// Desktop test host: graphics platform services and stubs for audio, native
// UI and 3D. Glyphs come from a 5x7 bitmap font so text can be seen in
// screenshots; frames are kept in memory and written as PNG on request.

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "Graphics/gfx_core.h"
#include "Graphics/gfx_text.h"
#include "Graphics/gfx_platform.h"
#include "Graphics/j2me_render.h"
#include "Input/j2me_input.h"
#include "Audio/j2me_audio.h"
#include "UI/j2me_ui.h"
#include "NativeBridge/j2me_micro3d_gl.h"
#include "NativeBridge/m3g/j2me_m3g.h"
#include "jvm.h"
#include "jvm_util.h"

// --- Latest frame -----------------------------------------------------------

static uint32_t *g_frame;
static int g_frame_w, g_frame_h;
long g_frames_presented = 0;

void gfx_platform_present(const GfxSurface *s) {
    size_t bytes = (size_t)s->width * s->height * 4;
    if (s->width != g_frame_w || s->height != g_frame_h) {
        free(g_frame);
        g_frame = (uint32_t *)malloc(bytes);
        g_frame_w = s->width;
        g_frame_h = s->height;
    }
    memcpy(g_frame, s->pixels, bytes);
    g_frames_presented++;
}

int host_save_frame(const char *path) {
    if (!g_frame) return 0;
    int32_t len = 0;
    uint8_t *png = gfx_png_encode(g_frame, g_frame_w, g_frame_h, &len);
    if (!png) return 0;
    FILE *f = fopen(path, "wb");
    if (!f) { free(png); return 0; }
    fwrite(png, 1, (size_t)len, f);
    fclose(f);
    free(png);
    return 1;
}

int gfx_platform_decode_image(const uint8_t *data, int32_t length, int32_t *w, int32_t *h, uint32_t **pixels, int32_t *hasAlpha) {
    return 0;
}

void gfx_platform_vibrate(int durationMs) { }
void gfx_platform_reset(void) { }
void j2me_render_set_flush_callback(j2me_flush_callback callback) { }

// --- Text -------------------------------------------------------------------

static const uint8_t FONT5X7[96][5] = {
{0,0,0,0,0},{0,0,95,0,0},{0,7,0,7,0},{20,127,20,127,20},{36,42,127,42,18},{35,19,8,100,98},{54,73,85,34,80},{0,5,3,0,0},
{0,28,34,65,0},{0,65,34,28,0},{20,8,62,8,20},{8,8,62,8,8},{0,80,48,0,0},{8,8,8,8,8},{0,96,96,0,0},{32,16,8,4,2},
{62,81,73,69,62},{0,66,127,64,0},{66,97,81,73,70},{33,65,69,75,49},{24,20,18,127,16},{39,69,69,69,57},{60,74,73,73,48},{1,113,9,5,3},
{54,73,73,73,54},{6,73,73,41,30},{0,54,54,0,0},{0,86,54,0,0},{8,20,34,65,0},{20,20,20,20,20},{0,65,34,20,8},{2,1,81,9,6},
{50,73,121,65,62},{126,17,17,17,126},{127,73,73,73,54},{62,65,65,65,34},{127,65,65,34,28},{127,73,73,73,65},{127,9,9,9,1},{62,65,73,73,122},
{127,8,8,8,127},{0,65,127,65,0},{32,64,65,63,1},{127,8,20,34,65},{127,64,64,64,64},{127,2,12,2,127},{127,4,8,16,127},{62,65,65,65,62},
{127,9,9,9,6},{62,65,81,33,94},{127,9,25,41,70},{70,73,73,73,49},{1,1,127,1,1},{63,64,64,64,63},{31,32,64,32,31},{63,64,56,64,63},
{99,20,8,20,99},{7,8,112,8,7},{97,81,73,69,67},{0,127,65,65,0},{2,4,8,16,32},{0,65,65,127,0},{4,2,1,2,4},{64,64,64,64,64},
{0,1,2,4,0},{32,84,84,84,120},{127,72,68,68,56},{56,68,68,68,32},{56,68,68,72,127},{56,84,84,84,24},{8,126,9,1,2},{12,82,82,82,62},
{127,8,4,4,120},{0,68,125,64,0},{32,64,68,61,0},{127,16,40,68,0},{0,65,127,64,0},{124,4,24,4,120},{124,8,4,4,120},{56,68,68,68,56},
{124,20,20,20,8},{8,20,20,24,124},{124,8,4,4,8},{72,84,84,84,32},{4,63,68,64,32},{60,64,64,32,124},{28,32,64,32,28},{60,64,48,64,60},
{68,40,16,40,68},{12,80,80,80,60},{68,100,84,76,68},{0,8,54,65,0},{0,0,127,0,0},{0,65,54,8,0},{16,8,8,16,8},{0,0,0,0,0}};

void gfx_platform_font_metrics(int font, int pixelSize, int *ascent, int *height) {
    int scale = pixelSize >= 16 ? 2 : 1;
    *ascent = 8 * scale;
    *height = 10 * scale;
}

