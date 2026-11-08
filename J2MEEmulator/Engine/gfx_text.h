//
//  gfx_text.h
//  JarBox Graphics Engine — text
//
//  Text is drawn from a glyph cache: each (font, character) is rasterized once
//  into an 8-bit mask by the platform layer and then blitted, so drawing a
//  string costs about the same as drawing a few small sprites.
//

#ifndef GFX_TEXT_H
#define GFX_TEXT_H

#include "gfx_core.h"

#ifdef __cplusplus
extern "C" {
#endif

/// MIDP Font constants.
enum { GFX_FACE_SYSTEM = 0, GFX_FACE_MONOSPACE = 32, GFX_FACE_PROPORTIONAL = 64 };
enum { GFX_STYLE_BOLD = 1, GFX_STYLE_ITALIC = 2, GFX_STYLE_UNDERLINED = 4 };
enum { GFX_SIZE_SMALL = 8, GFX_SIZE_MEDIUM = 0, GFX_SIZE_LARGE = 16 };

#define GFX_FONT_COUNT (3 * 4 * 3)

typedef struct GfxGlyph {
    uint8_t *mask;      // malloc'd coverage, w × h, may be NULL for blank glyphs
    int16_t w, h;
    int16_t left;       // mask offset from the pen position
    int16_t top;        // mask offset from the baseline, negative = above it
    int32_t advance64;  // advance width in 1/64 pixel
} GfxGlyph;

/// Index of a (face, style, size) combination. Underline is drawn separately.
int gfx_font_index(int face, int style, int size);

/// Font sizes in pixels for SMALL / MEDIUM / LARGE (0 keeps the current value).
void gfx_text_set_sizes(int small, int medium, int large);

/// Pixel size configured for one font index.
int gfx_font_pixel_size(int font);

int gfx_font_ascent(int font);
int gfx_font_height(int font);

/// Advance of one UTF-16 code unit, 1/64 pixel.
int gfx_char_width64(int font, uint32_t ch);

/// Pixel width of a string, rounded as Font.stringWidth reports it.
int gfx_text_width(int font, const uint16_t *chars, int count);

/// Draw text at an MIDP anchor.
void gfx_draw_text(const GfxSurface *s, const GfxPaint *p, int font, int underlined,
                   const uint16_t *chars, int count, int x, int y, int anchor);

/// Free every cached glyph and forget measured fonts (between games).
void gfx_text_reset(void);

// --- Implemented by the platform layer (Core Text on iOS) ---

/// Fills ascent and height, in pixels, of a font of the given pixel size.
void gfx_platform_font_metrics(int font, int pixelSize, int *ascent, int *height);

/// Rasterize one character. Returns 0 on failure.
int gfx_platform_make_glyph(int font, int pixelSize, uint32_t ch, GfxGlyph *out);

#ifdef __cplusplus
}
#endif

#endif /* GFX_TEXT_H */
