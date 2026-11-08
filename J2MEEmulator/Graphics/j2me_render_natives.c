//
//  j2me_render_natives.c
//  JarBox Graphics Engine — javax.microedition.lcdui.NativeBridge drawing natives
//
//  Owns images and drawing contexts and forwards every Graphics call to the
//  software renderer in gfx_core.c. Platform services (present a frame, decode
//  non-PNG images, rasterize glyphs, vibrate) are in gfx_platform_*.
//
//  Lifetimes: Java objects hold raw handles and are finalized by the GC thread
//  while other threads may still be drawing, so every call goes through
//  acquire/release reference counting. A freed shell is kept for one more
//  frame so a late acquire sees refcount 0 instead of reused memory.
//

#include "Graphics/j2me_render.h"
#include "Graphics/gfx_core.h"
#include "Graphics/gfx_text.h"
#include "Graphics/gfx_platform.h"
#include "jvm.h"
#include "jvm_util.h"
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct RenderImage {
    GfxSurface surface;
    int isMutable;
    _Atomic int32_t refcount;
    struct RenderImage *next_dead;
} RenderImage;

typedef struct RenderContext {
    RenderImage *target;        // holds one reference on the image
    GfxPaint paint;
    int font;                   // gfx_font_index
    int underlined;
    _Atomic int32_t refcount;
    struct RenderContext *next_dead;
} RenderContext;

static volatile int g_render_stopped = 0;

// ------------------------------------------------------------
// Tracking of live objects, for cleanup between game sessions
// ------------------------------------------------------------

#define TRACK_MAX 16384
static RenderContext *g_live_rc[TRACK_MAX];
static int g_live_rc_count = 0;
static RenderImage *g_live_img[TRACK_MAX];
static int g_live_img_count = 0;
static spinlock_t g_track_lock = {0, 0, 0};

static void track_rc(RenderContext *rc) {
    spin_lock(&g_track_lock);
    if (g_live_rc_count < TRACK_MAX) g_live_rc[g_live_rc_count++] = rc;
    spin_unlock(&g_track_lock);
}
static void untrack_rc(RenderContext *rc) {
    spin_lock(&g_track_lock);
    for (int i = 0; i < g_live_rc_count; i++) {
        if (g_live_rc[i] == rc) { g_live_rc[i] = g_live_rc[--g_live_rc_count]; break; }
    }
    spin_unlock(&g_track_lock);
}
static void track_img(RenderImage *img) {
    spin_lock(&g_track_lock);
    if (g_live_img_count < TRACK_MAX) g_live_img[g_live_img_count++] = img;
    spin_unlock(&g_track_lock);
}
static void untrack_img(RenderImage *img) {
    spin_lock(&g_track_lock);
    for (int i = 0; i < g_live_img_count; i++) {
        if (g_live_img[i] == img) { g_live_img[i] = g_live_img[--g_live_img_count]; break; }
    }
    spin_unlock(&g_track_lock);
}

// ------------------------------------------------------------
// Native memory, visible to the GC
// ------------------------------------------------------------

extern s64 g_native_extra_heap;
static inline void native_heap_add(s64 bytes) { __atomic_fetch_add(&g_native_extra_heap, bytes, __ATOMIC_RELAXED); }
static inline void native_heap_sub(s64 bytes) { __atomic_fetch_sub(&g_native_extra_heap, bytes, __ATOMIC_RELAXED); }

// ------------------------------------------------------------
// Dead shells (two generations)
// ------------------------------------------------------------

static _Atomic(RenderContext *) g_dead_rc_gen0 = NULL;
static RenderContext *g_dead_rc_gen1 = NULL;
static _Atomic(RenderImage *) g_dead_img_gen0 = NULL;
static RenderImage *g_dead_img_gen1 = NULL;

static void enqueue_dead_rc(RenderContext *rc) {
    RenderContext *old;
    do {
        old = atomic_load_explicit(&g_dead_rc_gen0, memory_order_relaxed);
        rc->next_dead = old;
    } while (!atomic_compare_exchange_weak_explicit(&g_dead_rc_gen0, &old, rc, memory_order_release, memory_order_relaxed));
}

static void enqueue_dead_img(RenderImage *img) {
    RenderImage *old;
    do {
        old = atomic_load_explicit(&g_dead_img_gen0, memory_order_relaxed);
        img->next_dead = old;
    } while (!atomic_compare_exchange_weak_explicit(&g_dead_img_gen0, &old, img, memory_order_release, memory_order_relaxed));
}

