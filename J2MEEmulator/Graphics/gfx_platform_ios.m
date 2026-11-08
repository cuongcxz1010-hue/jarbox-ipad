//
//  gfx_platform_ios.m
//  JarBox — iOS services for the Graphics Engine:
//  present frames, Core Text glyphs, ImageIO decoding, haptics.
//

#import <CoreGraphics/CoreGraphics.h>
#import <CoreText/CoreText.h>
#import <CoreHaptics/CoreHaptics.h>
#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>
#include "Graphics/j2me_render.h"
#include "Graphics/gfx_platform.h"
#include "Graphics/gfx_text.h"
#include <pthread.h>
#include <stdatomic.h>

// ============================================================
// Presenting frames
// ============================================================
// Frames are copied into a small pool of buffers wrapped by CGImages that do
// not copy the data. A buffer returns to the pool when Core Animation lets go
// of its image, so no memory is allocated per frame.

#define FRAME_POOL 4

typedef struct FrameBuffer {
    uint8_t *bytes;
    size_t size;
    _Atomic int busy;
} FrameBuffer;

static FrameBuffer g_frames[FRAME_POOL];
static j2me_flush_callback g_flush_callback = NULL;

void j2me_render_set_flush_callback(j2me_flush_callback callback) {
    g_flush_callback = callback;
}

static void frame_released(void *info, const void *data, size_t size) {
    if (info) atomic_store(&((FrameBuffer *)info)->busy, 0);
    else free((void *)data);
}

void gfx_platform_present(const GfxSurface *s) {
    if (!g_flush_callback) return;
    size_t bytes = (size_t)s->width * (size_t)s->height * 4;

    FrameBuffer *frame = NULL;
    for (int i = 0; i < FRAME_POOL; i++) {
        int expected = 0;
        if (atomic_compare_exchange_strong(&g_frames[i].busy, &expected, 1)) { frame = &g_frames[i]; break; }
    }
    uint8_t *dst;
    if (frame) {
        if (frame->size != bytes) {
            free(frame->bytes);
            frame->bytes = (uint8_t *)malloc(bytes);
            frame->size = frame->bytes ? bytes : 0;
        }
        if (!frame->bytes) { atomic_store(&frame->busy, 0); return; }
        dst = frame->bytes;
    } else {
        // Every buffer is in use: the UI is behind. Keep this frame anyway, it may be the last one.
        dst = (uint8_t *)malloc(bytes);
        if (!dst) return;
    }
    memcpy(dst, s->pixels, bytes);

    static CGColorSpaceRef colorSpace = NULL;
    if (!colorSpace) colorSpace = CGColorSpaceCreateDeviceRGB();
    CGDataProviderRef provider = CGDataProviderCreateWithData(frame, dst, bytes, frame_released);
    CGImageRef image = CGImageCreate((size_t)s->width, (size_t)s->height, 8, 32, (size_t)s->width * 4, colorSpace,
                                     kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little,
                                     provider, NULL, false, kCGRenderingIntentDefault);
    CGDataProviderRelease(provider);
    if (image) g_flush_callback(image, s->width, s->height);    // the callback owns the image
}

// ============================================================
// Fonts
// ============================================================

static CTFontRef g_ct_fonts[GFX_FONT_COUNT];
static int g_ct_font_sizes[GFX_FONT_COUNT];
static pthread_mutex_t g_font_lock = PTHREAD_MUTEX_INITIALIZER;