int gfx_platform_make_glyph(int font, int pixelSize, uint32_t ch, GfxGlyph *out) {
    memset(out, 0, sizeof(*out));
    int scale = pixelSize >= 16 ? 2 : 1;
    out->advance64 = 6 * scale * 64;
    if (ch == ' ') return 1;
    const uint8_t *cols = (ch >= 32 && ch < 128) ? FONT5X7[ch - 32] : FONT5X7['?' - 32];
    int w = 5 * scale, h = 7 * scale;
    uint8_t *mask = (uint8_t *)calloc((size_t)w, (size_t)h);
    if (!mask) return 0;
    for (int x = 0; x < 5; x++)
        for (int y = 0; y < 7; y++)
            if (cols[x] & (1 << y))
                for (int sy = 0; sy < scale; sy++)
                    for (int sx = 0; sx < scale; sx++)
                        mask[(y * scale + sy) * w + x * scale + sx] = 255;
    out->mask = mask;
    out->w = (int16_t)w;
    out->h = (int16_t)h;
    out->left = 0;
    out->top = (int16_t)(-7 * scale);
    return 1;
}

// --- Stubs ------------------------------------------------------------------

#define CLS "javax/microedition/lcdui/NativeBridge"

static char g_last_screen[65536];

static void log_jstring(const char *tag, Instance *jstr, Runtime *runtime) {
    Utf8String *u = utf8_create();
    if (jstr) jstring_2_utf8(jstr, u, runtime);
    strncpy(g_last_screen, utf8_cstr(u), sizeof(g_last_screen) - 1);
    printf("[%s] %s\n", tag, utf8_cstr(u));
    utf8_destroy(u);
}

static s32 n_showScreen(Runtime *r, JClass *c) { log_jstring("SCREEN", localvar_getRefer(r->localvar, 0), r); return RUNTIME_STATUS_NORMAL; }
static s32 n_setCanvasCommands(Runtime *r, JClass *c) { return RUNTIME_STATUS_NORMAL; }
static s32 n_showCanvas(Runtime *r, JClass *c) { printf("[UI] canvas shown\n"); return RUNTIME_STATUS_NORMAL; }
static s32 n_takeTextResult(Runtime *r, JClass *c) { push_ref(r->stack, NULL); return RUNTIME_STATUS_NORMAL; }
static s32 n_platformRequest(Runtime *r, JClass *c) { log_jstring("URL", localvar_getRefer(r->localvar, 0), r); return RUNTIME_STATUS_NORMAL; }
static s32 n_reportFailure(Runtime *r, JClass *c) { log_jstring("FAILURE", localvar_getRefer(r->localvar, 0), r); return RUNTIME_STATUS_NORMAL; }
static s32 n_noop(Runtime *r, JClass *c) { return RUNTIME_STATUS_NORMAL; }
static s32 n_zero_long(Runtime *r, JClass *c) { push_long(r->stack, 1); return RUNTIME_STATUS_NORMAL; }
static s32 n_zero_long0(Runtime *r, JClass *c) { push_long(r->stack, 0); return RUNTIME_STATUS_NORMAL; }

static java_native_method host_methods[] = {
    {CLS, "showScreen",       "(Ljava/lang/String;)V",  n_showScreen},
    {CLS, "showCanvas",       "()V",                    n_showCanvas},
    {CLS, "setCanvasCommands","(Ljava/lang/String;)V",  n_setCanvasCommands},
    {CLS, "takeTextResult",   "(I)Ljava/lang/String;",  n_takeTextResult},
    {CLS, "platformRequest",  "(Ljava/lang/String;)V",  n_platformRequest},
    {CLS, "reportFailure",    "(Ljava/lang/String;)V",  n_reportFailure},
    {CLS, "audioCreatePlayer","([B)J",   n_zero_long},
    {CLS, "audioStart",       "(J)V",    n_noop},
    {CLS, "audioStop",        "(J)V",    n_noop},
    {CLS, "audioClose",       "(J)V",    n_noop},
    {CLS, "audioSetLoop",     "(JI)V",   n_noop},
    {CLS, "audioSetVolume",   "(JF)V",   n_noop},
    {CLS, "audioGetDuration", "(J)J",    n_zero_long0},
    {CLS, "audioGetTime",     "(J)J",    n_zero_long0},
    {CLS, "audioCreateMidiPlayer","([B)J", n_zero_long},
    {CLS, "audioMidiStart",   "(J)V",    n_noop},
    {CLS, "audioMidiStop",    "(J)V",    n_noop},
    {CLS, "audioMidiClose",   "(J)V",    n_noop},
    {CLS, "audioPlayTone",    "(III)V",  n_noop},
};
#undef CLS

void j2me_ui_reg_natives(MiniJVM *jvm) { native_reg_lib(jvm, host_methods, sizeof(host_methods) / sizeof(java_native_method)); }
void j2me_audio_reg_natives(MiniJVM *jvm) { }
void j2me_audio_stop_all(void) { }
void j2me_micro3d_gl_reg_natives(MiniJVM *jvm) { }
void j2me_micro3d_gl_cleanup(void) { }
void j2me_m3g_reg_natives(MiniJVM *jvm) { }
void j2me_m3g_cleanup(void) { }