static void process_dead_shells(void) {
    RenderContext *rc = g_dead_rc_gen1;
    while (rc) { RenderContext *next = rc->next_dead; free(rc); rc = next; }
    RenderImage *img = g_dead_img_gen1;
    while (img) { RenderImage *next = img->next_dead; free(img); img = next; }
    g_dead_rc_gen1 = atomic_exchange_explicit(&g_dead_rc_gen0, NULL, memory_order_acquire);
    g_dead_img_gen1 = atomic_exchange_explicit(&g_dead_img_gen0, NULL, memory_order_acquire);
}

// ------------------------------------------------------------
// Acquire / release
// ------------------------------------------------------------

static inline RenderImage *img_acquire(s64 handle) {
    if (g_render_stopped || handle == 0) return NULL;
    RenderImage *img = (RenderImage *)(intptr_t)handle;
    int32_t old = atomic_load_explicit(&img->refcount, memory_order_relaxed);
    do {
        if (old <= 0) return NULL;
    } while (!atomic_compare_exchange_weak_explicit(&img->refcount, &old, old + 1, memory_order_acquire, memory_order_relaxed));
    return img;
}

static void img_release(RenderImage *img) {
    if (!img) return;
    if (atomic_fetch_sub_explicit(&img->refcount, 1, memory_order_release) == 1) {
        atomic_thread_fence(memory_order_acquire);
        untrack_img(img);
        native_heap_sub((s64)img->surface.width * img->surface.height * 4);
        gfx_surface_free(&img->surface);
        enqueue_dead_img(img);
    }
}

static inline RenderContext *rc_acquire(s64 handle) {
    if (g_render_stopped || handle == 0) return NULL;
    RenderContext *rc = (RenderContext *)(intptr_t)handle;
    int32_t old = atomic_load_explicit(&rc->refcount, memory_order_relaxed);
    do {
        if (old <= 0) return NULL;
    } while (!atomic_compare_exchange_weak_explicit(&rc->refcount, &old, old + 1, memory_order_acquire, memory_order_relaxed));
    return rc;
}

static void rc_release(RenderContext *rc) {
    if (!rc) return;
    if (atomic_fetch_sub_explicit(&rc->refcount, 1, memory_order_release) == 1) {
        atomic_thread_fence(memory_order_acquire);
        untrack_rc(rc);
        RenderImage *t = rc->target;
        rc->target = NULL;
        img_release(t);
        enqueue_dead_rc(rc);
    }
}

// ------------------------------------------------------------
// Creation
// ------------------------------------------------------------

static RenderImage *image_new(int w, int h, int isMutable, int hasAlpha) {
    RenderImage *img = (RenderImage *)calloc(1, sizeof(RenderImage));
    if (!img) return NULL;
    if (!gfx_surface_alloc(&img->surface, w, h, hasAlpha)) { free(img); return NULL; }
    img->isMutable = isMutable;
    atomic_init(&img->refcount, 1);
    native_heap_add((s64)img->surface.width * img->surface.height * 4);
    track_img(img);
    return img;
}

/// Wrap a pixel buffer that was allocated elsewhere (decoders).
static RenderImage *image_adopt(int w, int h, uint32_t *pixels, int hasAlpha) {
    RenderImage *img = (RenderImage *)calloc(1, sizeof(RenderImage));
    if (!img) { free(pixels); return NULL; }
    img->surface.pixels = pixels;
    img->surface.width = w;
    img->surface.height = h;
    img->surface.hasAlpha = hasAlpha;
    atomic_init(&img->refcount, 1);
    native_heap_add((s64)w * h * 4);
    track_img(img);
    return img;
}

static RenderContext *context_new(RenderImage *target) {
    RenderContext *rc = (RenderContext *)calloc(1, sizeof(RenderContext));
    if (!rc) return NULL;
    rc->target = target;
    gfx_paint_init(&rc->paint, &target->surface);
    rc->font = gfx_font_index(GFX_FACE_SYSTEM, 0, GFX_SIZE_MEDIUM);
    atomic_init(&rc->refcount, 1);
    track_rc(rc);
    return rc;
}

// ------------------------------------------------------------
// Natives. Arguments are read with the inline local-variable accessors.
// ------------------------------------------------------------