/// Retained font for a gfx font index at the given pixel size.
static CTFontRef copy_font(int font, int pixelSize) {
    pthread_mutex_lock(&g_font_lock);
    CTFontRef f = g_ct_fonts[font];
    if (!f || g_ct_font_sizes[font] != pixelSize) {
        if (f) CFRelease(f);
        int face = font / 12, style = (font % 12) / 3;
        CFStringRef name;
        if (face == 1) {
            name = style == 3 ? CFSTR("Courier-BoldOblique") : style == 1 ? CFSTR("Courier-Bold")
                 : style == 2 ? CFSTR("Courier-Oblique") : CFSTR("Courier");
        } else {
            name = style == 3 ? CFSTR("Helvetica-BoldOblique") : style == 1 ? CFSTR("Helvetica-Bold")
                 : style == 2 ? CFSTR("Helvetica-Oblique") : CFSTR("Helvetica");
        }
        f = CTFontCreateWithName(name, pixelSize, NULL);
        g_ct_fonts[font] = f;
        g_ct_font_sizes[font] = pixelSize;
    }
    if (f) CFRetain(f);
    pthread_mutex_unlock(&g_font_lock);
    return f;
}

void gfx_platform_font_metrics(int font, int pixelSize, int *ascent, int *height) {
    CTFontRef f = copy_font(font, pixelSize);
    if (!f) { *ascent = pixelSize; *height = pixelSize + pixelSize / 4; return; }
    int a = (int)ceil(CTFontGetAscent(f)), d = (int)ceil(CTFontGetDescent(f));
    *ascent = a;
    *height = a + d;
    CFRelease(f);
}

int gfx_platform_make_glyph(int font, int pixelSize, uint32_t ch, GfxGlyph *out) {
    memset(out, 0, sizeof(*out));
    CTFontRef f = copy_font(font, pixelSize);
    if (!f) return 0;

    UniChar uc = (UniChar)ch;
    CGGlyph glyph = 0;
    if (!CTFontGetGlyphsForCharacters(f, &uc, &glyph, 1) || glyph == 0) {
        CFStringRef str = CFStringCreateWithCharacters(NULL, &uc, 1);
        CTFontRef fallback = str ? CTFontCreateForString(f, str, CFRangeMake(0, 1)) : NULL;
        if (str) CFRelease(str);
        if (fallback) { CFRelease(f); f = fallback; }
        if (!CTFontGetGlyphsForCharacters(f, &uc, &glyph, 1)) glyph = 0;
    }
    if (glyph == 0) {
        out->advance64 = (ch < 0x20 || (ch >= 0xD800 && ch <= 0xDFFF)) ? 0 : pixelSize * 32;
        CFRelease(f);
        return 1;
    }

    CGSize advance = CGSizeZero;
    CTFontGetAdvancesForGlyphs(f, kCTFontOrientationHorizontal, &glyph, &advance, 1);
    out->advance64 = (int32_t)lround(advance.width * 64);

    CGRect box = CTFontGetBoundingRectsForGlyphs(f, kCTFontOrientationHorizontal, &glyph, NULL, 1);
    if (!CGRectIsEmpty(box)) {
        int left = (int)floor(CGRectGetMinX(box)) - 1, right = (int)ceil(CGRectGetMaxX(box)) + 1;
        int bottom = (int)floor(CGRectGetMinY(box)) - 1, top = (int)ceil(CGRectGetMaxY(box)) + 1;
        int w = right - left, h = top - bottom;
        uint8_t *mask = w > 0 && h > 0 ? (uint8_t *)calloc((size_t)w, (size_t)h) : NULL;
        if (mask) {
            CGContextRef c = CGBitmapContextCreate(mask, (size_t)w, (size_t)h, 8, (size_t)w, NULL, kCGImageAlphaOnly);
            if (c) {
                CGContextSetAlpha(c, 1);
                CGContextSetFillColorWithColor(c, CGColorGetConstantColor(kCGColorWhite));
                CGPoint at = CGPointMake(-left, -bottom);
                CTFontDrawGlyphs(f, &glyph, &at, 1, c);
                CGContextRelease(c);
                out->mask = mask;
                out->w = (int16_t)w;
                out->h = (int16_t)h;
                out->left = (int16_t)left;
                out->top = (int16_t)-top;
            } else {
                free(mask);
            }
        }
    }
    CFRelease(f);
    return 1;
}

