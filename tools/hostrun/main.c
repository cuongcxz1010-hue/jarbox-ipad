// Desktop test host for the emulator engine: runs a real MIDlet on the real JVM,
// event queue, MIDP layer and renderer, driven by a timed script.
//
//   hostrun <resources dir> <save dir> <game.jar> <width> <height> <seconds> [script] [out dir]
//
// Script: one command per line, time in milliseconds since start.
//   2000 key  -5        press and release a key
//   2000 down -5        press only
//   2500 up   -5        release only
//   3000 tap  120 160   touch at a point
//   4000 shot name      save the current frame as <out dir>/name.png

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <windows.h>
#include "jvm.h"
#include "jvm_util.h"
#include "Core/jvm_bridge.h"
#include "Input/j2me_input.h"

extern long g_frames_presented;
int host_save_frame(const char *path);

typedef struct {
    int at;
    char cmd[16];
    char arg[128];
    int a, b;
} Step;

static Step g_steps[1024];
static int g_step_count = 0;
static char g_out_dir[512] = ".";
static int g_seconds = 10;
static char g_jar[512];

static void load_script(const char *path) {
    FILE *f = fopen(path, "r");
    if (!f) { printf("[host] no script %s\n", path); return; }
    char line[256];
    while (fgets(line, sizeof line, f) && g_step_count < 1024) {
        Step *s = &g_steps[g_step_count];
        memset(s, 0, sizeof(*s));
        int n = sscanf(line, "%d %15s %127s %d", &s->at, s->cmd, s->arg, &s->b);
        if (n >= 2) {
            s->a = atoi(s->arg);
            g_step_count++;
        }
    }
    fclose(f);
}

static DWORD WINAPI driver(LPVOID unused) {
    DWORD start = GetTickCount();
    int next = 0;
    long lastFrames = 0;
    DWORD lastReport = start;
    for (;;) {
        DWORD now = GetTickCount();
        int elapsed = (int)(now - start);
        while (next < g_step_count && g_steps[next].at <= elapsed) {
            Step *s = &g_steps[next++];
            if (!strcmp(s->cmd, "key")) {
                j2me_input_post_key(J2ME_INPUT_KEY_PRESSED, s->a);
                Sleep(60);
                j2me_input_post_key(J2ME_INPUT_KEY_RELEASED, s->a);
            } else if (!strcmp(s->cmd, "down")) {
                j2me_input_post_key(J2ME_INPUT_KEY_PRESSED, s->a);
            } else if (!strcmp(s->cmd, "up")) {
                j2me_input_post_key(J2ME_INPUT_KEY_RELEASED, s->a);
            } else if (!strcmp(s->cmd, "tap")) {
                j2me_input_post_touch(J2ME_INPUT_POINTER_PRESSED, s->a, s->b);
                Sleep(50);
                j2me_input_post_touch(J2ME_INPUT_POINTER_RELEASED, s->a, s->b);
            } else if (!strcmp(s->cmd, "shot")) {
                char path[700];
                snprintf(path, sizeof path, "%s/%s.png", g_out_dir, s->arg);
                printf("[host] screenshot %s: %s\n", path, host_save_frame(path) ? "ok" : "no frame yet");
            }
            fflush(stdout);
        }
        if (now - lastReport >= 1000) {
            printf("[host] t=%ds frames/s=%ld\n", elapsed / 1000, g_frames_presented - lastFrames);
            fflush(stdout);
            lastFrames = g_frames_presented;
            lastReport = now;
        }
        if (elapsed >= g_seconds * 1000) {
            char path[700];
            snprintf(path, sizeof path, "%s/final.png", g_out_dir);
            host_save_frame(path);
            FILETIME c0, e0, k0, u0;
            GetProcessTimes(GetCurrentProcess(), &c0, &e0, &k0, &u0);
            ULONGLONG cpu = (((ULONGLONG)k0.dwHighDateTime << 32 | k0.dwLowDateTime) + ((ULONGLONG)u0.dwHighDateTime << 32 | u0.dwLowDateTime)) / 10000;
            printf("[host] cpu time %llu ms over %d s, %ld frames\n", cpu, elapsed / 1000, g_frames_presented);
            printf("[host] time is up, stopping\n");
            fflush(stdout);
            jvm_bridge_request_stop();
            j2me_input_wake();
            Sleep(4000);
            printf("[host] forced exit\n");
            fflush(stdout);
            ExitProcess(0);
        }
        Sleep(10);
    }
    return 0;
}

int main(int argc, char **argv) {
    if (argc < 7) {
        printf("usage: hostrun res save game.jar w h seconds [script] [outdir]\n");
        return 2;
    }
    setvbuf(stdout, NULL, _IONBF, 0);
    const char *res = argv[1], *save = argv[2];
    strncpy(g_jar, argv[3], sizeof g_jar - 1);
    int w = atoi(argv[4]), h = atoi(argv[5]);
    g_seconds = atoi(argv[6]);
    if (argc > 7) load_script(argv[7]);
    if (argc > 8) strncpy(g_out_dir, argv[8], sizeof g_out_dir - 1);

    WSADATA wsa;
    WSAStartup(MAKEWORD(2, 2), &wsa);

    int rc = jvm_bridge_init(res, save, g_jar, w, h, 1, 0);
    if (rc) { printf("[host] init failed %d\n", rc); return 1; }
    CreateThread(NULL, 0, driver, NULL, 0, NULL);
    rc = jvm_bridge_run_midlet(g_jar);
    printf("[host] run_midlet returned %d\n", rc);
    jvm_bridge_destroy();
    return rc;
}