#define ARG_I(n) localvar_getInt(runtime->localvar, (n))
#define ARG_L(n) localvar_getLong(runtime->localvar, (n))
#define ARG_R(n) ((Instance *)localvar_getRefer(runtime->localvar, (n)))

#define CTX(n) RenderContext *rc = rc_acquire(ARG_L(n)); if (!rc) return RUNTIME_STATUS_NORMAL
#define S(rc) (&(rc)->target->surface)

static s32 n_createContext(Runtime *runtime, JClass *clazz) {
    RenderImage *screen = image_new(ARG_I(0), ARG_I(1), 1, 0);
    RenderContext *rc = NULL;
    if (screen) {
        gfx_surface_fill(&screen->surface, 0xFFFFFFFFu);
        rc = context_new(screen);
        if (!rc) img_release(screen);
    }
    push_long(runtime->stack, (s64)(intptr_t)rc);
    return RUNTIME_STATUS_NORMAL;
}

static s32 n_destroyContext(Runtime *runtime, JClass *clazz) {
    s64 handle = ARG_L(0);
    if (!g_render_stopped && handle) rc_release((RenderContext *)(intptr_t)handle);
    return RUNTIME_STATUS_NORMAL;
}

static s32 n_flushToScreen(Runtime *runtime, JClass *clazz) {
    process_dead_shells();
    CTX(0);
    gfx_platform_present(S(rc));
    rc_release(rc);
    return RUNTIME_STATUS_NORMAL;
}

static s32 n_setColor(Runtime *runtime, JClass *clazz) {
    CTX(0);
    gfx_paint_set_color(&rc->paint, (uint32_t)ARG_I(2));
    rc_release(rc);
    return RUNTIME_STATUS_NORMAL;
}

static s32 n_setClip(Runtime *runtime, JClass *clazz) {
    CTX(0);
    gfx_paint_set_clip(&rc->paint, S(rc), ARG_I(2), ARG_I(3), ARG_I(4), ARG_I(5));
    rc_release(rc);
    return RUNTIME_STATUS_NORMAL;
}

static s32 n_setStrokeStyle(Runtime *runtime, JClass *clazz) {
    CTX(0);
    rc->paint.dotted = ARG_I(2) != 0;
    rc_release(rc);
    return RUNTIME_STATUS_NORMAL;
}

static s32 n_drawLine(Runtime *runtime, JClass *clazz) {
    CTX(0);
    gfx_draw_line(S(rc), &rc->paint, ARG_I(2), ARG_I(3), ARG_I(4), ARG_I(5));
    rc_release(rc);
    return RUNTIME_STATUS_NORMAL;
}

static s32 n_fillRect(Runtime *runtime, JClass *clazz) {
    CTX(0);
    gfx_fill_rect(S(rc), &rc->paint, ARG_I(2), ARG_I(3), ARG_I(4), ARG_I(5));
    rc_release(rc);
    return RUNTIME_STATUS_NORMAL;
}

static s32 n_drawRect(Runtime *runtime, JClass *clazz) {
    CTX(0);
    gfx_draw_rect(S(rc), &rc->paint, ARG_I(2), ARG_I(3), ARG_I(4), ARG_I(5));
    rc_release(rc);
    return RUNTIME_STATUS_NORMAL;
}

static s32 n_fillArc(Runtime *runtime, JClass *clazz) {
    CTX(0);
    gfx_fill_arc(S(rc), &rc->paint, ARG_I(2), ARG_I(3), ARG_I(4), ARG_I(5), ARG_I(6), ARG_I(7));
    rc_release(rc);
    return RUNTIME_STATUS_NORMAL;
}

static s32 n_drawArc(Runtime *runtime, JClass *clazz) {
    CTX(0);
    gfx_draw_arc(S(rc), &rc->paint, ARG_I(2), ARG_I(3), ARG_I(4), ARG_I(5), ARG_I(6), ARG_I(7));
    rc_release(rc);
    return RUNTIME_STATUS_NORMAL;
}

static s32 n_fillRoundRect(Runtime *runtime, JClass *clazz) {
    CTX(0);
    gfx_fill_round_rect(S(rc), &rc->paint, ARG_I(2), ARG_I(3), ARG_I(4), ARG_I(5), ARG_I(6), ARG_I(7));
    rc_release(rc);
    return RUNTIME_STATUS_NORMAL;
}

