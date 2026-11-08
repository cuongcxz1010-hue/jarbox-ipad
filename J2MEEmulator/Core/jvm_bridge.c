#include "Core/jvm_bridge.h"
#include "jvm.h"
#include "jvm_util.h"
#include "garbage.h"
#include "Graphics/j2me_render.h"
#include "Input/j2me_input.h"
#include "UI/j2me_ui.h"
#include "Audio/j2me_audio.h"
#include "NativeBridge/j2me_micro3d_gl.h"
#include "NativeBridge/m3g/j2me_m3g.h"
#include <stdio.h>
#include <string.h>
#include <stdatomic.h>
#include <signal.h>
#include "Graphics/gfx_text.h"

void net_natives_reg(MiniJVM *jvm);

static MiniJVM *g_jvm = NULL;
static atomic_int g_jvm_stop_requested = 0;

// Per-game settings to apply at the next jvm_bridge_init
#define MAX_EXTRA_PROPERTIES 32
static struct { char key[64]; char value[256]; } g_extra_properties[MAX_EXTRA_PROPERTIES];
static int g_extra_property_count = 0;
static int g_heap_limit_mb = 192;
static int g_font_small = 0, g_font_medium = 0, g_font_large = 0;

void jvm_bridge_set_property(const char *key, const char *value) {
    if (g_extra_property_count >= MAX_EXTRA_PROPERTIES) return;
    snprintf(g_extra_properties[g_extra_property_count].key, 64, "%s", key);
    snprintf(g_extra_properties[g_extra_property_count].value, 256, "%s", value);
    g_extra_property_count++;
}

void jvm_bridge_set_heap_limit(int megabytes) {
    if (megabytes >= 16 && megabytes <= 1024) g_heap_limit_mb = megabytes;
}

void jvm_bridge_set_font_sizes(int small, int medium, int large) {
    g_font_small = small;
    g_font_medium = medium;
    g_font_large = large;
}

/* 3D supersampling scale — shared by M3G (reads directly) and MC3D (via system property) */
int g_render_3d_scale = 1;

int jvm_bridge_init(const char *res_root, const char *save_root, const char *midlet_jar,
                    int screen_width, int screen_height, int render_3d_scale,
                    int fps_limit) {
    if (g_jvm) {
        printf("[JVM Bridge] JVM already initialized\n");
        return -1;
    }
    // Note: g_jvm_stop_requested is NOT reset here — it is reset in
    // jvm_bridge_destroy() after the previous session.  Resetting it here
    // would race with backTapped() which may have already set the flag
    // before this function runs on the background thread.

    // Build bootclasspath: minijvm_rt.jar
    // The J2ME API comes first so it can replace classes of the runtime (javax.microedition.io).
    char bootclasspath[1024];
    snprintf(bootclasspath, sizeof(bootclasspath), "%s/j2me_api.jar" PATHSEPARATOR "%s/minijvm_rt.jar", res_root, res_root);

    // Classpath: the MIDlet JAR
    char classpath[4096];
    snprintf(classpath, sizeof(classpath), "%s", midlet_jar);

    printf("[JVM Bridge] bootclasspath: %s\n", bootclasspath);
    printf("[JVM Bridge] classpath: %s\n", classpath);

    // Create JVM instance
    g_jvm = jvm_create();
    if (!g_jvm) {
        printf("[JVM Bridge] ERROR: jvm_create() failed\n");
        return -2;
    }

    g_jvm->jdwp_enable = 0;
    g_jvm->jdwp_suspend_on_start = 0;
    // The collector stops every game thread while it marks. Running it twice a
    // second made games stutter; now it runs every 4 s, or sooner when the
    // heap (Java objects + native images) passes 75% of 192 MB.
    g_jvm->max_heap_size = (s64)g_heap_limit_mb * 1024 * 1024;       // java + native via g_native_extra_heap
    g_jvm->garbage_collect_period_ms = 4000;
    g_jvm->heap_overload_percent = 75;

    s32 ret = jvm_init(g_jvm, (c8 *)bootclasspath, (c8 *)classpath);
    if (ret) {
        printf("[JVM Bridge] ERROR: jvm_init() failed with code %d\n", ret);
        jvm_destroy(g_jvm);
        g_jvm = NULL;
        return -3;
    }

    // Register native methods
    j2me_render_reg_natives(g_jvm);
    j2me_input_reg_natives(g_jvm);
    j2me_ui_reg_natives(g_jvm);
    j2me_audio_reg_natives(g_jvm);
    j2me_micro3d_gl_reg_natives(g_jvm);
    j2me_m3g_reg_natives(g_jvm);
    net_natives_reg(g_jvm);

    // Writing to a socket the server has closed must fail with an error, not kill the app
#ifdef SIGPIPE
    signal(SIGPIPE, SIG_IGN);
#endif

    // Set system properties
    sys_properties_set_c(g_jvm, "os.name", "iOS");
    sys_properties_set_c(g_jvm, "app.save.root", save_root);
    sys_properties_set_c(g_jvm, "microedition.platform", "Apple/iPhone");
    sys_properties_set_c(g_jvm, "microedition.encoding", "UTF-8");
    sys_properties_set_c(g_jvm, "microedition.locale", "en");
    sys_properties_set_c(g_jvm, "microedition.profiles", "MIDP-2.0");
    sys_properties_set_c(g_jvm, "microedition.configuration", "CLDC-1.1");

    // Screen dimensions — used by Display.java to set canvas size
    char sw[16], sh[16];
    snprintf(sw, sizeof(sw), "%d", screen_width);
    snprintf(sh, sizeof(sh), "%d", screen_height);
    sys_properties_set_c(g_jvm, "j2me.screen.width", sw);
    sys_properties_set_c(g_jvm, "j2me.screen.height", sh);

    // 3D supersampling scale for M3G and MascotCapsule (1=native, 2=2x AA, 3=3x AA)
    g_render_3d_scale = render_3d_scale > 0 ? render_3d_scale : 1;
    char ss[8];
    snprintf(ss, sizeof(ss), "%d", g_render_3d_scale);
    sys_properties_set_c(g_jvm, "micro3d.v3.fbo.scale", ss);  // MC3D reads this in Render.java

    // FPS limit (0 = unlimited)
    if (fps_limit > 0) {
        char fl[8];
        snprintf(fl, sizeof(fl), "%d", fps_limit);
        sys_properties_set_c(g_jvm, "j2me.fps.limit", fl);
    }
    for (int i = 0; i < g_extra_property_count; i++) {
        sys_properties_set_c(g_jvm, g_extra_properties[i].key, g_extra_properties[i].value);
    }
    g_extra_property_count = 0;
    gfx_text_set_sizes(g_font_small, g_font_medium, g_font_large);

    printf("[JVM Bridge] Screen size: %dx%d, 3D render scale: %s, FPS limit: %d\n",
           screen_width, screen_height, ss, fps_limit);

    printf("[JVM Bridge] JVM initialized successfully\n");
    return 0;
}

