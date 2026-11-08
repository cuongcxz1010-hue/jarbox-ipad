//
// j2me_render.m — Core Graphics rendering bridge for J2ME LCDUI
//
// Maps J2ME Graphics operations to iOS Core Graphics (CGContext).
// Analogous to J2ME-Loader's mapping of Graphics → Android Canvas (Skia).
//

#import <CoreGraphics/CoreGraphics.h>
#import <CoreText/CoreText.h>
#import <ImageIO/ImageIO.h>
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <CoreHaptics/CoreHaptics.h>
#include "j2me_render.h"
#include "jvm.h"
#include "jvm_util.h"
#include <stdio.h>
#include <stdatomic.h>
#include <pthread.h>

// ============================================================
// Internal structures
// ============================================================
// Thread safety is provided by three complementary mechanisms:
//
// 1. Refcounting (rc_acquire/rc_release, img_acquire/img_release):
//    Prevents use-after-free of CF resources. GC finalize() releases
//    the owner reference; struct stays alive while native code uses it.
//
// 2. paintLock (Java synchronized in Canvas.doPaint/flushBuffer/destroyContext):
//    Prevents concurrent CGContext access on the same Canvas.
//    CGContext is NOT thread-safe; concurrent Save/RestoreGState corrupts it.
//
// 3. Two-generation deferred shell free (process_dead_shells):
//    When refcount reaches 0, CF resources are released immediately but
//    the struct shell is kept for one frame to prevent ABA in acquire.

typedef struct RenderContext {
    CGContextRef ctx;
    int width;
    int height;
    CTFontRef font;
    float fontSize;
    int fontStyle;
    int clipSaved;
    int ownsPixels;
    // Mirror of the Graphics state, for the software blitters and for
    // re-applying after CGContextRestoreGState (setClip).
    int argb;
    int dashed;
    int clipX, clipY, clipW, clipH;
    _Atomic int32_t refcount;
    struct RenderContext *next_dead;
} RenderContext;

typedef struct RenderImage {
    CGContextRef ctx;
    int width;
    int height;
    int isMutable;
    _Atomic int32_t refcount;
    struct RenderImage *next_dead;
} RenderImage;

static j2me_flush_callback g_flush_callback = NULL;
static CGColorSpaceRef g_colorSpace = NULL;

// Set by jvm_bridge before native cleanup. All acquire functions
// check this and return NULL, so zombie threads can't touch freed resources.
static volatile int g_render_stopped = 0;

// Global tracking arrays for forced cleanup between game sessions.
// Protected by g_track_lock. Entries are added on create, removed on release (refcount→0).
#define TRACK_MAX 8192
static RenderContext *g_live_rc[TRACK_MAX];
static int            g_live_rc_count = 0;
static RenderImage   *g_live_img[TRACK_MAX];
static int            g_live_img_count = 0;
static spinlock_t     g_track_lock = {0, 0, 0};

static void track_rc(RenderContext *rc) {
    spin_lock(&g_track_lock);
    if (g_live_rc_count < TRACK_MAX) g_live_rc[g_live_rc_count++] = rc;
    spin_unlock(&g_track_lock);
}
static void untrack_rc(RenderContext *rc) {
    spin_lock(&g_track_lock);
    for (int i = 0; i < g_live_rc_count; i++) {
        if (g_live_rc[i] == rc) {
            g_live_rc[i] = g_live_rc[--g_live_rc_count];
            break;
        }
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
        if (g_live_img[i] == img) {
            g_live_img[i] = g_live_img[--g_live_img_count];
            break;
        }
    }
    spin_unlock(&g_track_lock);
}

// ============================================================
// Native memory counter — visible to miniJVM GC via gc_sum_heap()
// ============================================================
extern s64 g_native_extra_heap;

static inline void native_heap_add(s32 bytes) {
    __atomic_fetch_add(&g_native_extra_heap, (s64)bytes, __ATOMIC_RELAXED);
}
static inline void native_heap_sub(s32 bytes) {
    __atomic_fetch_sub(&g_native_extra_heap, (s64)bytes, __ATOMIC_RELAXED);
}

// ============================================================
// Dead shell reclamation (two-generation)
// ============================================================
// When refcount reaches 0, CF resources are released immediately but
// the struct shell is kept alive (ABA prevention). Dead shells are
// pushed onto gen0 (atomic, any thread). Each flushToScreen call:
//   1. free(gen1) — shells dead for 1+ frames, safe to free
//   2. gen1 = gen0; gen0 = NULL — promote current to previous
// This bounds the leak to at most 2 frames' worth of shells.

static _Atomic(RenderContext *) g_dead_rc_gen0 = NULL;
static RenderContext            *g_dead_rc_gen1 = NULL;
static _Atomic(RenderImage *)   g_dead_img_gen0 = NULL;
static RenderImage              *g_dead_img_gen1 = NULL;

static void enqueue_dead_rc(RenderContext *rc) {
    RenderContext *old;
    do {
        old = atomic_load_explicit(&g_dead_rc_gen0, memory_order_relaxed);
        rc->next_dead = old;
    } while (!atomic_compare_exchange_weak_explicit(
        &g_dead_rc_gen0, &old, rc,
        memory_order_release, memory_order_relaxed));
}

static void enqueue_dead_img(RenderImage *img) {
    RenderImage *old;
    do {
        old = atomic_load_explicit(&g_dead_img_gen0, memory_order_relaxed);
        img->next_dead = old;
    } while (!atomic_compare_exchange_weak_explicit(
        &g_dead_img_gen0, &old, img,
        memory_order_release, memory_order_relaxed));
}

static void process_dead_shells(void) {
    // Free gen1 (dead for 1+ frames — all in-flight acquires have completed)
    RenderContext *rc = g_dead_rc_gen1;
    while (rc) { RenderContext *next = rc->next_dead; free(rc); rc = next; }
    RenderImage *img = g_dead_img_gen1;
    while (img) { RenderImage *next = img->next_dead; free(img); img = next; }
    // Promote gen0 → gen1
    g_dead_rc_gen1 = atomic_exchange_explicit(&g_dead_rc_gen0, NULL, memory_order_acquire);
    g_dead_img_gen1 = atomic_exchange_explicit(&g_dead_img_gen0, NULL, memory_order_acquire);
}

// ============================================================
// Reference counting: acquire / release
// ============================================================

static inline RenderContext *rc_acquire(s64 handle) {
    if (g_render_stopped || handle == 0) return NULL;
    RenderContext *rc = (RenderContext *)(intptr_t)handle;
    int32_t old = atomic_load_explicit(&rc->refcount, memory_order_relaxed);
    do {
        if (old <= 0) return NULL;
    } while (!atomic_compare_exchange_weak_explicit(
        &rc->refcount, &old, old + 1,
        memory_order_acquire, memory_order_relaxed));
    return rc;
}

static inline void rc_release(RenderContext *rc) {
    if (!rc) return;
    if (atomic_fetch_sub_explicit(&rc->refcount, 1, memory_order_release) == 1) {
        atomic_thread_fence(memory_order_acquire);
        untrack_rc(rc); // remove from live tracking before freeing resources
        int pixels = rc->ownsPixels ? rc->width * rc->height * 4 : 0;
        CGContextRef ctx = rc->ctx;
        CTFontRef font = __atomic_exchange_n(&rc->font, NULL, __ATOMIC_ACQ_REL);
        rc->ctx = NULL;
        rc->ownsPixels = 0;
        if (ctx) CGContextRelease(ctx);
        if (font) CFRelease(font);
        if (pixels > 0) native_heap_sub(pixels);
        enqueue_dead_rc(rc);
    }
}

static inline RenderImage *img_acquire(s64 handle) {
    if (g_render_stopped || handle == 0) return NULL;
    RenderImage *img = (RenderImage *)(intptr_t)handle;
    int32_t old = atomic_load_explicit(&img->refcount, memory_order_relaxed);
    do {
        if (old <= 0) return NULL;
    } while (!atomic_compare_exchange_weak_explicit(
        &img->refcount, &old, old + 1,
        memory_order_acquire, memory_order_relaxed));
    return img;
}

static inline void img_release(RenderImage *img) {
    if (!img) return;
    if (atomic_fetch_sub_explicit(&img->refcount, 1, memory_order_release) == 1) {
        atomic_thread_fence(memory_order_acquire);
        untrack_img(img); // remove from live tracking before freeing resources
        int pixels = img->width * img->height * 4;
        CGContextRef ctx = img->ctx;
        img->ctx = NULL;
        if (ctx) CGContextRelease(ctx);
        if (pixels > 0) native_heap_sub(pixels);
        enqueue_dead_img(img);
    }
}

// ============================================================

static CGColorSpaceRef getColorSpace(void) {
    if (!g_colorSpace) {
        g_colorSpace = CGColorSpaceCreateDeviceRGB();
    }
    return g_colorSpace;
}

void j2me_render_set_flush_callback(j2me_flush_callback callback) {
    g_flush_callback = callback;
}

// ============================================================
// Helper
// ============================================================

static inline void setColorFromARGB(CGContextRef ctx, int argb) {
    CGFloat a = ((argb >> 24) & 0xFF) / 255.0;
    CGFloat r = ((argb >> 16) & 0xFF) / 255.0;
    CGFloat g = ((argb >> 8) & 0xFF) / 255.0;
    CGFloat b = (argb & 0xFF) / 255.0;
    CGContextSetRGBFillColor(ctx, r, g, b, a);
    CGContextSetRGBStrokeColor(ctx, r, g, b, a);
}