static s32 n_drawRoundRect(Runtime *runtime, JClass *clazz) {
    CTX(0);
    gfx_draw_round_rect(S(rc), &rc->paint, ARG_I(2), ARG_I(3), ARG_I(4), ARG_I(5), ARG_I(6), ARG_I(7));
    rc_release(rc);
    return RUNTIME_STATUS_NORMAL;
}

static s32 n_fillTriangle(Runtime *runtime, JClass *clazz) {
    CTX(0);
    gfx_fill_triangle(S(rc), &rc->paint, ARG_I(2), ARG_I(3), ARG_I(4), ARG_I(5), ARG_I(6), ARG_I(7));
    rc_release(rc);
    return RUNTIME_STATUS_NORMAL;
}

static s32 n_fillPolygon(Runtime *runtime, JClass *clazz) {
    Instance *xs = ARG_R(2), *ys = ARG_R(3);
    s32 n = ARG_I(4);
    CTX(0);
    if (xs && ys && n >= 3 && n <= xs->arr_length && n <= ys->arr_length)
        gfx_fill_polygon(S(rc), &rc->paint, (const int32_t *)xs->arr_body, (const int32_t *)ys->arr_body, n);
    rc_release(rc);
    return RUNTIME_STATUS_NORMAL;
}

static s32 n_drawPolygon(Runtime *runtime, JClass *clazz) {
    Instance *xs = ARG_R(2), *ys = ARG_R(3);
    s32 n = ARG_I(4);
    CTX(0);
    if (xs && ys && n >= 2 && n <= xs->arr_length && n <= ys->arr_length)
        gfx_draw_polygon(S(rc), &rc->paint, (const int32_t *)xs->arr_body, (const int32_t *)ys->arr_body, n);
    rc_release(rc);
    return RUNTIME_STATUS_NORMAL;
}

static s32 n_copyArea(Runtime *runtime, JClass *clazz) {
    CTX(0);
    gfx_copy_area(S(rc), &rc->paint, ARG_I(2), ARG_I(3), ARG_I(4), ARG_I(5), ARG_I(6), ARG_I(7));
    rc_release(rc);
    return RUNTIME_STATUS_NORMAL;
}

// --- Text ---

static s32 n_setFont(Runtime *runtime, JClass *clazz) {
    s32 face = ARG_I(2), style = ARG_I(3), size = ARG_I(4);
    CTX(0);
    rc->font = gfx_font_index(face, style, size);
    rc->underlined = (style & GFX_STYLE_UNDERLINED) != 0;
    rc_release(rc);
    return RUNTIME_STATUS_NORMAL;
}

/// UTF-16 code units of a java.lang.String, or NULL for an empty one.
static inline const uint16_t *jstring_chars(Instance *jstr, Runtime *runtime, s32 *count) {
    *count = 0;
    if (!jstr) return NULL;
    Instance *arr = jstring_get_value_array(jstr, runtime);
    s32 n = jstring_get_count(jstr, runtime);
    s32 off = jstring_get_offset(jstr, runtime);
    if (!arr || !arr->arr_body || n <= 0 || off < 0 || off + n > arr->arr_length) return NULL;
    *count = n;
    return (const uint16_t *)arr->arr_body + off;
}

static s32 n_drawString(Runtime *runtime, JClass *clazz) {
    Instance *jstr = ARG_R(2);
    s32 x = ARG_I(3), y = ARG_I(4), anchor = ARG_I(5);
    CTX(0);
    s32 count;
    const uint16_t *chars = jstring_chars(jstr, runtime, &count);
    if (chars) gfx_draw_text(S(rc), &rc->paint, rc->font, rc->underlined, chars, count, x, y, anchor);
    rc_release(rc);
    return RUNTIME_STATUS_NORMAL;
}

static s32 n_getStringWidth(Runtime *runtime, JClass *clazz) {
    Instance *jstr = ARG_R(2);
    RenderContext *rc = rc_acquire(ARG_L(0));
    s32 width = 0, count;
    const uint16_t *chars = jstring_chars(jstr, runtime, &count);
    if (rc && chars) width = gfx_text_width(rc->font, chars, count);
    rc_release(rc);
    push_int(runtime->stack, width);
    return RUNTIME_STATUS_NORMAL;
}

