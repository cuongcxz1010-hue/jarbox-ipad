//
//  gfx_core.h
//  JarBox Graphics Engine
//
//  Platform-neutral software renderer implementing the MIDP drawing model on
//  32-bit premultiplied ARGB surfaces (0xAARRGGBB words, row 0 on top).
//  No Core Graphics, no allocation per call: a game draws thousands of
//  sprites and clip changes per frame and every call must be cheap.
//

#ifndef GFX_CORE_H
#define GFX_CORE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct GfxSurface {
    uint32_t *pixels;
    int32_t width;
    int32_t height;
    int32_t hasAlpha;   // 0 = every pixel is opaque, blits may copy whole rows
} GfxSurface;

typedef struct GfxPaint {
    uint32_t argb;      // colour as given by the game (straight alpha)
    uint32_t premul;    // the same colour premultiplied
    int32_t dotted;     // Graphics.DOTTED
    int32_t cx0, cy0, cx1, cy1;     // clip, half-open, inside the surface
} GfxPaint;

/// MIDP drawRegion / Sprite transforms.
enum {
    GFX_TRANS_NONE = 0,
    GFX_TRANS_MIRROR_ROT180 = 1,
    GFX_TRANS_MIRROR = 2,
    GFX_TRANS_ROT180 = 3,
    GFX_TRANS_MIRROR_ROT270 = 4,
    GFX_TRANS_ROT90 = 5,
    GFX_TRANS_ROT270 = 6,
    GFX_TRANS_MIRROR_ROT90 = 7,
};

/// MIDP anchors.
enum {
    GFX_HCENTER = 1,
    GFX_VCENTER = 2,
    GFX_LEFT = 4,
    GFX_RIGHT = 8,
    GFX_TOP = 16,
    GFX_BOTTOM = 32,
    GFX_BASELINE = 64,
};

void gfx_paint_init(GfxPaint *p, const GfxSurface *s);
void gfx_paint_set_color(GfxPaint *p, uint32_t argb);
void gfx_paint_set_clip(GfxPaint *p, const GfxSurface *s, int x, int y, int w, int h);

/// Allocates pixels (not zeroed); returns 0 when out of memory.
int gfx_surface_alloc(GfxSurface *s, int width, int height, int hasAlpha);
void gfx_surface_free(GfxSurface *s);
void gfx_surface_fill(GfxSurface *s, uint32_t premul);

/// Premultiply one straight-alpha colour.
uint32_t gfx_premultiply(uint32_t argb);

void gfx_fill_rect(const GfxSurface *s, const GfxPaint *p, int x, int y, int w, int h);
void gfx_draw_rect(const GfxSurface *s, const GfxPaint *p, int x, int y, int w, int h);
void gfx_draw_line(const GfxSurface *s, const GfxPaint *p, int x1, int y1, int x2, int y2);
void gfx_fill_triangle(const GfxSurface *s, const GfxPaint *p, int x1, int y1, int x2, int y2, int x3, int y3);
void gfx_fill_polygon(const GfxSurface *s, const GfxPaint *p, const int32_t *xs, const int32_t *ys, int n);
void gfx_draw_polygon(const GfxSurface *s, const GfxPaint *p, const int32_t *xs, const int32_t *ys, int n);
void gfx_fill_arc(const GfxSurface *s, const GfxPaint *p, int x, int y, int w, int h, int start, int arc);
void gfx_draw_arc(const GfxSurface *s, const GfxPaint *p, int x, int y, int w, int h, int start, int arc);
void gfx_fill_round_rect(const GfxSurface *s, const GfxPaint *p, int x, int y, int w, int h, int aw, int ah);
void gfx_draw_round_rect(const GfxSurface *s, const GfxPaint *p, int x, int y, int w, int h, int aw, int ah);

/// Width and height of a region once `transform` is applied.
void gfx_transformed_size(int w, int h, int transform, int *outW, int *outH);

/// Draw a region of src with its transformed top-left corner at (x, y).
void gfx_blit(const GfxSurface *dst, const GfxPaint *p, const GfxSurface *src,
              int xSrc, int ySrc, int w, int h, int transform, int x, int y);

/// drawRGB: straight ARGB input. Every array access is bounds-checked.
void gfx_blit_rgb(const GfxSurface *dst, const GfxPaint *p, const int32_t *rgb, int32_t rgbLen,
                  int32_t offset, int32_t scan, int x, int y, int w, int h, int processAlpha);

/// getRGB: straight ARGB output. Every array access is bounds-checked.
void gfx_read_rgb(const GfxSurface *src, int32_t *out, int32_t outLen, int32_t offset, int32_t scan,
                  int x, int y, int w, int h);

/// Graphics.copyArea: overlapping areas are handled; the clip applies to the destination.
void gfx_copy_area(const GfxSurface *s, const GfxPaint *p, int xSrc, int ySrc, int w, int h, int xDst, int yDst);

/// Paint an 8-bit coverage mask with the current colour.
void gfx_blit_mask(const GfxSurface *dst, const GfxPaint *p, const uint8_t *mask, int maskW, int maskH, int x, int y);

/// Replace pixels of a surface from straight-ARGB input without blending
/// (used to build images; bounds-checked).
void gfx_store_rgb(GfxSurface *dst, const int32_t *rgb, int32_t rgbLen, int processAlpha);

/// Box-filter downscale of RGBA bytes into a surface's BGRA pixels (3D supersampling).
void gfx_downscale_rgba(const uint8_t *rgba, int sw, int sh, uint32_t *dst, int dw, int dh, int dstStride, int keepAlpha);

/// Decode a PNG file. Returns 1 and a malloc'd premultiplied buffer on success.
int gfx_png_decode(const uint8_t *data, int32_t length, int32_t *outW, int32_t *outH,
                   uint32_t **outPixels, int32_t *outHasAlpha);

/// Encode an RGBA8888-free buffer of premultiplied pixels as a PNG (for
/// screenshots). Returns a malloc'd buffer, sets *outLen.
uint8_t *gfx_png_encode(const uint32_t *pixels, int width, int height, int32_t *outLen);

#ifdef __cplusplus
}
#endif

#endif /* GFX_CORE_H */
