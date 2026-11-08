//
//  gfx_text.c
//  JarBox Graphics Engine — glyph cache and text layout
//

#include "Graphics/gfx_text.h"
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

#define PAGE_BITS 8
#define PAGE_SIZE (1 << PAGE_BITS)
#define PAGE_COUNT (0x10000 >> PAGE_BITS)

typedef struct GlyphPage {
    GfxGlyph glyphs[PAGE_SIZE];
    _Atomic uint8_t ready[PAGE_SIZE];
} GlyphPage;

typedef struct {
    _Atomic(GlyphPage *) pages[PAGE_COUNT];
    _Atomic int measured;       // 0 no, 1 yes
    int ascent, height;
} FontState;

static FontState g_fonts[GFX_FONT_COUNT];

/// SMALL / MEDIUM / LARGE, in pixels. J2ME Loader's defaults for 240×320.
static _Atomic int g_sizes[3] = {18, 22, 26};

static atomic_flag g_lock = ATOMIC_FLAG_INIT;
static inline void text_lock(void) { while (atomic_flag_test_and_set_explicit(&g_lock, memory_order_acquire)) { } }
static inline void text_unlock(void) { atomic_flag_clear_explicit(&g_lock, memory_order_release); }

int gfx_font_index(int face, int style, int size) {
    int f = face == GFX_FACE_MONOSPACE ? 1 : (face == GFX_FACE_PROPORTIONAL ? 2 : 0);
    int st = style & (GFX_STYLE_BOLD | GFX_STYLE_ITALIC);
    int si = size == GFX_SIZE_SMALL ? 0 : (size == GFX_SIZE_LARGE ? 2 : 1);
    return f * 12 + st * 3 + si;
}

int gfx_font_pixel_size(int font) {
    return atomic_load(&g_sizes[font % 3]);
}

void gfx_text_set_sizes(int small, int medium, int large) {
    if (small > 0) atomic_store(&g_sizes[0], small);
    if (medium > 0) atomic_store(&g_sizes[1], medium);
    if (large > 0) atomic_store(&g_sizes[2], large);
    gfx_text_reset();
}

void gfx_text_reset(void) {
    text_lock();
    for (int f = 0; f < GFX_FONT_COUNT; f++) {
        FontState *fs = &g_fonts[f];
        for (int p = 0; p < PAGE_COUNT; p++) {
            GlyphPage *page = atomic_exchange(&fs->pages[p], NULL);
            if (!page) continue;
            for (int i = 0; i < PAGE_SIZE; i++) free(page->glyphs[i].mask);
            free(page);
        }
        atomic_store(&fs->measured, 0);
    }
    text_unlock();
}

static void ensure_measured(int font) {
    FontState *fs = &g_fonts[font];
    if (atomic_load_explicit(&fs->measured, memory_order_acquire)) return;
    int ascent = 0, height = 0;
    gfx_platform_font_metrics(font, gfx_font_pixel_size(font), &ascent, &height);
    text_lock();
    fs->ascent = ascent;
    fs->height = height;
    text_unlock();
    atomic_store_explicit(&fs->measured, 1, memory_order_release);
}

int gfx_font_ascent(int font) { ensure_measured(font); return g_fonts[font].ascent; }
int gfx_font_height(int font) { ensure_measured(font); return g_fonts[font].height; }

static const GfxGlyph *get_glyph(int font, uint32_t ch) {
    if (ch > 0xFFFF) return NULL;
    FontState *fs = &g_fonts[font];
    uint32_t pageIndex = ch >> PAGE_BITS, slot = ch & (PAGE_SIZE - 1);
    GlyphPage *page = atomic_load_explicit(&fs->pages[pageIndex], memory_order_acquire);
    if (!page) {
        GlyphPage *fresh = (GlyphPage *)calloc(1, sizeof(GlyphPage));
        if (!fresh) return NULL;
        text_lock();
        page = atomic_load_explicit(&fs->pages[pageIndex], memory_order_relaxed);
        if (!page) {
            atomic_store_explicit(&fs->pages[pageIndex], fresh, memory_order_release);
            page = fresh;
            fresh = NULL;
        }
        text_unlock();
        free(fresh);
    }
    if (atomic_load_explicit(&page->ready[slot], memory_order_acquire)) return &page->glyphs[slot];

    // Rasterize outside the lock (slow); the first finisher publishes it.
    GfxGlyph made;
    memset(&made, 0, sizeof(made));
    gfx_platform_make_glyph(font, gfx_font_pixel_size(font), ch, &made);
    text_lock();
    if (!atomic_load_explicit(&page->ready[slot], memory_order_relaxed)) {
        page->glyphs[slot] = made;
        made.mask = NULL;
        atomic_store_explicit(&page->ready[slot], 1, memory_order_release);
    }
    text_unlock();
    free(made.mask);
    return &page->glyphs[slot];
}

int gfx_char_width64(int font, uint32_t ch) {
    const GfxGlyph *g = get_glyph(font, ch);
    return g ? g->advance64 : 0;
}

int gfx_text_width(int font, const uint16_t *chars, int count) {
    int64_t sum = 0;
    for (int i = 0; i < count; i++) sum += gfx_char_width64(font, chars[i]);
    return (int)((sum + 32) >> 6);
}

void gfx_draw_text(const GfxSurface *s, const GfxPaint *p, int font, int underlined,
                   const uint16_t *chars, int count, int x, int y, int anchor) {
    if (count <= 0) return;
    int ascent = gfx_font_ascent(font), height = gfx_font_height(font);

    int64_t width64 = 0;
    int needWidth = (anchor & (GFX_HCENTER | GFX_RIGHT)) != 0 || underlined;
    if (needWidth) for (int i = 0; i < count; i++) width64 += gfx_char_width64(font, chars[i]);
    int width = (int)((width64 + 32) >> 6);

    if (anchor & GFX_HCENTER) x -= width / 2;
    else if (anchor & GFX_RIGHT) x -= width;

    int baseline;
    if (anchor & GFX_BASELINE) baseline = y;
    else if (anchor & GFX_BOTTOM) baseline = y - height + ascent;
    else if (anchor & GFX_VCENTER) baseline = y - height / 2 + ascent;
    else baseline = y + ascent;

    // Whole line above or below the clip: nothing to do
    if (baseline + height < p->cy0 || baseline - height >= p->cy1) return;

    int64_t pen = (int64_t)x * 64;
    for (int i = 0; i < count; i++) {
        const GfxGlyph *g = get_glyph(font, chars[i]);
        if (!g) continue;
        if (g->mask) {
            int gx = (int)((pen + 32) >> 6) + g->left;
            gfx_blit_mask(s, p, g->mask, g->w, g->h, gx, baseline + g->top);
        }
        pen += g->advance64;
    }

    if (underlined) gfx_draw_line(s, p, x, baseline + 1, x + width - 1, baseline + 1);
}