static s32 n_getFontHeight(Runtime *runtime, JClass *clazz) {
    RenderContext *rc = rc_acquire(ARG_L(0));
    push_int(runtime->stack, rc ? gfx_font_height(rc->font) : 0);
    rc_release(rc);
    return RUNTIME_STATUS_NORMAL;
}

static s32 n_getFontAscent(Runtime *runtime, JClass *clazz) {
    RenderContext *rc = rc_acquire(ARG_L(0));
    push_int(runtime->stack, rc ? gfx_font_ascent(rc->font) : 0);
    rc_release(rc);
    return RUNTIME_STATUS_NORMAL;
}

static s32 n_fontHeight(Runtime *runtime, JClass *clazz) {
    push_int(runtime->stack, gfx_font_height(gfx_font_index(ARG_I(0), ARG_I(1), ARG_I(2))));
    return RUNTIME_STATUS_NORMAL;
}

static s32 n_fontAscent(Runtime *runtime, JClass *clazz) {
    push_int(runtime->stack, gfx_font_ascent(gfx_font_index(ARG_I(0), ARG_I(1), ARG_I(2))));
    return RUNTIME_STATUS_NORMAL;
}

static s32 n_charWidth64(Runtime *runtime, JClass *clazz) {
    push_int(runtime->stack, gfx_char_width64(gfx_font_index(ARG_I(0), ARG_I(1), ARG_I(2)), (uint32_t)ARG_I(3) & 0xFFFF));
    return RUNTIME_STATUS_NORMAL;
}

static s32 n_stringWidthFont(Runtime *runtime, JClass *clazz) {
    int font = gfx_font_index(ARG_I(0), ARG_I(1), ARG_I(2));
    s32 count;
    const uint16_t *chars = jstring_chars(ARG_R(3), runtime, &count);
    push_int(runtime->stack, chars ? gfx_text_width(font, chars, count) : 0);
    return RUNTIME_STATUS_NORMAL;
}

// --- Images ---

static s32 n_createMutableImage(Runtime *runtime, JClass *clazz) {
    RenderImage *img = image_new(ARG_I(0), ARG_I(1), 1, 0);
    if (img) gfx_surface_fill(&img->surface, 0xFFFFFFFFu);     // MIDP: mutable images start white
    push_long(runtime->stack, (s64)(intptr_t)img);
    return RUNTIME_STATUS_NORMAL;
}

/// A mutable image filled with one ARGB colour, transparent allowed (Nokia, Siemens).
static s32 n_createFilledImage(Runtime *runtime, JClass *clazz) {
    uint32_t argb = (uint32_t)ARG_I(2);
    RenderImage *img = image_new(ARG_I(0), ARG_I(1), 1, (argb >> 24) != 255);
    if (img) gfx_surface_fill(&img->surface, gfx_premultiply(argb));
    push_long(runtime->stack, (s64)(intptr_t)img);
    return RUNTIME_STATUS_NORMAL;
}

static s32 n_createImageFromData(Runtime *runtime, JClass *clazz) {
    Instance *arr = ARG_R(0);
    s32 offset = ARG_I(1), length = ARG_I(2);
    RenderImage *img = NULL;
    if (arr && offset >= 0 && length > 0 && offset <= arr->arr_length - length) {
        const uint8_t *data = (const uint8_t *)arr->arr_body + offset;
        int32_t w = 0, h = 0, hasAlpha = 0;
        uint32_t *pixels = NULL;
        if (gfx_png_decode(data, length, &w, &h, &pixels, &hasAlpha) ||
            gfx_platform_decode_image(data, length, &w, &h, &pixels, &hasAlpha)) {
            img = image_adopt(w, h, pixels, hasAlpha);
        }
    }
    push_long(runtime->stack, (s64)(intptr_t)img);
    return RUNTIME_STATUS_NORMAL;
}

static s32 n_createImageFromRGB(Runtime *runtime, JClass *clazz) {
    Instance *arr = ARG_R(0);
    s32 w = ARG_I(1), h = ARG_I(2), alpha = ARG_I(3);
    RenderImage *img = NULL;
    if (arr && w > 0 && h > 0 && (s64)w * h <= arr->arr_length) {
        img = image_new(w, h, 0, alpha);
        if (img) gfx_store_rgb(&img->surface, (const int32_t *)arr->arr_body, arr->arr_length, alpha);
    }
    push_long(runtime->stack, (s64)(intptr_t)img);
    return RUNTIME_STATUS_NORMAL;
}