int jvm_bridge_run_midlet(const char *midlet_jar_path) {
    if (!g_jvm) {
        printf("[JVM Bridge] ERROR: JVM not initialized\n");
        return -1;
    }

    printf("[JVM Bridge] Running MIDlet from: %s\n", midlet_jar_path);

    ArrayList *java_para = arraylist_create(0);
    arraylist_push_back(java_para, (void *)midlet_jar_path);

    s32 ret = call_main(g_jvm, (c8 *)"javax/microedition/shell/MIDletRunner", java_para);

    arraylist_destroy(java_para);

    printf("[JVM Bridge] MIDlet finished with code %d\n", ret);
    return ret;
}

void jvm_bridge_destroy(void) {
    if (g_jvm) {
        printf("[JVM Bridge] Destroying JVM\n");

        // Step 1: Stop render subsystem first — zombie threads calling native
        // render methods will get NULL from acquire and return harmlessly.
        j2me_render_stop();

        // Step 2: Signal JVM shutdown and stop all threads.
        // exit_flag makes jvm_destroy's non-daemon wait loop exit immediately;
        // thread_stop_all sets is_stop/is_interrupt on each thread.
        g_jvm->collector->exit_flag = 1;
        thread_stop_all(g_jvm);

        // Step 3: jvm_destroy waits up to 3s for threads, then force-zombies.
        // After this, threads either exited or are zombie (status only — pthread
        // may still be running but render_stop prevents them touching freed resources).
        // Note: force-zombied pthreads may still execute briefly — class_clinit
        // and print_exception have is_stop / jvm_state guards to avoid crashes.
        jvm_destroy(g_jvm);
        g_jvm = NULL;

        // Step 4: Clean up native subsystems — safe because:
        // - render_stop blocks all render acquire calls
        // - jvm_destroy gave threads 3s to exit
        j2me_input_reset();
        j2me_audio_stop_all();
        j2me_micro3d_gl_cleanup();
        j2me_m3g_cleanup();
        j2me_render_cleanup(); // also resets render_stopped flag
        atomic_store(&g_jvm_stop_requested, 0);

        printf("[JVM Bridge] JVM destroyed, native state cleaned up\n");
    }
}

void jvm_bridge_request_stop(void) {
    printf("[JVM Bridge] Stop requested\n");
    atomic_store(&g_jvm_stop_requested, 1);
    j2me_input_wake();
}

int jvm_bridge_is_stop_requested(void) {
    return atomic_load(&g_jvm_stop_requested);
}