// ============================================================
// Images other than PNG
// ============================================================

int gfx_platform_decode_image(const uint8_t *data, int32_t length, int32_t *outW, int32_t *outH,
                              uint32_t **outPixels, int32_t *outHasAlpha) {
    CFDataRef cfData = CFDataCreate(NULL, data, length);
    if (!cfData) return 0;
    CGImageSourceRef source = CGImageSourceCreateWithData(cfData, NULL);
    CFRelease(cfData);
    if (!source) return 0;
    CGImageRef image = CGImageSourceCreateImageAtIndex(source, 0, NULL);
    CFRelease(source);
    if (!image) return 0;

    size_t w = CGImageGetWidth(image), h = CGImageGetHeight(image);
    uint32_t *pixels = (w && h) ? (uint32_t *)malloc(w * h * 4) : NULL;
    int ok = 0;
    if (pixels) {
        memset(pixels, 0, w * h * 4);
        CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
        CGContextRef c = CGBitmapContextCreate(pixels, w, h, 8, w * 4, cs,
                                               kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
        CGColorSpaceRelease(cs);
        if (c) {
            CGContextDrawImage(c, CGRectMake(0, 0, w, h), image);
            CGContextRelease(c);
            CGImageAlphaInfo alpha = CGImageGetAlphaInfo(image);
            *outW = (int32_t)w;
            *outH = (int32_t)h;
            *outPixels = pixels;
            *outHasAlpha = !(alpha == kCGImageAlphaNone || alpha == kCGImageAlphaNoneSkipFirst || alpha == kCGImageAlphaNoneSkipLast);
            ok = 1;
        } else {
            free(pixels);
        }
    }
    CGImageRelease(image);
    return ok;
}

// ============================================================
// Vibration
// ============================================================

static CHHapticEngine *g_engine = nil;
static id<CHHapticPatternPlayer> g_player = nil;

static void ensure_engine(void) {
    if (g_engine || !CHHapticEngine.capabilitiesForHardware.supportsHaptics) return;
    NSError *err = nil;
    g_engine = [[CHHapticEngine alloc] initAndReturnError:&err];
    if (err) { g_engine = nil; return; }
    g_engine.resetHandler = ^{ [g_engine startAndReturnError:nil]; };
    [g_engine startAndReturnError:nil];
}

void gfx_platform_vibrate(int durationMs) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (g_player) { [g_player stopAtTime:0 error:nil]; g_player = nil; }
        if (durationMs <= 0) return;
        ensure_engine();
        if (!g_engine) return;
        CHHapticEventParameter *intensity = [[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDHapticIntensity value:0.35f];
        CHHapticEventParameter *sharpness = [[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDHapticSharpness value:0.1f];
        CHHapticEvent *event = [[CHHapticEvent alloc] initWithEventType:CHHapticEventTypeHapticContinuous
                                                             parameters:@[intensity, sharpness]
                                                           relativeTime:0
                                                               duration:durationMs / 1000.0];
        NSError *err = nil;
        CHHapticPattern *pattern = [[CHHapticPattern alloc] initWithEvents:@[event] parameters:@[] error:&err];
        if (err) return;
        g_player = [g_engine createPlayerWithPattern:pattern error:&err];
        if (!err) [g_player startAtTime:0 error:nil];
    });
}

void gfx_platform_reset(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (g_player) { [g_player stopAtTime:0 error:nil]; g_player = nil; }
        if (g_engine) { [g_engine stopWithCompletionHandler:nil]; g_engine = nil; }
    });
    pthread_mutex_lock(&g_font_lock);
    for (int i = 0; i < GFX_FONT_COUNT; i++) {
        if (g_ct_fonts[i]) { CFRelease(g_ct_fonts[i]); g_ct_fonts[i] = NULL; }
        g_ct_font_sizes[i] = 0;
    }
    pthread_mutex_unlock(&g_font_lock);
}