/// Immutable copy of a region of an image, transparency kept.
static s32 n_createImageFromRegion(Runtime *runtime, JClass *clazz) {
    s32 x = ARG_I(2), y = ARG_I(3), w = ARG_I(4), h = ARG_I(5), transform = ARG_I(6);
    RenderImage *src = img_acquire(ARG_L(0));
    RenderImage *img = NULL;
    if (src) {
        int outW, outH;
        gfx_transformed_size(w, h, transform, &outW, &outH);
        img = image_new(outW, outH, 0, src->surface.hasAlpha);
        if (img) {
            gfx_surface_fill(&img->surface, 0);
            GfxPaint paint;
            gfx_paint_init(&paint, &img->surface);
            gfx_blit(&img->surface, &paint, &src->surface, x, y, w, h, transform, 0, 0);
        }
    }
    img_release(src);
    push_long(runtime->stack, (s64)(intptr_t)img);
    return RUNTIME_STATUS_NORMAL;
}

static s32 n_destroyImage(Runtime *runtime, JClass *clazz) {
    s64 handle = ARG_L(0);
    if (!g_render_stopped && handle) img_release((RenderImage *)(intptr_t)handle);
    return RUNTIME_STATUS_NORMAL;
}

static s32 n_getImageWidth(Runtime *runtime, JClass *clazz) {
    RenderImage *img = img_acquire(ARG_L(0));
    push_int(runtime->stack, img ? img->surface.width : 0);
    img_release(img);
    return RUNTIME_STATUS_NORMAL;
}

static s32 n_getImageHeight(Runtime *runtime, JClass *clazz) {
    RenderImage *img = img_acquire(ARG_L(0));
    push_int(runtime->stack, img ? img->surface.height : 0);
    img_release(img);
    return RUNTIME_STATUS_NORMAL;
}

static s32 n_getImageContext(Runtime *runtime, JClass *clazz) {
    RenderImage *img = img_acquire(ARG_L(0));
    RenderContext *rc = NULL;
    if (img && img->isMutable) {
        rc = context_new(img);          // takes over the acquired reference
        if (!rc) img_release(img);
    } else {
        img_release(img);
    }
    push_long(runtime->stack, (s64)(intptr_t)rc);
    return RUNTIME_STATUS_NORMAL;
}

/// Anchored position of a w × h box.
static inline void anchor_box(int anchor, int w, int h, int *x, int *y) {
    if (anchor & GFX_HCENTER) *x -= w / 2;
    else if (anchor & GFX_RIGHT) *x -= w;
    if (anchor & GFX_VCENTER) *y -= h / 2;
    else if (anchor & GFX_BOTTOM) *y -= h;
}

static s32 n_drawImage(Runtime *runtime, JClass *clazz) {
    s32 x = ARG_I(4), y = ARG_I(5), anchor = ARG_I(6);
    CTX(0);
    RenderImage *img = img_acquire(ARG_L(2));
    if (img) {
        anchor_box(anchor, img->surface.width, img->surface.height, &x, &y);
        gfx_blit(S(rc), &rc->paint, &img->surface, 0, 0, img->surface.width, img->surface.height, GFX_TRANS_NONE, x, y);
        img_release(img);
    }
    rc_release(rc);
    return RUNTIME_STATUS_NORMAL;
}

static s32 n_drawRegion(Runtime *runtime, JClass *clazz) {
    s32 xSrc = ARG_I(4), ySrc = ARG_I(5), w = ARG_I(6), h = ARG_I(7), transform = ARG_I(8);
    s32 x = ARG_I(9), y = ARG_I(10), anchor = ARG_I(11);
    CTX(0);
    RenderImage *img = img_acquire(ARG_L(2));
    if (img) {
        int outW, outH;
        gfx_transformed_size(w, h, transform, &outW, &outH);
        anchor_box(anchor, outW, outH, &x, &y);
        gfx_blit(S(rc), &rc->paint, &img->surface, xSrc, ySrc, w, h, transform, x, y);
        img_release(img);
    }
    rc_release(rc);
    return RUNTIME_STATUS_NORMAL;
}