static inline void applyDash(CGContextRef ctx, int dashed) {
    if (dashed) {
        CGFloat dash[] = {2.0, 2.0};
        CGContextSetLineDash(ctx, 0, dash, 2);
    } else {
        CGContextSetLineDash(ctx, 0, NULL, 0);
    }
}

// ============================================================
// Fonts — one shared CTFont per (face, style, size)
// ============================================================
// CTFontCreateWithName is slow; games call setFont many times per frame.

static CTFontRef g_fonts[3][4][3];
static pthread_mutex_t g_font_lock = PTHREAD_MUTEX_INITIALIZER;

static inline int faceIndex(int face) { return face == 32 ? 1 : (face == 64 ? 2 : 0); }
static inline int sizeIndex(int size) { return size == 8 ? 0 : (size == 16 ? 2 : 1); }

/// Shared font (not retained — CFRetain it to keep a reference).
static CTFontRef sharedFont(int face, int style, int size) {
    int fi = faceIndex(face), si = sizeIndex(size), st = style & 3;
    CTFontRef f = __atomic_load_n(&g_fonts[fi][st][si], __ATOMIC_ACQUIRE);
    if (f) return f;
    pthread_mutex_lock(&g_font_lock);
    f = g_fonts[fi][st][si];
    if (!f) {
        static const CGFloat sizes[3] = {10.0, 14.0, 18.0};
        CFStringRef name;
        if (fi == 1) {
            name = st == 3 ? CFSTR("Courier-BoldOblique") : st == 1 ? CFSTR("Courier-Bold")
                 : st == 2 ? CFSTR("Courier-Oblique") : CFSTR("Courier");
        } else {
            name = st == 3 ? CFSTR("Helvetica-BoldOblique") : st == 1 ? CFSTR("Helvetica-Bold")
                 : st == 2 ? CFSTR("Helvetica-Oblique") : CFSTR("Helvetica");
        }
        f = CTFontCreateWithName(name, sizes[si], NULL);
        __atomic_store_n(&g_fonts[fi][st][si], f, __ATOMIC_RELEASE);
    }
    pthread_mutex_unlock(&g_font_lock);
    return f;
}