static s32 n_drawRGB(Runtime *runtime, JClass *clazz) {
    Instance *arr = ARG_R(2);
    s32 offset = ARG_I(3), scan = ARG_I(4), x = ARG_I(5), y = ARG_I(6), w = ARG_I(7), h = ARG_I(8), alpha = ARG_I(9);
    CTX(0);
    if (arr) gfx_blit_rgb(S(rc), &rc->paint, (const int32_t *)arr->arr_body, arr->arr_length, offset, scan, x, y, w, h, alpha);
    rc_release(rc);
    return RUNTIME_STATUS_NORMAL;
}

static s32 n_getImageRGB(Runtime *runtime, JClass *clazz) {
    Instance *arr = ARG_R(2);
    s32 offset = ARG_I(3), scan = ARG_I(4), x = ARG_I(5), y = ARG_I(6), w = ARG_I(7), h = ARG_I(8);
    RenderImage *img = img_acquire(ARG_L(0));
    if (img && arr) gfx_read_rgb(&img->surface, (int32_t *)arr->arr_body, arr->arr_length, offset, scan, x, y, w, h);
    img_release(img);
    return RUNTIME_STATUS_NORMAL;
}

/// Read pixels of the surface behind a Graphics (Nokia DirectGraphics.getPixels).
static s32 n_getContextRGB(Runtime *runtime, JClass *clazz) {
    Instance *arr = ARG_R(2);
    s32 offset = ARG_I(3), scan = ARG_I(4), x = ARG_I(5), y = ARG_I(6), w = ARG_I(7), h = ARG_I(8);
    CTX(0);
    if (arr) gfx_read_rgb(S(rc), (int32_t *)arr->arr_body, arr->arr_length, offset, scan, x, y, w, h);
    rc_release(rc);
    return RUNTIME_STATUS_NORMAL;
}

static s32 n_vibrate(Runtime *runtime, JClass *clazz) {
    gfx_platform_vibrate(ARG_I(0));
    return RUNTIME_STATUS_NORMAL;
}

/// A PNG of the image as base64 text, for ImageItem and friends.
static s32 n_imagePngBase64(Runtime *runtime, JClass *clazz) {
    static const char T[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    RenderImage *img = img_acquire(ARG_L(0));
    Instance *result = NULL;
    if (img) {
        int32_t len = 0;
        uint8_t *png = gfx_png_encode(img->surface.pixels, img->surface.width, img->surface.height, &len);
        if (png) {
            size_t size = ((size_t)len + 2) / 3 * 4 + 1;
            char *text = (char *)malloc(size);
            if (text) {
                char *o = text;
                for (int32_t i = 0; i < len; i += 3) {
                    uint32_t v = (uint32_t)png[i] << 16;
                    if (i + 1 < len) v |= (uint32_t)png[i + 1] << 8;
                    if (i + 2 < len) v |= png[i + 2];
                    *o++ = T[(v >> 18) & 63];
                    *o++ = T[(v >> 12) & 63];
                    *o++ = i + 1 < len ? T[(v >> 6) & 63] : '=';
                    *o++ = i + 2 < len ? T[v & 63] : '=';
                }
                *o = 0;
                result = jstring_create_cstr(text, runtime);
                free(text);
            }
            free(png);
        }
        img_release(img);
    }
    push_ref(runtime->stack, result);
    return RUNTIME_STATUS_NORMAL;
}

// ============================================================
// Table
// ============================================================

#define CLS "javax/microedition/lcdui/NativeBridge"

static java_native_method j2me_render_methods[] = {
    {CLS, "createContext",    "(II)J",                     n_createContext},
    {CLS, "destroyContext",   "(J)V",                      n_destroyContext},
    {CLS, "flushToScreen",    "(J)V",                      n_flushToScreen},
    {CLS, "setColor",         "(JI)V",                     n_setColor},
    {CLS, "setClip",          "(JIIII)V",                  n_setClip},
    {CLS, "setStrokeStyle",   "(JI)V",                     n_setStrokeStyle},
    {CLS, "drawLine",         "(JIIII)V",                  n_drawLine},
    {CLS, "fillRect",         "(JIIII)V",                  n_fillRect},
    {CLS, "drawRect",         "(JIIII)V",                  n_drawRect},
    {CLS, "fillArc",          "(JIIIIII)V",                n_fillArc},
    {CLS, "drawArc",          "(JIIIIII)V",                n_drawArc},
    {CLS, "fillRoundRect",    "(JIIIIII)V",                n_fillRoundRect},
    {CLS, "drawRoundRect",    "(JIIIIII)V",                n_drawRoundRect},
    {CLS, "fillTriangle",     "(JIIIIII)V",                n_fillTriangle},
    {CLS, "fillPolygon",      "(J[I[II)V",                 n_fillPolygon},
    {CLS, "drawPolygon",      "(J[I[II)V",                 n_drawPolygon},
    {CLS, "copyArea",         "(JIIIIII)V",                n_copyArea},
    {CLS, "setFont",          "(JIII)V",                   n_setFont},
    {CLS, "drawString",       "(JLjava/lang/String;III)V", n_drawString},
    {CLS, "getStringWidth",   "(JLjava/lang/String;)I",    n_getStringWidth},
    {CLS, "getFontHeight",    "(J)I",                      n_getFontHeight},
    {CLS, "getFontAscent",    "(J)I",                      n_getFontAscent},
    {CLS, "fontHeight",       "(III)I",                    n_fontHeight},
    {CLS, "fontAscent",       "(III)I",                    n_fontAscent},
    {CLS, "charWidth64",      "(IIII)I",                   n_charWidth64},
    {CLS, "stringWidthFont",  "(IIILjava/lang/String;)I",  n_stringWidthFont},
    {CLS, "createMutableImage",      "(II)J",     n_createMutableImage},
    {CLS, "createFilledImage",       "(III)J",    n_createFilledImage},
    {CLS, "createImageFromData",     "([BII)J",   n_createImageFromData},
    {CLS, "createImageFromRGB",      "([IIIZ)J",  n_createImageFromRGB},
    {CLS, "createImageFromRegion",   "(JIIIII)J", n_createImageFromRegion},
    {CLS, "destroyImage",            "(J)V",      n_destroyImage},
    {CLS, "imagePngBase64",          "(J)Ljava/lang/String;", n_imagePngBase64},
    {CLS, "getImageWidth",           "(J)I",      n_getImageWidth},
    {CLS, "getImageHeight",          "(J)I",      n_getImageHeight},
    {CLS, "getImageContext",         "(J)J",      n_getImageContext},
    {CLS, "drawImage",        "(JJIII)V",          n_drawImage},
    {CLS, "drawRegion",       "(JJIIIIIIII)V",     n_drawRegion},
    {CLS, "drawRGB",          "(J[IIIIIIII)V",     n_drawRGB},
    {CLS, "getImageRGB",      "(J[IIIIIII)V",      n_getImageRGB},
    {CLS, "getContextRGB",    "(J[IIIIIII)V",      n_getContextRGB},
    {CLS, "vibrate",          "(I)V",              n_vibrate},
};

#undef CLS

void j2me_render_reg_natives(MiniJVM *jvm) {
    native_reg_lib(jvm, j2me_render_methods, sizeof(j2me_render_methods) / sizeof(java_native_method));
}

int j2me_render_get_pixels(int64_t ctxHandle, uint8_t **pixels, int *width, int *height) {
    RenderContext *rc = rc_acquire(ctxHandle);
    if (!rc) return 0;
    *pixels = (uint8_t *)rc->target->surface.pixels;
    *width = rc->target->surface.width;
    *height = rc->target->surface.height;
    rc_release(rc);
    return 1;
}

void j2me_render_stop(void) {
    g_render_stopped = 1;
}

void j2me_render_cleanup(void) {
    process_dead_shells();
    process_dead_shells();

    spin_lock(&g_track_lock);
    int rc_count = g_live_rc_count, img_count = g_live_img_count;
    for (int i = 0; i < g_live_rc_count; i++) free(g_live_rc[i]);
    g_live_rc_count = 0;
    for (int i = 0; i < g_live_img_count; i++) {
        RenderImage *img = g_live_img[i];
        gfx_surface_free(&img->surface);
        free(img);
    }
    g_live_img_count = 0;
    spin_unlock(&g_track_lock);

    atomic_store_explicit(&g_dead_rc_gen0, NULL, memory_order_relaxed);
    g_dead_rc_gen1 = NULL;
    atomic_store_explicit(&g_dead_img_gen0, NULL, memory_order_relaxed);
    g_dead_img_gen1 = NULL;
    __atomic_store_n(&g_native_extra_heap, 0, __ATOMIC_RELAXED);

    gfx_platform_reset();
    gfx_text_reset();
    g_render_stopped = 0;
    printf("[Graphics] Session cleanup: %d contexts, %d images released\n", rc_count, img_count);
}