/// Text attributes: font, colour from the context, no kerning and no
/// optional ligatures — so a string is exactly as wide as the sum of its
/// characters (Font.charWidth / stringWidth stay consistent with drawing).
static CFDictionaryRef textAttributes(CTFontRef font, int colorFromContext) {
    static CFNumberRef zeroFloat = NULL, zeroInt = NULL;
    if (!zeroFloat) {
        float z = 0; int zi = 0;
        zeroFloat = CFNumberCreate(NULL, kCFNumberFloatType, &z);
        zeroInt = CFNumberCreate(NULL, kCFNumberIntType, &zi);
    }
    CFMutableDictionaryRef attrs = CFDictionaryCreateMutable(NULL, 4,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFDictionarySetValue(attrs, kCTFontAttributeName, font);
    CFDictionarySetValue(attrs, kCTKernAttributeName, zeroFloat);
    CFDictionarySetValue(attrs, kCTLigatureAttributeName, zeroInt);
    if (colorFromContext) CFDictionarySetValue(attrs, kCTForegroundColorFromContextAttributeName, kCFBooleanTrue);
    return attrs;
}

static double measureText(CTFontRef font, CFStringRef str) {
    CFDictionaryRef attrs = textAttributes(font, 0);
    CFAttributedStringRef attrStr = CFAttributedStringCreate(NULL, str, attrs);
    CTLineRef line = CTLineCreateWithAttributedString(attrStr);
    double w = CTLineGetTypographicBounds(line, NULL, NULL, NULL);
    CFRelease(line); CFRelease(attrStr); CFRelease(attrs);
    return w;
}

// ============================================================
// Software blitters (the hot path of 2D games)
// ============================================================
// All bitmaps are 32-bit premultiplied ARGB, little-endian words
// (kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little), row 0 at
// the top. Drawing tiles and sprites by copying pixels directly is many
// times faster than creating a CGImage and calling CGContextDrawImage for
// every drawImage / drawRegion — 2D games do hundreds of those per frame.

/// d * f / 255 for all four channels (f = 0…255).
static inline uint32_t scalePixel(uint32_t d, uint32_t f) {
    uint32_t rb = (d & 0x00FF00FFu) * f + 0x00800080u;
    rb = ((rb + ((rb >> 8) & 0x00FF00FFu)) >> 8) & 0x00FF00FFu;
    uint32_t ag = ((d >> 8) & 0x00FF00FFu) * f + 0x00800080u;
    ag = (ag + ((ag >> 8) & 0x00FF00FFu)) & 0xFF00FF00u;
    return rb | ag;
}

/// Source-over of a premultiplied pixel.
static inline void blendPixel(uint32_t *d, uint32_t s) {
    uint32_t a = s >> 24;
    if (a == 255) *d = s;
    else if (a) *d = s + scalePixel(*d, 255 - a);
}

/// Current clip of a context intersected with its bounds.
static inline void clipBounds(RenderContext *rc, int *x0, int *y0, int *x1, int *y1) {
    int cx0 = rc->clipX, cy0 = rc->clipY;
    int cx1 = rc->clipX + rc->clipW, cy1 = rc->clipY + rc->clipH;
    *x0 = cx0 > 0 ? cx0 : 0;
    *y0 = cy0 > 0 ? cy0 : 0;
    *x1 = cx1 < rc->width ? cx1 : rc->width;
    *y1 = cy1 < rc->height ? cy1 : rc->height;
}

/// drawRegion / drawImage by copying pixels. (xDst, yDst) is the top-left of
/// the transformed output. Returns 0 when the caller must fall back to
/// Core Graphics (unusual bitmap, region outside the image, image drawn
/// onto itself).
static int blitRegion(RenderContext *rc, RenderImage *img, int xSrc, int ySrc, int w, int h,
                      int transform, int xDst, int yDst) {
    if (w <= 0 || h <= 0) return 1;
    if (xSrc < 0 || ySrc < 0 || xSrc + w > img->width || ySrc + h > img->height) return 0;
    uint8_t *dbase = (uint8_t *)CGBitmapContextGetData(rc->ctx);
    uint8_t *sbase = (uint8_t *)CGBitmapContextGetData(img->ctx);
    if (!dbase || !sbase || dbase == sbase) return 0;
    if (CGBitmapContextGetBitsPerPixel(rc->ctx) != 32 || CGBitmapContextGetBitsPerPixel(img->ctx) != 32) return 0;
    ptrdiff_t dstride = (ptrdiff_t)(CGBitmapContextGetBytesPerRow(rc->ctx) / 4);
    ptrdiff_t sstride = (ptrdiff_t)(CGBitmapContextGetBytesPerRow(img->ctx) / 4);

    // Output pixel (u, v) shows source pixel (sx0 + u*sxu + v*sxv, sy0 + u*syu + v*syv)
    int sx0, sy0, sxu, syu, sxv, syv, outW = w, outH = h;
    switch (transform) {
        case 0: sx0 = 0;     sy0 = 0;     sxu = 1;  syu = 0;  sxv = 0;  syv = 1;  break; // NONE
        case 2: sx0 = w - 1; sy0 = 0;     sxu = -1; syu = 0;  sxv = 0;  syv = 1;  break; // MIRROR
        case 1: sx0 = 0;     sy0 = h - 1; sxu = 1;  syu = 0;  sxv = 0;  syv = -1; break; // MIRROR_ROT180
        case 3: sx0 = w - 1; sy0 = h - 1; sxu = -1; syu = 0;  sxv = 0;  syv = -1; break; // ROT180
        case 5: sx0 = 0;     sy0 = h - 1; sxu = 0;  syu = -1; sxv = 1;  syv = 0;  outW = h; outH = w; break; // ROT90
        case 6: sx0 = w - 1; sy0 = 0;     sxu = 0;  syu = 1;  sxv = -1; syv = 0;  outW = h; outH = w; break; // ROT270
        case 7: sx0 = w - 1; sy0 = h - 1; sxu = 0;  syu = -1; sxv = -1; syv = 0;  outW = h; outH = w; break; // MIRROR_ROT90
        case 4: sx0 = 0;     sy0 = 0;     sxu = 0;  syu = 1;  sxv = 1;  syv = 0;  outW = h; outH = w; break; // MIRROR_ROT270
        default: return 0;
    }

    int cx0, cy0, cx1, cy1;
    clipBounds(rc, &cx0, &cy0, &cx1, &cy1);
    int dx0 = xDst > cx0 ? xDst : cx0, dy0 = yDst > cy0 ? yDst : cy0;
    int dx1 = xDst + outW < cx1 ? xDst + outW : cx1, dy1 = yDst + outH < cy1 ? yDst + outH : cy1;
    if (dx0 >= dx1 || dy0 >= dy1) return 1;

    ptrdiff_t stepU = sxu + syu * sstride, stepV = sxv + syv * sstride;
    const uint32_t *origin = (const uint32_t *)sbase + (ptrdiff_t)(ySrc + sy0) * sstride + (xSrc + sx0);
    uint32_t *drow = (uint32_t *)dbase + (ptrdiff_t)dy0 * dstride;
    int u0 = dx0 - xDst, count = dx1 - dx0;
    for (int dy = dy0; dy < dy1; dy++, drow += dstride) {
        const uint32_t *s = origin + (ptrdiff_t)u0 * stepU + (ptrdiff_t)(dy - yDst) * stepV;
        uint32_t *d = drow + dx0;
        if (stepU == 1) {
            for (int n = 0; n < count; n++) blendPixel(d + n, s[n]);
        } else {
            for (int n = count; n > 0; n--, d++, s += stepU) blendPixel(d, *s);
        }
    }
    return 1;
}

/// drawRGB by writing pixels directly (non-premultiplied ARGB input).
static int blitRGB(RenderContext *rc, const int32_t *src, int32_t arrLen, int32_t offset, int32_t scan,
                   int x, int y, int w, int h, int processAlpha) {
    uint8_t *dbase = (uint8_t *)CGBitmapContextGetData(rc->ctx);
    if (!dbase || CGBitmapContextGetBitsPerPixel(rc->ctx) != 32) return 0;
    ptrdiff_t dstride = (ptrdiff_t)(CGBitmapContextGetBytesPerRow(rc->ctx) / 4);
    int cx0, cy0, cx1, cy1;
    clipBounds(rc, &cx0, &cy0, &cx1, &cy1);
    int dx0 = x > cx0 ? x : cx0, dy0 = y > cy0 ? y : cy0;
    int dx1 = x + w < cx1 ? x + w : cx1, dy1 = y + h < cy1 ? y + h : cy1;
    for (int dy = dy0; dy < dy1; dy++) {
        uint32_t *d = (uint32_t *)dbase + (ptrdiff_t)dy * dstride;
        int64_t rowStart = (int64_t)offset + (int64_t)(dy - y) * scan - x;
        for (int dx = dx0; dx < dx1; dx++) {
            int64_t idx = rowStart + dx;
            if (idx < 0 || idx >= arrLen) continue;
            uint32_t argb = (uint32_t)src[idx];
            uint32_t a = processAlpha ? (argb >> 24) : 255;
            if (a == 255) d[dx] = argb | 0xFF000000u;
            else if (a) blendPixel(d + dx, (a << 24) | (scalePixel(argb, a) & 0x00FFFFFFu));
        }
    }
    return 1;
}

/// Snapshot of the screen for display. The pixels are copied (instead of
/// CGBitmapContextCreateImage) because the blitters write to the bitmap
/// directly, behind Core Graphics' copy-on-write. Opaque, so Core Animation
/// composites it without blending.
static CGImageRef copyScreenImage(RenderContext *rc) {
    void *data = CGBitmapContextGetData(rc->ctx);
    size_t bpr = CGBitmapContextGetBytesPerRow(rc->ctx);
    if (!data || CGBitmapContextGetBitsPerPixel(rc->ctx) != 32) return CGBitmapContextCreateImage(rc->ctx);
    CFDataRef pixels = CFDataCreate(NULL, data, (CFIndex)(bpr * (size_t)rc->height));
    if (!pixels) return NULL;
    CGDataProviderRef provider = CGDataProviderCreateWithCFData(pixels);
    CFRelease(pixels);
    CGImageRef image = CGImageCreate(rc->width, rc->height, 8, 32, bpr, getColorSpace(),
                                     kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little,
                                     provider, NULL, false, kCGRenderingIntentDefault);
    CGDataProviderRelease(provider);
    return image;
}

// ============================================================
// Context management
// ============================================================

static RenderContext *createRenderContext(int width, int height) {
    RenderContext *rc = (RenderContext *)calloc(1, sizeof(RenderContext));
    atomic_init(&rc->refcount, 1);
    rc->width = width;
    rc->height = height;

    CGColorSpaceRef cs = getColorSpace();
    rc->ctx = CGBitmapContextCreate(NULL, width, height, 8, width * 4,
                                     cs, kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    CGContextTranslateCTM(rc->ctx, 0, height);
    CGContextScaleCTM(rc->ctx, 1.0, -1.0);

    CGContextSetLineWidth(rc->ctx, 1.0);
    CGContextSetLineCap(rc->ctx, kCGLineCapSquare);
    CGContextSetLineJoin(rc->ctx, kCGLineJoinMiter);

    rc->fontSize = 14.0;
    rc->fontStyle = 0;
    rc->font = (CTFontRef)CFRetain(sharedFont(0, 0, 0));
    rc->ownsPixels = 1;
    rc->argb = 0xFF000000;
    rc->clipW = width;
    rc->clipH = height;

    track_rc(rc);
    native_heap_add(width * height * 4);
    return rc;
}

static void destroyRenderContext(RenderContext *rc) {
    if (!rc) return;
    rc_release(rc);
}

// ============================================================
// Image management
// ============================================================

static RenderImage *createMutableImage(int width, int height) {
    RenderImage *img = (RenderImage *)calloc(1, sizeof(RenderImage));
    atomic_init(&img->refcount, 1);
    img->width = width;
    img->height = height;
    img->isMutable = 1;

    CGColorSpaceRef cs = getColorSpace();
    img->ctx = CGBitmapContextCreate(NULL, width, height, 8, width * 4,
                                      cs, kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    CGContextClearRect(img->ctx, CGRectMake(0, 0, width, height));
    CGContextTranslateCTM(img->ctx, 0, height);
    CGContextScaleCTM(img->ctx, 1.0, -1.0);

    track_img(img);
    native_heap_add(width * height * 4);
    return img;
}

static RenderImage *createImageFromData(const uint8_t *data, int length) {
    RenderImage *img = (RenderImage *)calloc(1, sizeof(RenderImage));
    atomic_init(&img->refcount, 1);
    img->isMutable = 0;

    CFDataRef cfData = CFDataCreate(NULL, data, length);
    CGImageSourceRef source = CGImageSourceCreateWithData(cfData, NULL);
    CFRelease(cfData);

    CGImageRef cgImage = NULL;
    if (source) {
        cgImage = CGImageSourceCreateImageAtIndex(source, 0, NULL);
        CFRelease(source);
    }

    if (!cgImage) {
        free(img);
        return NULL;
    }

    img->width = (int)CGImageGetWidth(cgImage);
    img->height = (int)CGImageGetHeight(cgImage);

    CGColorSpaceRef cs = getColorSpace();
    img->ctx = CGBitmapContextCreate(NULL, img->width, img->height, 8, img->width * 4,
                                      cs, kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    CGContextClearRect(img->ctx, CGRectMake(0, 0, img->width, img->height));
    CGContextDrawImage(img->ctx, CGRectMake(0, 0, img->width, img->height), cgImage);
    CGImageRelease(cgImage);


    track_img(img);
    native_heap_add(img->width * img->height * 4);
    return img;
}

static void destroyImage(RenderImage *img) {
    if (!img) return;
    img_release(img);
}

// ============================================================
// Native method implementations
// ============================================================

static s32 n_createContext(Runtime *runtime, JClass *clazz) {
    JniEnv *env = runtime->jnienv;
    s32 w = env->localvar_getInt(runtime->localvar, 0);
    s32 h = env->localvar_getInt(runtime->localvar, 1);
    RenderContext *rc = createRenderContext(w, h);
    env->push_long(runtime->stack, (s64)(intptr_t)rc);
    return RUNTIME_STATUS_NORMAL;
}

static s32 n_destroyContext(Runtime *runtime, JClass *clazz) {
    JniEnv *env = runtime->jnienv;
    s64 handle = env->localvar_getLong_2slot(runtime->localvar, 0);
    if (g_render_stopped || handle == 0) return RUNTIME_STATUS_NORMAL;
    destroyRenderContext((RenderContext *)(intptr_t)handle);
    return RUNTIME_STATUS_NORMAL;
}

static s32 n_flushToScreen(Runtime *runtime, JClass *clazz) {
    process_dead_shells();

    JniEnv *env = runtime->jnienv;
    s64 handle = env->localvar_getLong_2slot(runtime->localvar, 0);
    RenderContext *rc = rc_acquire(handle);
    if (rc && g_flush_callback) {
        CGImageRef image = copyScreenImage(rc);
        if (image) g_flush_callback(image, rc->width, rc->height);
    }
    rc_release(rc);
    return RUNTIME_STATUS_NORMAL;
}

// --- Color & State ---

static s32 n_setColor(Runtime *runtime, JClass *clazz) {
    JniEnv *env = runtime->jnienv;
    s64 handle = env->localvar_getLong_2slot(runtime->localvar, 0);
    s32 argb = env->localvar_getInt(runtime->localvar, 2);
    RenderContext *rc = rc_acquire(handle);
    if (rc) {
        rc->argb = argb;
        setColorFromARGB(rc->ctx, argb);
    }
    rc_release(rc);
    return RUNTIME_STATUS_NORMAL;
}

static s32 n_setClip(Runtime *runtime, JClass *clazz) {
    JniEnv *env = runtime->jnienv;
    s64 handle = env->localvar_getLong_2slot(runtime->localvar, 0);
    s32 x = env->localvar_getInt(runtime->localvar, 2);
    s32 y = env->localvar_getInt(runtime->localvar, 3);
    s32 w = env->localvar_getInt(runtime->localvar, 4);
    s32 h = env->localvar_getInt(runtime->localvar, 5);
    RenderContext *rc = rc_acquire(handle);
    if (rc) {
        if (rc->clipSaved) {
            CGContextRestoreGState(rc->ctx);
        }
        CGContextSaveGState(rc->ctx);
        rc->clipSaved = 1;
        rc->clipX = x; rc->clipY = y;
        rc->clipW = w > 0 ? w : 0; rc->clipH = h > 0 ? h : 0;
        CGContextClipToRect(rc->ctx, CGRectMake(x, y, rc->clipW, rc->clipH));
        // RestoreGState above also reverted the colour and dash: set them again
        setColorFromARGB(rc->ctx, rc->argb);
        applyDash(rc->ctx, rc->dashed);
    }
    rc_release(rc);
    return RUNTIME_STATUS_NORMAL;
}

static s32 n_setStrokeStyle(Runtime *runtime, JClass *clazz) {
    JniEnv *env = runtime->jnienv;
    s64 handle = env->localvar_getLong_2slot(runtime->localvar, 0);
    s32 style = env->localvar_getInt(runtime->localvar, 2);
    RenderContext *rc = rc_acquire(handle);
    if (rc) {
        rc->dashed = style == 1;
        applyDash(rc->ctx, rc->dashed);
    }
    rc_release(rc);
    return RUNTIME_STATUS_NORMAL;
}

// --- Drawing ---

static s32 n_drawLine(Runtime *runtime, JClass *clazz) {
    JniEnv *env = runtime->jnienv;
    s64 handle = env->localvar_getLong_2slot(runtime->localvar, 0);
    s32 x1 = env->localvar_getInt(runtime->localvar, 2);
    s32 y1 = env->localvar_getInt(runtime->localvar, 3);
    s32 x2 = env->localvar_getInt(runtime->localvar, 4);
    s32 y2 = env->localvar_getInt(runtime->localvar, 5);
    RenderContext *rc = rc_acquire(handle);
    if (rc) {
        CGContextBeginPath(rc->ctx);
        CGContextMoveToPoint(rc->ctx, x1 + 0.5, y1 + 0.5);
        CGContextAddLineToPoint(rc->ctx, x2 + 0.5, y2 + 0.5);
        CGContextStrokePath(rc->ctx);
    }
    rc_release(rc);
    return RUNTIME_STATUS_NORMAL;
}

static s32 n_fillRect(Runtime *runtime, JClass *clazz) {
    JniEnv *env = runtime->jnienv;
    s64 handle = env->localvar_getLong_2slot(runtime->localvar, 0);
    s32 x = env->localvar_getInt(runtime->localvar, 2);
    s32 y = env->localvar_getInt(runtime->localvar, 3);
    s32 w = env->localvar_getInt(runtime->localvar, 4);
    s32 h = env->localvar_getInt(runtime->localvar, 5);
    RenderContext *rc = rc_acquire(handle);
    if (rc) {
        CGContextFillRect(rc->ctx, CGRectMake(x, y, w, h));
    }
    rc_release(rc);
    return RUNTIME_STATUS_NORMAL;
}

static s32 n_drawRect(Runtime *runtime, JClass *clazz) {
    JniEnv *env = runtime->jnienv;
    s64 handle = env->localvar_getLong_2slot(runtime->localvar, 0);
    s32 x = env->localvar_getInt(runtime->localvar, 2);
    s32 y = env->localvar_getInt(runtime->localvar, 3);
    s32 w = env->localvar_getInt(runtime->localvar, 4);
    s32 h = env->localvar_getInt(runtime->localvar, 5);
    RenderContext *rc = rc_acquire(handle);
    if (rc) {
        CGContextStrokeRect(rc->ctx, CGRectMake(x + 0.5, y + 0.5, w, h));
    }
    rc_release(rc);
    return RUNTIME_STATUS_NORMAL;
}

static s32 n_fillArc(Runtime *runtime, JClass *clazz) {
    JniEnv *env = runtime->jnienv;
    s64 handle = env->localvar_getLong_2slot(runtime->localvar, 0);
    s32 x = env->localvar_getInt(runtime->localvar, 2);
    s32 y = env->localvar_getInt(runtime->localvar, 3);
    s32 w = env->localvar_getInt(runtime->localvar, 4);
    s32 h = env->localvar_getInt(runtime->localvar, 5);
    s32 startAngle = env->localvar_getInt(runtime->localvar, 6);
    s32 arcAngle = env->localvar_getInt(runtime->localvar, 7);
    RenderContext *rc = rc_acquire(handle);
    if (rc) {
        CGFloat cx = x + w / 2.0, cy = y + h / 2.0;
        CGFloat rx = w / 2.0, ry = h / 2.0;
        CGContextSaveGState(rc->ctx);
        CGContextTranslateCTM(rc->ctx, cx, cy);
        CGContextScaleCTM(rc->ctx, 1.0, ry / rx);
        CGContextBeginPath(rc->ctx);
        CGContextMoveToPoint(rc->ctx, 0, 0);
        CGFloat sa = -startAngle * M_PI / 180.0;
        CGFloat ea = -(startAngle + arcAngle) * M_PI / 180.0;
        CGContextAddArc(rc->ctx, 0, 0, rx, sa, ea, arcAngle > 0 ? 1 : 0);
        CGContextClosePath(rc->ctx);
        CGContextFillPath(rc->ctx);
        CGContextRestoreGState(rc->ctx);
    }
    rc_release(rc);
    return RUNTIME_STATUS_NORMAL;
}

static s32 n_drawArc(Runtime *runtime, JClass *clazz) {
    JniEnv *env = runtime->jnienv;
    s64 handle = env->localvar_getLong_2slot(runtime->localvar, 0);
    s32 x = env->localvar_getInt(runtime->localvar, 2);
    s32 y = env->localvar_getInt(runtime->localvar, 3);
    s32 w = env->localvar_getInt(runtime->localvar, 4);
    s32 h = env->localvar_getInt(runtime->localvar, 5);
    s32 startAngle = env->localvar_getInt(runtime->localvar, 6);
    s32 arcAngle = env->localvar_getInt(runtime->localvar, 7);
    RenderContext *rc = rc_acquire(handle);
    if (rc) {
        CGFloat cx = x + w / 2.0, cy = y + h / 2.0;
        CGFloat rx = w / 2.0, ry = h / 2.0;
        CGContextSaveGState(rc->ctx);
        CGContextTranslateCTM(rc->ctx, cx, cy);
        CGContextScaleCTM(rc->ctx, 1.0, ry / rx);
        CGContextBeginPath(rc->ctx);
        CGFloat sa = -startAngle * M_PI / 180.0;
        CGFloat ea = -(startAngle + arcAngle) * M_PI / 180.0;
        CGContextAddArc(rc->ctx, 0, 0, rx, sa, ea, arcAngle > 0 ? 1 : 0);
        CGContextStrokePath(rc->ctx);
        CGContextRestoreGState(rc->ctx);
    }
    rc_release(rc);
    return RUNTIME_STATUS_NORMAL;
}

static s32 n_fillRoundRect(Runtime *runtime, JClass *clazz) {
    JniEnv *env = runtime->jnienv;
    s64 handle = env->localvar_getLong_2slot(runtime->localvar, 0);
    s32 x = env->localvar_getInt(runtime->localvar, 2);
    s32 y = env->localvar_getInt(runtime->localvar, 3);
    s32 w = env->localvar_getInt(runtime->localvar, 4);
    s32 h = env->localvar_getInt(runtime->localvar, 5);
    s32 aw = env->localvar_getInt(runtime->localvar, 6);
    s32 ah = env->localvar_getInt(runtime->localvar, 7);
    RenderContext *rc = rc_acquire(handle);
    if (rc) {
        CGFloat radius = fmin(aw, ah) / 2.0;
        CGPathRef path = CGPathCreateWithRoundedRect(CGRectMake(x, y, w, h), radius, radius, NULL);
        CGContextAddPath(rc->ctx, path);
        CGContextFillPath(rc->ctx);
        CGPathRelease(path);
    }
    rc_release(rc);
    return RUNTIME_STATUS_NORMAL;
}

static s32 n_drawRoundRect(Runtime *runtime, JClass *clazz) {
    JniEnv *env = runtime->jnienv;
    s64 handle = env->localvar_getLong_2slot(runtime->localvar, 0);
    s32 x = env->localvar_getInt(runtime->localvar, 2);
    s32 y = env->localvar_getInt(runtime->localvar, 3);
    s32 w = env->localvar_getInt(runtime->localvar, 4);
    s32 h = env->localvar_getInt(runtime->localvar, 5);
    s32 aw = env->localvar_getInt(runtime->localvar, 6);
    s32 ah = env->localvar_getInt(runtime->localvar, 7);
    RenderContext *rc = rc_acquire(handle);
    if (rc) {
        CGFloat radius = fmin(aw, ah) / 2.0;
        CGPathRef path = CGPathCreateWithRoundedRect(CGRectMake(x + 0.5, y + 0.5, w, h), radius, radius, NULL);
        CGContextAddPath(rc->ctx, path);
        CGContextStrokePath(rc->ctx);
        CGPathRelease(path);
    }
    rc_release(rc);
    return RUNTIME_STATUS_NORMAL;
}

// --- Text ---

static s32 n_setFont(Runtime *runtime, JClass *clazz) {
    JniEnv *env = runtime->jnienv;
    s64 handle = env->localvar_getLong_2slot(runtime->localvar, 0);
    s32 face = env->localvar_getInt(runtime->localvar, 2);
    s32 style = env->localvar_getInt(runtime->localvar, 3);
    s32 size = env->localvar_getInt(runtime->localvar, 4);
    RenderContext *rc = rc_acquire(handle);
    if (rc) {
        CTFontRef newFont = sharedFont(face, style, size);
        if (newFont != rc->font) {
            CFRetain(newFont);
            CTFontRef oldFont = __atomic_exchange_n(&rc->font, newFont, __ATOMIC_ACQ_REL);
            if (oldFont) CFRelease(oldFont);
        }
        rc->fontSize = CTFontGetSize(newFont);
        rc->fontStyle = style;
    }
    rc_release(rc);
    return RUNTIME_STATUS_NORMAL;
}

// --- Font metrics without a context (Font.getHeight / charWidth / stringWidth)

static s32 n_fontHeight(Runtime *runtime, JClass *clazz) {
    JniEnv *env = runtime->jnienv;
    CTFontRef f = sharedFont(env->localvar_getInt(runtime->localvar, 0),
                             env->localvar_getInt(runtime->localvar, 1),
                             env->localvar_getInt(runtime->localvar, 2));
    env->push_int(runtime->stack, (s32)ceil(CTFontGetAscent(f) + CTFontGetDescent(f)));
    return RUNTIME_STATUS_NORMAL;
}

static s32 n_fontAscent(Runtime *runtime, JClass *clazz) {
    JniEnv *env = runtime->jnienv;
    CTFontRef f = sharedFont(env->localvar_getInt(runtime->localvar, 0),
                             env->localvar_getInt(runtime->localvar, 1),
                             env->localvar_getInt(runtime->localvar, 2));
    env->push_int(runtime->stack, (s32)ceil(CTFontGetAscent(f)));
    return RUNTIME_STATUS_NORMAL;
}

/// Advance of one character in 1/64 pixel.
static s32 n_charWidth64(Runtime *runtime, JClass *clazz) {
    JniEnv *env = runtime->jnienv;
    CTFontRef f = sharedFont(env->localvar_getInt(runtime->localvar, 0),
                             env->localvar_getInt(runtime->localvar, 1),
                             env->localvar_getInt(runtime->localvar, 2));
    UniChar ch = (UniChar)env->localvar_getInt(runtime->localvar, 3);
    CFStringRef str = CFStringCreateWithCharacters(NULL, &ch, 1);
    double w = str ? measureText(f, str) : 0;
    if (str) CFRelease(str);
    env->push_int(runtime->stack, (s32)lround(w * 64.0));
    return RUNTIME_STATUS_NORMAL;
}

/// Width of a whole string in pixels (for text outside the cached range).
static s32 n_stringWidthFont(Runtime *runtime, JClass *clazz) {
    JniEnv *env = runtime->jnienv;
    CTFontRef f = sharedFont(env->localvar_getInt(runtime->localvar, 0),
                             env->localvar_getInt(runtime->localvar, 1),
                             env->localvar_getInt(runtime->localvar, 2));
    Instance *jstr = env->localvar_getRefer(runtime->localvar, 3);
    if (!jstr) { env->push_int(runtime->stack, 0); return RUNTIME_STATUS_NORMAL; }
    Utf8String *ustr = utf8_create();
    env->jstring_2_utf8(jstr, ustr, runtime);
    CFStringRef str = CFStringCreateWithCString(NULL, utf8_cstr(ustr), kCFStringEncodingUTF8);
    utf8_destroy(ustr);
    double w = str ? measureText(f, str) : 0;
    if (str) CFRelease(str);
    env->push_int(runtime->stack, (s32)lround(w));
    return RUNTIME_STATUS_NORMAL;
}

static s32 n_drawString(Runtime *runtime, JClass *clazz) {
    JniEnv *env = runtime->jnienv;
    s64 handle = env->localvar_getLong_2slot(runtime->localvar, 0);
    Instance *jstr = env->localvar_getRefer(runtime->localvar, 2);
    s32 x = env->localvar_getInt(runtime->localvar, 3);
    s32 y = env->localvar_getInt(runtime->localvar, 4);
    s32 anchor = env->localvar_getInt(runtime->localvar, 5);
    RenderContext *rc = rc_acquire(handle);

    if (!rc || !jstr) { rc_release(rc); return RUNTIME_STATUS_NORMAL; }

    Utf8String *ustr = utf8_create();
    env->jstring_2_utf8(jstr, ustr, runtime);
    CFStringRef str = CFStringCreateWithCString(NULL, utf8_cstr(ustr), kCFStringEncodingUTF8);
    utf8_destroy(ustr);
    if (!str) { rc_release(rc); return RUNTIME_STATUS_NORMAL; }

    CFDictionaryRef attrs = textAttributes(rc->font, 1);

    CFAttributedStringRef attrStr = CFAttributedStringCreate(NULL, str, attrs);
    CTLineRef line = CTLineCreateWithAttributedString(attrStr);

    CGFloat ascent, descent, leading;
    double textWidth = CTLineGetTypographicBounds(line, &ascent, &descent, &leading);
    CGFloat textHeight = ascent + descent;

    CGFloat dx = x, dy = y;
    if (anchor & 1) dx -= textWidth / 2;
    if (anchor & 8) dx -= textWidth;
    if (anchor & 4) dy -= 0;
    if (anchor & 32) dy -= textHeight;
    if (anchor == 0 || (anchor & 16)) dy += 0;

    CGContextSaveGState(rc->ctx);
    CGContextTranslateCTM(rc->ctx, dx, dy + ascent);
    CGContextScaleCTM(rc->ctx, 1.0, -1.0);
    CGContextSetTextPosition(rc->ctx, 0, 0);
    CTLineDraw(line, rc->ctx);
    CGContextRestoreGState(rc->ctx);

    CFRelease(line);
    CFRelease(attrStr);
    CFRelease(attrs);
    CFRelease(str);
    rc_release(rc);
    return RUNTIME_STATUS_NORMAL;
}

static s32 n_getStringWidth(Runtime *runtime, JClass *clazz) {
    JniEnv *env = runtime->jnienv;
    s64 handle = env->localvar_getLong_2slot(runtime->localvar, 0);
    Instance *jstr = env->localvar_getRefer(runtime->localvar, 2);
    RenderContext *rc = rc_acquire(handle);

    if (!rc || !jstr) { rc_release(rc); env->push_int(runtime->stack, 0); return RUNTIME_STATUS_NORMAL; }

    Utf8String *ustr = utf8_create();
    env->jstring_2_utf8(jstr, ustr, runtime);
    CFStringRef str = CFStringCreateWithCString(NULL, utf8_cstr(ustr), kCFStringEncodingUTF8);
    utf8_destroy(ustr);
    if (!str) { rc_release(rc); env->push_int(runtime->stack, 0); return RUNTIME_STATUS_NORMAL; }

    double w = measureText(rc->font, str);
    CFRelease(str);
    rc_release(rc);
    env->push_int(runtime->stack, (s32)lround(w));
    return RUNTIME_STATUS_NORMAL;
}

static s32 n_getFontHeight(Runtime *runtime, JClass *clazz) {
    JniEnv *env = runtime->jnienv;
    s64 handle = env->localvar_getLong_2slot(runtime->localvar, 0);
    RenderContext *rc = rc_acquire(handle);
    if (!rc) { env->push_int(runtime->stack, 14); return RUNTIME_STATUS_NORMAL; }
    CGFloat ascent = CTFontGetAscent(rc->font);
    CGFloat descent = CTFontGetDescent(rc->font);
    rc_release(rc);
    env->push_int(runtime->stack, (s32)ceil(ascent + descent));
    return RUNTIME_STATUS_NORMAL;
}

static s32 n_getFontAscent(Runtime *runtime, JClass *clazz) {
    JniEnv *env = runtime->jnienv;
    s64 handle = env->localvar_getLong_2slot(runtime->localvar, 0);
    RenderContext *rc = rc_acquire(handle);
    if (!rc) { env->push_int(runtime->stack, 12); return RUNTIME_STATUS_NORMAL; }
    CGFloat ascent = CTFontGetAscent(rc->font);
    rc_release(rc);
    env->push_int(runtime->stack, (s32)ceil(ascent));
    return RUNTIME_STATUS_NORMAL;
}

// --- Image ---

static s32 n_createMutableImage(Runtime *runtime, JClass *clazz) {
    JniEnv *env = runtime->jnienv;
    s32 w = env->localvar_getInt(runtime->localvar, 0);
    s32 h = env->localvar_getInt(runtime->localvar, 1);
    RenderImage *img = createMutableImage(w, h);
    env->push_long(runtime->stack, (s64)(intptr_t)img);
    return RUNTIME_STATUS_NORMAL;
}

static s32 n_createImageFromData(Runtime *runtime, JClass *clazz) {
    JniEnv *env = runtime->jnienv;
    Instance *arr = env->localvar_getRefer(runtime->localvar, 0);
    s32 offset = env->localvar_getInt(runtime->localvar, 1);
    s32 length = env->localvar_getInt(runtime->localvar, 2);
    if (!arr) { env->push_long(runtime->stack, 0); return RUNTIME_STATUS_NORMAL; }
    c8 *arrBody = arr->arr_body;
    RenderImage *img = createImageFromData((uint8_t *)arrBody + offset, length);
    env->push_long(runtime->stack, (s64)(intptr_t)img);
    return RUNTIME_STATUS_NORMAL;
}

static s32 n_destroyImage(Runtime *runtime, JClass *clazz) {
    JniEnv *env = runtime->jnienv;
    s64 handle = env->localvar_getLong_2slot(runtime->localvar, 0);
    if (g_render_stopped || handle == 0) return RUNTIME_STATUS_NORMAL;
    destroyImage((RenderImage *)(intptr_t)handle);
    return RUNTIME_STATUS_NORMAL;
}

static s32 n_getImageWidth(Runtime *runtime, JClass *clazz) {
    JniEnv *env = runtime->jnienv;
    s64 handle = env->localvar_getLong_2slot(runtime->localvar, 0);
    RenderImage *img = img_acquire(handle);
    env->push_int(runtime->stack, img ? img->width : 0);
    img_release(img);
    return RUNTIME_STATUS_NORMAL;
}

static s32 n_getImageHeight(Runtime *runtime, JClass *clazz) {
    JniEnv *env = runtime->jnienv;
    s64 handle = env->localvar_getLong_2slot(runtime->localvar, 0);
    RenderImage *img = img_acquire(handle);
    env->push_int(runtime->stack, img ? img->height : 0);
    img_release(img);
    return RUNTIME_STATUS_NORMAL;
}

static s32 n_getImageContext(Runtime *runtime, JClass *clazz) {
    JniEnv *env = runtime->jnienv;
    s64 handle = env->localvar_getLong_2slot(runtime->localvar, 0);
    RenderImage *img = img_acquire(handle);
    if (img && img->isMutable && img->ctx) {
        RenderContext *rc = (RenderContext *)calloc(1, sizeof(RenderContext));
        atomic_init(&rc->refcount, 1);
        rc->ctx = img->ctx;
        CGContextRetain(rc->ctx);
        rc->width = img->width;
        rc->height = img->height;
        rc->fontSize = 14.0;
        rc->font = (CTFontRef)CFRetain(sharedFont(0, 0, 0));
        rc->ownsPixels = 0; // pixels owned by the RenderImage, not this wrapper
        rc->argb = 0xFF000000;
        rc->clipW = img->width;
        rc->clipH = img->height;
        track_rc(rc);
        img_release(img);
        env->push_long(runtime->stack, (s64)(intptr_t)rc);
    } else {
        img_release(img);
        env->push_long(runtime->stack, 0);
    }
    return RUNTIME_STATUS_NORMAL;
}

static s32 n_drawImage(Runtime *runtime, JClass *clazz) {
    JniEnv *env = runtime->jnienv;
    s64 ctxHandle = env->localvar_getLong_2slot(runtime->localvar, 0);
    s64 imgHandle = env->localvar_getLong_2slot(runtime->localvar, 2);
    s32 x = env->localvar_getInt(runtime->localvar, 4);
    s32 y = env->localvar_getInt(runtime->localvar, 5);
    s32 anchor = env->localvar_getInt(runtime->localvar, 6);

    RenderContext *rc = rc_acquire(ctxHandle);
    RenderImage *img = img_acquire(imgHandle);
    if (!rc || !img) { img_release(img); rc_release(rc); return RUNTIME_STATUS_NORMAL; }

    int imgW = img->width, imgH = img->height;
    if (anchor & 1) x -= imgW / 2;
    if (anchor & 8) x -= imgW;
    if (anchor & 2) y -= imgH / 2;
    if (anchor & 32) y -= imgH;

    if (blitRegion(rc, img, 0, 0, imgW, imgH, 0, x, y)) {
        img_release(img);
        rc_release(rc);
        return RUNTIME_STATUS_NORMAL;
    }

    CGImageRef cgImage = CGBitmapContextCreateImage(img->ctx);
    if (cgImage) {
        CGContextSaveGState(rc->ctx);
        CGContextTranslateCTM(rc->ctx, x, y + imgH);
        CGContextScaleCTM(rc->ctx, 1.0, -1.0);
        CGContextDrawImage(rc->ctx, CGRectMake(0, 0, imgW, imgH), cgImage);
        CGContextRestoreGState(rc->ctx);
        CGImageRelease(cgImage);
    }
    img_release(img);
    rc_release(rc);
    return RUNTIME_STATUS_NORMAL;
}

// --- drawRegion ---

#define TRANS_NONE           0
#define TRANS_ROT90          5
#define TRANS_ROT180         3
#define TRANS_ROT270         6
#define TRANS_MIRROR         2
#define TRANS_MIRROR_ROT90   7
#define TRANS_MIRROR_ROT180  1
#define TRANS_MIRROR_ROT270  4

static s32 n_drawRegion(Runtime *runtime, JClass *clazz) {
    JniEnv *env = runtime->jnienv;
    s64 ctxHandle = env->localvar_getLong_2slot(runtime->localvar, 0);
    s64 imgHandle = env->localvar_getLong_2slot(runtime->localvar, 2);
    s32 xSrc = env->localvar_getInt(runtime->localvar, 4);
    s32 ySrc = env->localvar_getInt(runtime->localvar, 5);
    s32 wSrc = env->localvar_getInt(runtime->localvar, 6);
    s32 hSrc = env->localvar_getInt(runtime->localvar, 7);
    s32 transform = env->localvar_getInt(runtime->localvar, 8);
    s32 xDst = env->localvar_getInt(runtime->localvar, 9);
    s32 yDst = env->localvar_getInt(runtime->localvar, 10);
    s32 anchor = env->localvar_getInt(runtime->localvar, 11);

    RenderContext *rc = rc_acquire(ctxHandle);
    RenderImage *img = img_acquire(imgHandle);
    if (!rc || !img) { img_release(img); rc_release(rc); return RUNTIME_STATUS_NORMAL; }
    CGContextRef rctx = rc->ctx;
    CGContextRef ictx = img->ctx;

    int outW = wSrc, outH = hSrc;
    if (transform == TRANS_ROT90 || transform == TRANS_ROT270 ||
        transform == TRANS_MIRROR_ROT90 || transform == TRANS_MIRROR_ROT270) {
        outW = hSrc; outH = wSrc;
    }

    if (anchor & 1) xDst -= outW / 2;
    if (anchor & 8) xDst -= outW;
    if (anchor & 2) yDst -= outH / 2;
    if (anchor & 32) yDst -= outH;

    if (blitRegion(rc, img, xSrc, ySrc, wSrc, hSrc, transform, xDst, yDst)) {
        img_release(img);
        rc_release(rc);
        return RUNTIME_STATUS_NORMAL;
    }

    CGImageRef fullImage = CGBitmapContextCreateImage(ictx);
    if (!fullImage) { img_release(img); rc_release(rc); return RUNTIME_STATUS_NORMAL; }
    CGImageRef subImage = CGImageCreateWithImageInRect(fullImage, CGRectMake(xSrc, ySrc, wSrc, hSrc));
    CGImageRelease(fullImage);
    if (!subImage) { img_release(img); rc_release(rc); return RUNTIME_STATUS_NORMAL; }

    CGContextSaveGState(rctx);
    CGContextTranslateCTM(rctx, xDst, yDst);

    /* CTM transforms for J2ME drawRegion on a bottom-up CGContext.
     *
     * CGContextDrawImage maps source pixel (sx, sy) to draw-rect position
     * (sx, hSrc - sy) because CG draws top of image at higher Y.
     * We need the final CG position to match the J2ME output position.
     *
     * For each J2ME transform T, source pixel (sx, sy) should appear at
     * J2ME output position T(sx, sy) offset by (xDst, yDst).
     * The CTM must satisfy: CTM * (sx, hSrc-sy) = desired CG position.
     *
     * All operations below are relative to the initial translate(xDst, yDst). */
    switch (transform) {
        case TRANS_NONE:
            CGContextTranslateCTM(rctx, 0, hSrc);
            CGContextScaleCTM(rctx, 1, -1);
            break;
        case TRANS_MIRROR_ROT180: /* = vertical flip, cancels CG's Y-flip */
            break;
        case TRANS_MIRROR:
            CGContextTranslateCTM(rctx, wSrc, hSrc);
            CGContextScaleCTM(rctx, -1, -1);
            break;
        case TRANS_ROT180:
            CGContextTranslateCTM(rctx, wSrc, 0);
            CGContextScaleCTM(rctx, -1, 1);
            break;
        case TRANS_ROT90:
            CGContextRotateCTM(rctx, M_PI_2);
            CGContextScaleCTM(rctx, 1, -1);
            break;
        case TRANS_ROT270:
            CGContextTranslateCTM(rctx, hSrc, wSrc);
            CGContextRotateCTM(rctx, -M_PI_2);
            CGContextScaleCTM(rctx, 1, -1);
            break;
        case TRANS_MIRROR_ROT90:
            CGContextTranslateCTM(rctx, 0, wSrc);
            CGContextRotateCTM(rctx, -M_PI_2);
            break;
        case TRANS_MIRROR_ROT270:
            CGContextTranslateCTM(rctx, hSrc, 0);
            CGContextRotateCTM(rctx, M_PI_2);
            break;
    }

    CGContextDrawImage(rctx, CGRectMake(0, 0, wSrc, hSrc), subImage);
    CGContextRestoreGState(rctx);
    CGImageRelease(subImage);
    img_release(img);
    rc_release(rc);
    return RUNTIME_STATUS_NORMAL;
}

// --- drawRGB ---

static s32 n_drawRGB(Runtime *runtime, JClass *clazz) {
    JniEnv *env = runtime->jnienv;
    s64 ctxHandle = env->localvar_getLong_2slot(runtime->localvar, 0);
    Instance *arr = env->localvar_getRefer(runtime->localvar, 2);
    s32 offset = env->localvar_getInt(runtime->localvar, 3);
    s32 scanlength = env->localvar_getInt(runtime->localvar, 4);
    s32 x = env->localvar_getInt(runtime->localvar, 5);
    s32 y = env->localvar_getInt(runtime->localvar, 6);
    s32 w = env->localvar_getInt(runtime->localvar, 7);
    s32 h = env->localvar_getInt(runtime->localvar, 8);
    s32 processAlpha = env->localvar_getInt(runtime->localvar, 9);

    RenderContext *rc = rc_acquire(ctxHandle);
    if (!rc || !arr || w <= 0 || h <= 0) { rc_release(rc); return RUNTIME_STATUS_NORMAL; }

    s32 arrLen = arr->arr_length;
    s32 *srcData = (s32 *)arr->arr_body;
    if (blitRGB(rc, srcData, arrLen, offset, scanlength, x, y, w, h, processAlpha)) {
        rc_release(rc);
        return RUNTIME_STATUS_NORMAL;
    }
    CGColorSpaceRef cs = getColorSpace();
    CGContextRef tmpCtx = CGBitmapContextCreate(NULL, w, h, 8, w * 4, cs,
        kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    if (!tmpCtx) { rc_release(rc); return RUNTIME_STATUS_NORMAL; }

    uint8_t *dst = (uint8_t *)CGBitmapContextGetData(tmpCtx);
    for (int row = 0; row < h; row++) {
        for (int col = 0; col < w; col++) {
            int srcIdx = offset + row * scanlength + col;
            if (srcIdx < 0 || srcIdx >= arrLen) continue;
            s32 argb = srcData[srcIdx];
            int dstIdx = (row * w + col) * 4;
            uint8_t a = processAlpha ? ((argb >> 24) & 0xFF) : 0xFF;
            uint8_t r = (argb >> 16) & 0xFF;
            uint8_t g = (argb >> 8) & 0xFF;
            uint8_t b = argb & 0xFF;
            if (a < 255 && a > 0) {
                r = (uint8_t)(r * a / 255);
                g = (uint8_t)(g * a / 255);
                b = (uint8_t)(b * a / 255);
            } else if (a == 0) {
                r = g = b = 0;
            }
            dst[dstIdx + 0] = b;
            dst[dstIdx + 1] = g;
            dst[dstIdx + 2] = r;
            dst[dstIdx + 3] = a;
        }
    }

    CGImageRef img = CGBitmapContextCreateImage(tmpCtx);
    CGContextRelease(tmpCtx);

    if (img) {
        CGContextSaveGState(rc->ctx);
        CGContextTranslateCTM(rc->ctx, x, y + h);
        CGContextScaleCTM(rc->ctx, 1, -1);
        CGContextDrawImage(rc->ctx, CGRectMake(0, 0, w, h), img);
        CGContextRestoreGState(rc->ctx);
        CGImageRelease(img);
    }
    rc_release(rc);
    return RUNTIME_STATUS_NORMAL;
}

// --- getImageRGB ---

static s32 n_getImageRGB(Runtime *runtime, JClass *clazz) {
    JniEnv *env = runtime->jnienv;
    s64 imgHandle = env->localvar_getLong_2slot(runtime->localvar, 0);
    Instance *arr = env->localvar_getRefer(runtime->localvar, 2);
    s32 offset = env->localvar_getInt(runtime->localvar, 3);
    s32 scanlength = env->localvar_getInt(runtime->localvar, 4);
    s32 x = env->localvar_getInt(runtime->localvar, 5);
    s32 y = env->localvar_getInt(runtime->localvar, 6);
    s32 w = env->localvar_getInt(runtime->localvar, 7);
    s32 h = env->localvar_getInt(runtime->localvar, 8);

    RenderImage *img = img_acquire(imgHandle);
    if (!img || !arr) { img_release(img); return RUNTIME_STATUS_NORMAL; }

    s32 *dstData = (s32 *)arr->arr_body;
    uint8_t *srcData = (uint8_t *)CGBitmapContextGetData(img->ctx);
    int imgW = img->width;
    s32 arrLen = arr->arr_length;
    if (!srcData || x < 0 || y < 0 || w <= 0 || h <= 0 || x + w > imgW || y + h > img->height) {
        img_release(img);
        return RUNTIME_STATUS_NORMAL;
    }
    size_t srcStride = CGBitmapContextGetBytesPerRow(img->ctx);

    for (int row = 0; row < h; row++) {
        for (int col = 0; col < w; col++) {
            int64_t dstIdx = (int64_t)offset + (int64_t)row * scanlength + col;
            if (dstIdx < 0 || dstIdx >= arrLen) continue;
            size_t srcIdx = (size_t)(y + row) * srcStride + (size_t)(x + col) * 4;
            uint8_t b = srcData[srcIdx + 0];
            uint8_t g = srcData[srcIdx + 1];
            uint8_t r = srcData[srcIdx + 2];
            uint8_t a = srcData[srcIdx + 3];
            // Stored premultiplied; getRGB returns straight (non-premultiplied) ARGB
            if (a > 0 && a < 255) {
                r = (uint8_t)((r * 255 + a / 2) / a);
                g = (uint8_t)((g * 255 + a / 2) / a);
                b = (uint8_t)((b * 255 + a / 2) / a);
            }
            s32 argb = (a << 24) | (r << 16) | (g << 8) | b;
            dstData[dstIdx] = argb;
        }
    }
    img_release(img);
    return RUNTIME_STATUS_NORMAL;
}

// --- fillPolygon / drawPolygon ---

static s32 n_fillPolygon(Runtime *runtime, JClass *clazz) {
    JniEnv *env = runtime->jnienv;
    s64 handle = env->localvar_getLong_2slot(runtime->localvar, 0);
    Instance *xArr = env->localvar_getRefer(runtime->localvar, 2);
    Instance *yArr = env->localvar_getRefer(runtime->localvar, 3);
    s32 nPoints = env->localvar_getInt(runtime->localvar, 4);
    RenderContext *rc = rc_acquire(handle);
    if (!rc || !xArr || !yArr || nPoints < 3) { rc_release(rc); return RUNTIME_STATUS_NORMAL; }
    s32 *xPts = (s32 *)xArr->arr_body;
    s32 *yPts = (s32 *)yArr->arr_body;
    CGContextBeginPath(rc->ctx);
    CGContextMoveToPoint(rc->ctx, xPts[0], yPts[0]);
    for (int i = 1; i < nPoints; i++) {
        CGContextAddLineToPoint(rc->ctx, xPts[i], yPts[i]);
    }
    CGContextClosePath(rc->ctx);
    CGContextFillPath(rc->ctx);
    rc_release(rc);
    return RUNTIME_STATUS_NORMAL;
}

static s32 n_drawPolygon(Runtime *runtime, JClass *clazz) {
    JniEnv *env = runtime->jnienv;
    s64 handle = env->localvar_getLong_2slot(runtime->localvar, 0);
    Instance *xArr = env->localvar_getRefer(runtime->localvar, 2);
    Instance *yArr = env->localvar_getRefer(runtime->localvar, 3);
    s32 nPoints = env->localvar_getInt(runtime->localvar, 4);
    RenderContext *rc = rc_acquire(handle);
    if (!rc || !xArr || !yArr || nPoints < 3) { rc_release(rc); return RUNTIME_STATUS_NORMAL; }
    s32 *xPts = (s32 *)xArr->arr_body;
    s32 *yPts = (s32 *)yArr->arr_body;
    CGContextBeginPath(rc->ctx);
    CGContextMoveToPoint(rc->ctx, xPts[0] + 0.5, yPts[0] + 0.5);
    for (int i = 1; i < nPoints; i++) {
        CGContextAddLineToPoint(rc->ctx, xPts[i] + 0.5, yPts[i] + 0.5);
    }
    CGContextClosePath(rc->ctx);
    CGContextStrokePath(rc->ctx);
    rc_release(rc);
    return RUNTIME_STATUS_NORMAL;
}

// --- copyArea ---

static s32 n_copyArea(Runtime *runtime, JClass *clazz) {
    JniEnv *env = runtime->jnienv;
    s64 handle = env->localvar_getLong_2slot(runtime->localvar, 0);
    s32 xSrc = env->localvar_getInt(runtime->localvar, 2);
    s32 ySrc = env->localvar_getInt(runtime->localvar, 3);
    s32 w = env->localvar_getInt(runtime->localvar, 4);
    s32 h = env->localvar_getInt(runtime->localvar, 5);
    s32 xDst = env->localvar_getInt(runtime->localvar, 6);
    s32 yDst = env->localvar_getInt(runtime->localvar, 7);
    RenderContext *rc = rc_acquire(handle);
    if (!rc || w <= 0 || h <= 0) { rc_release(rc); return RUNTIME_STATUS_NORMAL; }
    CGImageRef fullImg = CGBitmapContextCreateImage(rc->ctx);
    if (!fullImg) { rc_release(rc); return RUNTIME_STATUS_NORMAL; }
    CGImageRef subImg = CGImageCreateWithImageInRect(fullImg, CGRectMake(xSrc, ySrc, w, h));
    CGImageRelease(fullImg);
    if (!subImg) { rc_release(rc); return RUNTIME_STATUS_NORMAL; }
    CGContextSaveGState(rc->ctx);
    CGContextTranslateCTM(rc->ctx, xDst, yDst + h);
    CGContextScaleCTM(rc->ctx, 1, -1);
    CGContextDrawImage(rc->ctx, CGRectMake(0, 0, w, h), subImg);
    CGContextRestoreGState(rc->ctx);
    CGImageRelease(subImg);
    rc_release(rc);
    return RUNTIME_STATUS_NORMAL;
}

// ============================================================
// Native method table
// ============================================================
// Haptics
// ============================================================

static CHHapticEngine *g_hapticEngine API_AVAILABLE(ios(13.0)) = nil;
static id<CHHapticPatternPlayer> g_hapticPlayer API_AVAILABLE(ios(13.0)) = nil;

static void ensureHapticEngine(void) API_AVAILABLE(ios(13.0)) {
    if (g_hapticEngine) return;
    NSError *err = nil;
    g_hapticEngine = [[CHHapticEngine alloc] initAndReturnError:&err];
    if (err) {
        printf("[Haptics] Engine init error: %s\n", err.localizedDescription.UTF8String);
        g_hapticEngine = nil;
        return;
    }
    g_hapticEngine.resetHandler = ^{
        NSError *startErr = nil;
        [g_hapticEngine startAndReturnError:&startErr];
    };
    [g_hapticEngine startAndReturnError:&err];
    if (err) {
        printf("[Haptics] Engine start error: %s\n", err.localizedDescription.UTF8String);
        g_hapticEngine = nil;
    }
}

static s32 n_vibrate(Runtime *runtime, JClass *clazz) {
    s32 durationMs = runtime->jnienv->localvar_getInt(runtime->localvar, 0);
    dispatch_async(dispatch_get_main_queue(), ^{
        if (@available(iOS 13.0, *)) {
            if (g_hapticPlayer) {
                NSError *err = nil;
                [g_hapticPlayer stopAtTime:0 error:&err];
                g_hapticPlayer = nil;
            }
            if (durationMs <= 0) return;

            ensureHapticEngine();
            if (!g_hapticEngine) return;

            float duration = durationMs / 1000.0f;
            CHHapticEventParameter *intensity =
                [[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDHapticIntensity
                                                              value:0.35f];
            CHHapticEventParameter *sharpness =
                [[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDHapticSharpness
                                                              value:0.1f];
            CHHapticEvent *event =
                [[CHHapticEvent alloc] initWithEventType:CHHapticEventTypeHapticContinuous
                                             parameters:@[intensity, sharpness]
                                           relativeTime:0
                                               duration:duration];
            NSError *err = nil;
            CHHapticPattern *pattern =
                [[CHHapticPattern alloc] initWithEvents:@[event] parameters:@[] error:&err];
            if (err) return;

            g_hapticPlayer = [g_hapticEngine createPlayerWithPattern:pattern error:&err];
            if (err) return;

            [g_hapticPlayer startAtTime:0 error:&err];
        }
    });
    return RUNTIME_STATUS_NORMAL;
}

// ============================================================

#define CLS "javax/microedition/lcdui/NativeBridge"

static java_native_method j2me_render_methods[] = {
    // Context
    {CLS, "createContext",    "(II)J",                                   n_createContext},
    {CLS, "destroyContext",   "(J)V",                                    n_destroyContext},
    {CLS, "flushToScreen",    "(J)V",                                    n_flushToScreen},

    // Color & State
    {CLS, "setColor",         "(JI)V",                                   n_setColor},
    {CLS, "setClip",          "(JIIII)V",                                n_setClip},
    {CLS, "setStrokeStyle",   "(JI)V",                                   n_setStrokeStyle},

    // Drawing
    {CLS, "drawLine",         "(JIIII)V",                                n_drawLine},
    {CLS, "fillRect",         "(JIIII)V",                                n_fillRect},
    {CLS, "drawRect",         "(JIIII)V",                                n_drawRect},
    {CLS, "fillArc",          "(JIIIIII)V",                              n_fillArc},
    {CLS, "drawArc",          "(JIIIIII)V",                              n_drawArc},
    {CLS, "fillRoundRect",    "(JIIIIII)V",                              n_fillRoundRect},
    {CLS, "drawRoundRect",    "(JIIIIII)V",                              n_drawRoundRect},

    // Text
    {CLS, "setFont",          "(JIII)V",                                 n_setFont},
    {CLS, "drawString",       "(JLjava/lang/String;III)V",               n_drawString},
    {CLS, "getStringWidth",   "(JLjava/lang/String;)I",                  n_getStringWidth},
    {CLS, "getFontHeight",    "(J)I",                                    n_getFontHeight},
    {CLS, "getFontAscent",    "(J)I",                                    n_getFontAscent},
    {CLS, "fontHeight",       "(III)I",                                  n_fontHeight},
    {CLS, "fontAscent",       "(III)I",                                  n_fontAscent},
    {CLS, "charWidth64",      "(IIII)I",                                 n_charWidth64},
    {CLS, "stringWidthFont",  "(IIILjava/lang/String;)I",                n_stringWidthFont},

    // Image
    {CLS, "createMutableImage",  "(II)J",                                n_createMutableImage},
    {CLS, "createImageFromData", "([BII)J",                              n_createImageFromData},
    {CLS, "destroyImage",        "(J)V",                                 n_destroyImage},
    {CLS, "getImageWidth",       "(J)I",                                 n_getImageWidth},
    {CLS, "getImageHeight",      "(J)I",                                 n_getImageHeight},
    {CLS, "getImageContext",     "(J)J",                                 n_getImageContext},
    {CLS, "drawImage",           "(JJIII)V",                             n_drawImage},
    {CLS, "drawRegion",          "(JJIIIIIIII)V",                        n_drawRegion},
    {CLS, "drawRGB",             "(J[IIIIIIII)V",                        n_drawRGB},
    {CLS, "getImageRGB",         "(J[IIIIIII)V",                         n_getImageRGB},
    {CLS, "fillPolygon",         "(J[I[II)V",                            n_fillPolygon},
    {CLS, "drawPolygon",         "(J[I[II)V",                            n_drawPolygon},
    {CLS, "copyArea",            "(JIIIIII)V",                           n_copyArea},

    // Haptics
    {CLS, "vibrate",             "(I)V",                                 n_vibrate},
};

#undef CLS

void j2me_render_reg_natives(MiniJVM *jvm) {
    native_reg_lib(jvm, j2me_render_methods,
                   sizeof(j2me_render_methods) / sizeof(java_native_method));
    printf("[J2ME Render] Registered %lu native methods\n",
           sizeof(j2me_render_methods) / sizeof(java_native_method));
}

void j2me_render_stop(void) {
    g_render_stopped = 1;
}

void j2me_render_cleanup(void) {
    // g_render_stopped must already be set (via j2me_render_stop).
    // Two passes needed: first frees gen1 and promotes gen0→gen1,
    // second frees promoted gen1 (was gen0). After both, all dead shells are freed.
    process_dead_shells();
    process_dead_shells();

    // Force-release all still-live RenderContexts (never destroyed by Java).
    // These are guaranteed valid: untrack_rc removed freed ones from the array.
    spin_lock(&g_track_lock);
    int rc_count = g_live_rc_count;
    for (int i = 0; i < g_live_rc_count; i++) {
        RenderContext *rc = g_live_rc[i];
        if (rc->ctx) { CGContextRelease(rc->ctx); rc->ctx = NULL; }
        CTFontRef font = rc->font;
        rc->font = NULL;
        if (font) CFRelease(font);
        free(rc);
    }
    g_live_rc_count = 0;

    // Force-release all still-live RenderImages
    int img_count = g_live_img_count;
    for (int i = 0; i < g_live_img_count; i++) {
        RenderImage *img = g_live_img[i];
        if (img->ctx) { CGContextRelease(img->ctx); img->ctx = NULL; }
        free(img);
    }
    g_live_img_count = 0;
    spin_unlock(&g_track_lock);

    // Clear dead queues
    atomic_store_explicit(&g_dead_rc_gen0, NULL, memory_order_relaxed);
    g_dead_rc_gen1 = NULL;
    atomic_store_explicit(&g_dead_img_gen0, NULL, memory_order_relaxed);
    g_dead_img_gen1 = NULL;

    // Reset native heap counter
    __atomic_store_n(&g_native_extra_heap, 0, __ATOMIC_RELAXED);

    // Stop haptic engine
    if (@available(iOS 13.0, *)) {
        if (g_hapticPlayer) {
            NSError *err = nil;
            [g_hapticPlayer stopAtTime:0 error:&err];
            g_hapticPlayer = nil;
        }
        if (g_hapticEngine) {
            [g_hapticEngine stopWithCompletionHandler:nil];
            g_hapticEngine = nil;
        }
    }

    g_render_stopped = 0; // ready for next game session
    printf("[J2ME Render] Cleanup: %d contexts, %d images released\n", rc_count, img_count);
}
