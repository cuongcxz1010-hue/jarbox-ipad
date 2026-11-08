//
//  gfx_core.c
//  JarBox Graphics Engine — software rasterizer (see gfx_core.h)
//
//  Pixel rules follow the MIDP 2.0 specification:
//    fillRect covers w × h pixels; drawRect covers (w + 1) × (h + 1);
//    drawLine includes both end points; arcs are measured against a circle
//    inscribed in the bounding box, 0° at 3 o'clock, counter-clockwise.
//

#include "Graphics/gfx_core.h"
#include <stdlib.h>
#include <string.h>
#include <math.h>

// ============================================================
// Pixel helpers
// ============================================================

/// d * f / 255 for all four channels (f = 0…255).
static inline uint32_t scale_pixel(uint32_t d, uint32_t f) {
    uint32_t rb = (d & 0x00FF00FFu) * f + 0x00800080u;
    rb = ((rb + ((rb >> 8) & 0x00FF00FFu)) >> 8) & 0x00FF00FFu;
    uint32_t ag = ((d >> 8) & 0x00FF00FFu) * f + 0x00800080u;
    ag = (ag + ((ag >> 8) & 0x00FF00FFu)) & 0xFF00FF00u;
    return rb | ag;
}

/// Source-over of a premultiplied pixel.
static inline void blend(uint32_t *d, uint32_t s) {
    uint32_t a = s >> 24;
    if (a == 255) *d = s;
    else if (a) *d = s + scale_pixel(*d, 255 - a);
}

uint32_t gfx_premultiply(uint32_t argb) {
    uint32_t a = argb >> 24;
    if (a == 255) return argb;
    if (a == 0) return 0;
    return scale_pixel(argb | 0xFF000000u, a);
}

static inline int imin(int a, int b) { return a < b ? a : b; }
static inline int imax(int a, int b) { return a > b ? a : b; }

/// a + b without overflow.
static inline int sat_add(int a, int b) {
    int64_t v = (int64_t)a + b;
    if (v > INT32_MAX) return INT32_MAX;
    if (v < INT32_MIN) return INT32_MIN;
    return (int)v;
}

static inline void put(const GfxSurface *s, const GfxPaint *p, int x, int y) {
    if (x >= p->cx0 && x < p->cx1 && y >= p->cy0 && y < p->cy1)
        blend(s->pixels + (ptrdiff_t)y * s->width + x, p->premul);
}

/// Horizontal run with the paint colour; x0..x1 half-open, clipped here.
static inline void hspan(const GfxSurface *s, const GfxPaint *p, int x0, int x1, int y) {
    if (y < p->cy0 || y >= p->cy1) return;
    if (x0 < p->cx0) x0 = p->cx0;
    if (x1 > p->cx1) x1 = p->cx1;
    if (x0 >= x1) return;
    uint32_t *d = s->pixels + (ptrdiff_t)y * s->width + x0;
    uint32_t c = p->premul;
    int n = x1 - x0;
    if ((c >> 24) == 255) {
        while (n--) *d++ = c;
    } else if (c >> 24) {
        uint32_t inv = 255 - (c >> 24);
        while (n--) { *d = c + scale_pixel(*d, inv); d++; }
    }
}

// ============================================================
// Surfaces and paint
// ============================================================

int gfx_surface_alloc(GfxSurface *s, int width, int height, int hasAlpha) {
    s->pixels = NULL;
    s->width = width > 0 ? width : 1;
    s->height = height > 0 ? height : 1;
    s->hasAlpha = hasAlpha;
    size_t bytes = (size_t)s->width * (size_t)s->height * 4;
    s->pixels = (uint32_t *)malloc(bytes);
    return s->pixels != NULL;
}

void gfx_surface_free(GfxSurface *s) {
    free(s->pixels);
    s->pixels = NULL;
}

void gfx_surface_fill(GfxSurface *s, uint32_t premul) {
    size_t n = (size_t)s->width * (size_t)s->height;
    uint32_t *d = s->pixels;
    if (premul == 0) {
        memset(d, 0, n * 4);
    } else {
        for (size_t i = 0; i < n; i++) d[i] = premul;
    }
}

void gfx_paint_init(GfxPaint *p, const GfxSurface *s) {
    memset(p, 0, sizeof(*p));
    gfx_paint_set_color(p, 0xFF000000u);
    p->cx1 = s->width;
    p->cy1 = s->height;
}

void gfx_paint_set_color(GfxPaint *p, uint32_t argb) {
    p->argb = argb;
    p->premul = gfx_premultiply(argb);
}

void gfx_paint_set_clip(GfxPaint *p, const GfxSurface *s, int x, int y, int w, int h) {
    int x1 = sat_add(x, w), y1 = sat_add(y, h);
    p->cx0 = imax(x, 0);
    p->cy0 = imax(y, 0);
    p->cx1 = imin(x1, s->width);
    p->cy1 = imin(y1, s->height);
    if (w <= 0 || h <= 0 || p->cx1 < p->cx0 || p->cy1 < p->cy0) {
        p->cx1 = p->cx0;
        p->cy1 = p->cy0;
    }
}

// ============================================================
// Rectangles and lines
// ============================================================

void gfx_fill_rect(const GfxSurface *s, const GfxPaint *p, int x, int y, int w, int h) {
    if (w <= 0 || h <= 0) return;
    int x0 = imax(x, p->cx0), x1 = imin(sat_add(x, w), p->cx1);
    int y0 = imax(y, p->cy0), y1 = imin(sat_add(y, h), p->cy1);
    if (x0 >= x1 || y0 >= y1) return;
    uint32_t c = p->premul;
    uint32_t a = c >> 24;
    if (a == 0) return;
    int n = x1 - x0, stride = s->width;
    uint32_t *row = s->pixels + (ptrdiff_t)y0 * stride + x0;
    if (a == 255) {
        for (int yy = y0; yy < y1; yy++, row += stride) {
            uint32_t *d = row;
            for (int i = 0; i < n; i++) d[i] = c;
        }
    } else {
        uint32_t inv = 255 - a;
        for (int yy = y0; yy < y1; yy++, row += stride) {
            for (int i = 0; i < n; i++) row[i] = c + scale_pixel(row[i], inv);
        }
    }
}

#define DASH_ON 5
#define DASH_PERIOD 10

/// Keep coordinates in a range where the line walk stays short.
static inline int clamp_coord(int v) {
    if (v < -32768) return -32768;
    if (v > 32767) return 32767;
    return v;
}

void gfx_draw_line(const GfxSurface *s, const GfxPaint *p, int x1, int y1, int x2, int y2) {
    x1 = clamp_coord(x1); y1 = clamp_coord(y1);
    x2 = clamp_coord(x2); y2 = clamp_coord(y2);

    if (!p->dotted) {
        if (y1 == y2) {
            hspan(s, p, imin(x1, x2), imax(x1, x2) + 1, y1);
            return;
        }
        if (x1 == x2) {
            int y0 = imax(imin(y1, y2), p->cy0), yEnd = imin(imax(y1, y2) + 1, p->cy1);
            if (x1 < p->cx0 || x1 >= p->cx1) return;
            for (int y = y0; y < yEnd; y++) blend(s->pixels + (ptrdiff_t)y * s->width + x1, p->premul);
            return;
        }
    }

    // Quick reject: the whole line on one side of the clip
    if ((x1 < p->cx0 && x2 < p->cx0) || (x1 >= p->cx1 && x2 >= p->cx1) ||
        (y1 < p->cy0 && y2 < p->cy0) || (y1 >= p->cy1 && y2 >= p->cy1)) return;

    int dx = abs(x2 - x1), dy = abs(y2 - y1);
    int sx = x1 < x2 ? 1 : -1, sy = y1 < y2 ? 1 : -1;
    int err = dx - dy, step = 0;
    for (;;) {
        if (!p->dotted || (step % DASH_PERIOD) < DASH_ON) put(s, p, x1, y1);
        if (x1 == x2 && y1 == y2) break;
        int e2 = 2 * err;
        if (e2 > -dy) { err -= dy; x1 += sx; }
        if (e2 < dx) { err += dx; y1 += sy; }
        step++;
    }
}

void gfx_draw_rect(const GfxSurface *s, const GfxPaint *p, int x, int y, int w, int h) {
    if (w < 0 || h < 0) return;
    int x1 = sat_add(x, w), y1 = sat_add(y, h);
    if (w == 0 || h == 0) { gfx_draw_line(s, p, x, y, x1, y1); return; }
    gfx_draw_line(s, p, x, y, x1, y);
    gfx_draw_line(s, p, x1, y + 1, x1, y1);
    gfx_draw_line(s, p, x1 - 1, y1, x, y1);
    gfx_draw_line(s, p, x, y1 - 1, x, y + 1);
}

// ============================================================
// Polygons
// ============================================================

static int cmp_int(const void *a, const void *b) {
    return *(const int *)a - *(const int *)b;
}

void gfx_fill_polygon(const GfxSurface *s, const GfxPaint *p, const int32_t *xs, const int32_t *ys, int n) {
    if (n < 3) return;
    int ymin = ys[0], ymax = ys[0];
    for (int i = 1; i < n; i++) { ymin = imin(ymin, ys[i]); ymax = imax(ymax, ys[i]); }
    ymin = imax(ymin, p->cy0);
    ymax = imin(ymax, p->cy1 - 1);
    if (ymin > ymax) return;

    int stackHits[64];
    int *hits = n <= 64 ? stackHits : (int *)malloc(sizeof(int) * (size_t)n);
    if (!hits) return;

    for (int y = ymin; y <= ymax; y++) {
        int count = 0;
        // Sample at pixel centres; even-odd rule
        int64_t sy2 = 2 * (int64_t)y + 1;
        for (int i = 0, j = n - 1; i < n; j = i++) {
            int64_t y0 = 2 * (int64_t)ys[j], y1 = 2 * (int64_t)ys[i];
            if ((y0 <= sy2 && y1 > sy2) || (y1 <= sy2 && y0 > sy2)) {
                int64_t num = (int64_t)(xs[i] - xs[j]) * (sy2 - y0);
                int64_t den = y1 - y0;
                int x = (int)(xs[j] + (double)num / (double)den + 0.5);
                hits[count++] = x;
            }
        }
        qsort(hits, (size_t)count, sizeof(int), cmp_int);
        for (int k = 0; k + 1 < count; k += 2) hspan(s, p, hits[k], hits[k + 1], y);
    }
    if (hits != stackHits) free(hits);
}

void gfx_draw_polygon(const GfxSurface *s, const GfxPaint *p, const int32_t *xs, const int32_t *ys, int n) {
    if (n < 2) return;
    for (int i = 0; i < n - 1; i++) gfx_draw_line(s, p, xs[i], ys[i], xs[i + 1], ys[i + 1]);
    gfx_draw_line(s, p, xs[n - 1], ys[n - 1], xs[0], ys[0]);
}

void gfx_fill_triangle(const GfxSurface *s, const GfxPaint *p, int x1, int y1, int x2, int y2, int x3, int y3) {
    // Order by y
    int t;
    if (y2 < y1) { t = y1; y1 = y2; y2 = t; t = x1; x1 = x2; x2 = t; }
    if (y3 < y1) { t = y1; y1 = y3; y3 = t; t = x1; x1 = x3; x3 = t; }
    if (y3 < y2) { t = y2; y2 = y3; y3 = t; t = x2; x2 = x3; x3 = t; }
    if (y3 < p->cy0 || y1 >= p->cy1) return;

    if (y1 == y3) {     // degenerate: a single row
        int a = imin(x1, imin(x2, x3)), b = imax(x1, imax(x2, x3));
        hspan(s, p, a, b + 1, y1);
        return;
    }
    int yStart = imax(y1, p->cy0), yEnd = imin(y3, p->cy1 - 1);
    double longSlope = (double)(x3 - x1) / (double)(y3 - y1);
    for (int y = yStart; y <= yEnd; y++) {
        double a = x1 + longSlope * (y - y1), b;
        if (y < y2) {
            b = x1 + (double)(x2 - x1) / (double)(y2 - y1) * (y - y1);
        } else if (y3 != y2) {
            b = x2 + (double)(x3 - x2) / (double)(y3 - y2) * (y - y2);
        } else {
            b = x2;
        }
        int xa = (int)floor(a + 0.5), xb = (int)floor(b + 0.5);
        hspan(s, p, imin(xa, xb), imax(xa, xb) + 1, y);
    }
}

// ============================================================
// Arcs and rounded rectangles
// ============================================================

/// MIDP angle (degrees, against the inscribed circle) of a point relative to the ellipse centre.
static inline double point_angle(double dx, double dy, double rx, double ry) {
    double deg = atan2(-dy / ry, dx / rx) * 180.0 / M_PI;
    return deg < 0 ? deg + 360.0 : deg;
}

static inline int angle_in_arc(double a, double start, double sweep) {
    double d = fmod(a - start + 720.0, 360.0);
    return d <= sweep;
}

void gfx_fill_arc(const GfxSurface *s, const GfxPaint *p, int x, int y, int w, int h, int start, int arc) {
    if (w <= 0 || h <= 0 || arc == 0) return;
    double rx = w / 2.0, ry = h / 2.0, cx = x + rx, cy = y + ry;

    double startD = start, sweep = arc;
    if (sweep < 0) { startD += sweep; sweep = -sweep; }
    int full = sweep >= 360.0;
    startD = fmod(fmod(startD, 360.0) + 360.0, 360.0);

    int y0 = imax(y, p->cy0), y1 = imin(sat_add(y, h), p->cy1);
    for (int yy = y0; yy < y1; yy++) {
        double dy = yy + 0.5 - cy;
        double q = 1.0 - (dy * dy) / (ry * ry);
        if (q <= 0) continue;
        double half = rx * sqrt(q);
        int a = (int)ceil(cx - half - 0.5), b = (int)floor(cx + half - 0.5);
        if (a > b) continue;
        if (full) { hspan(s, p, a, b + 1, yy); continue; }
        a = imax(a, p->cx0);
        b = imin(b, p->cx1 - 1);
        int runStart = -1;
        for (int xx = a; xx <= b; xx++) {
            int inside = angle_in_arc(point_angle(xx + 0.5 - cx, dy, rx, ry), startD, sweep);
            if (inside && runStart < 0) runStart = xx;
            if (!inside && runStart >= 0) { hspan(s, p, runStart, xx, yy); runStart = -1; }
        }
        if (runStart >= 0) hspan(s, p, runStart, b + 1, yy);
    }
}

void gfx_draw_arc(const GfxSurface *s, const GfxPaint *p, int x, int y, int w, int h, int start, int arc) {
    if (w < 0 || h < 0 || arc == 0) return;
    double rx = w / 2.0, ry = h / 2.0, cx = x + rx, cy = y + ry;
    double startD = start, sweep = arc;
    if (sweep < 0) { startD += sweep; sweep = -sweep; }
    if (sweep > 360.0) sweep = 360.0;

    double r = rx > ry ? rx : ry;
    int steps = (int)(sweep / 360.0 * (r * 2.0 * M_PI)) + 2;
    if (steps > 8192) steps = 8192;
    int px = 0, py = 0;
    for (int i = 0; i <= steps; i++) {
        double t = (startD + sweep * i / steps) * M_PI / 180.0;
        int nx = (int)floor(cx + rx * cos(t) + 0.5), ny = (int)floor(cy - ry * sin(t) + 0.5);
        if (i == 0) put(s, p, nx, ny);
        else if (nx != px || ny != py) gfx_draw_line(s, p, px, py, nx, ny);
        px = nx; py = ny;
    }
}

void gfx_fill_round_rect(const GfxSurface *s, const GfxPaint *p, int x, int y, int w, int h, int aw, int ah) {
    if (w <= 0 || h <= 0) return;
    if (aw < 0) aw = -aw;
    if (ah < 0) ah = -ah;
    if (aw > w) aw = w;
    if (ah > h) ah = h;
    if (aw == 0 || ah == 0) { gfx_fill_rect(s, p, x, y, w, h); return; }

    double rx = aw / 2.0, ry = ah / 2.0;
    int yEnd = imin(sat_add(y, h), p->cy1);
    for (int yy = imax(y, p->cy0); yy < yEnd; yy++) {
        double dy;
        int inTop = yy - y < ry, inBottom = (y + h - 1) - yy < ry;
        if (inTop) dy = ry - (yy - y + 0.5);
        else if (inBottom) dy = ry - ((y + h - 1) - yy + 0.5);
        else { hspan(s, p, x, x + w, yy); continue; }
        double q = 1.0 - (dy * dy) / (ry * ry);
        double inset = rx - (q > 0 ? rx * sqrt(q) : 0.0);
        int d = (int)ceil(inset - 0.5);
        if (d < 0) d = 0;
        hspan(s, p, x + d, x + w - d, yy);
    }
}

void gfx_draw_round_rect(const GfxSurface *s, const GfxPaint *p, int x, int y, int w, int h, int aw, int ah) {
    if (w < 0 || h < 0) return;
    if (aw < 0) aw = -aw;
    if (ah < 0) ah = -ah;
    if (aw > w) aw = w;
    if (ah > h) ah = h;
    if (aw == 0 || ah == 0) { gfx_draw_rect(s, p, x, y, w, h); return; }
    int rx = aw / 2, ry = ah / 2;
    gfx_draw_line(s, p, x + rx, y, x + w - rx, y);
    gfx_draw_line(s, p, x + rx, y + h, x + w - rx, y + h);
    gfx_draw_line(s, p, x, y + ry, x, y + h - ry);
    gfx_draw_line(s, p, x + w, y + ry, x + w, y + h - ry);
    gfx_draw_arc(s, p, x, y, aw, ah, 90, 90);
    gfx_draw_arc(s, p, x + w - aw, y, aw, ah, 0, 90);
    gfx_draw_arc(s, p, x, y + h - ah, aw, ah, 180, 90);
    gfx_draw_arc(s, p, x + w - aw, y + h - ah, aw, ah, 270, 90);
}

// ============================================================
// Image blits
// ============================================================

void gfx_transformed_size(int w, int h, int transform, int *outW, int *outH) {
    switch (transform) {
        case GFX_TRANS_ROT90: case GFX_TRANS_ROT270:
        case GFX_TRANS_MIRROR_ROT90: case GFX_TRANS_MIRROR_ROT270:
            *outW = h; *outH = w; break;
        default:
            *outW = w; *outH = h; break;
    }
}

void gfx_blit(const GfxSurface *dst, const GfxPaint *p, const GfxSurface *src,
              int xSrc, int ySrc, int w, int h, int transform, int x, int y) {
    if (w <= 0 || h <= 0 || !src->pixels) return;

    // Output pixel (u, v) shows source pixel (sx0 + u*sxu + v*sxv, sy0 + u*syu + v*syv)
    int sx0, sy0, sxu, syu, sxv, syv, outW = w, outH = h;
    switch (transform) {
        case GFX_TRANS_NONE:          sx0 = 0;     sy0 = 0;     sxu = 1;  syu = 0;  sxv = 0;  syv = 1;  break;
        case GFX_TRANS_MIRROR:        sx0 = w - 1; sy0 = 0;     sxu = -1; syu = 0;  sxv = 0;  syv = 1;  break;
        case GFX_TRANS_MIRROR_ROT180: sx0 = 0;     sy0 = h - 1; sxu = 1;  syu = 0;  sxv = 0;  syv = -1; break;
        case GFX_TRANS_ROT180:        sx0 = w - 1; sy0 = h - 1; sxu = -1; syu = 0;  sxv = 0;  syv = -1; break;
        case GFX_TRANS_ROT90:         sx0 = 0;     sy0 = h - 1; sxu = 0;  syu = -1; sxv = 1;  syv = 0;  outW = h; outH = w; break;
        case GFX_TRANS_ROT270:        sx0 = w - 1; sy0 = 0;     sxu = 0;  syu = 1;  sxv = -1; syv = 0;  outW = h; outH = w; break;
        case GFX_TRANS_MIRROR_ROT90:  sx0 = w - 1; sy0 = h - 1; sxu = 0;  syu = -1; sxv = -1; syv = 0;  outW = h; outH = w; break;
        case GFX_TRANS_MIRROR_ROT270: sx0 = 0;     sy0 = 0;     sxu = 0;  syu = 1;  sxv = 1;  syv = 0;  outW = h; outH = w; break;
        default: return;
    }

    int dx0 = imax(x, p->cx0), dy0 = imax(y, p->cy0);
    int dx1 = imin(sat_add(x, outW), p->cx1), dy1 = imin(sat_add(y, outH), p->cy1);
    if (dx0 >= dx1 || dy0 >= dy1) return;

    ptrdiff_t sstride = src->width, dstride = dst->width;

    // Region partly outside the image: only the part inside is copied
    if (xSrc < 0 || ySrc < 0 || xSrc > src->width - w || ySrc > src->height - h) {
        for (int dy = dy0; dy < dy1; dy++) {
            uint32_t *d = dst->pixels + (ptrdiff_t)dy * dstride;
            for (int dx = dx0; dx < dx1; dx++) {
                int u = dx - x, v = dy - y;
                int sx = xSrc + sx0 + u * sxu + v * sxv, sy = ySrc + sy0 + u * syu + v * syv;
                if (sx < 0 || sy < 0 || sx >= src->width || sy >= src->height) continue;
                blend(d + dx, src->pixels[(ptrdiff_t)sy * sstride + sx]);
            }
        }
        return;
    }

    ptrdiff_t stepU = sxu + syu * sstride, stepV = sxv + syv * sstride;
    const uint32_t *origin = src->pixels + (ptrdiff_t)(ySrc + sy0) * sstride + (xSrc + sx0);

    // The image drawn onto itself: source and destination may overlap
    uint32_t *copy = NULL;
    if (dst->pixels == src->pixels) {
        size_t bytes = (size_t)src->width * (size_t)src->height * 4;
        copy = (uint32_t *)malloc(bytes);
        if (!copy) return;
        memcpy(copy, src->pixels, bytes);
        origin = copy + (ptrdiff_t)(ySrc + sy0) * sstride + (xSrc + sx0);
    }

    uint32_t *drow = dst->pixels + (ptrdiff_t)dy0 * dstride;
    int u0 = dx0 - x, count = dx1 - dx0;
    int opaque = !src->hasAlpha;

    for (int dy = dy0; dy < dy1; dy++, drow += dstride) {
        const uint32_t *s = origin + (ptrdiff_t)u0 * stepU + (ptrdiff_t)(dy - y) * stepV;
        uint32_t *d = drow + dx0;
        if (stepU == 1) {
            if (opaque) {
                memcpy(d, s, (size_t)count * 4);
            } else {
                for (int n = 0; n < count; n++) {
                    uint32_t c = s[n];
                    uint32_t a = c >> 24;
                    if (a == 255) d[n] = c;
                    else if (a) d[n] = c + scale_pixel(d[n], 255 - a);
                }
            }
        } else {
            for (int n = count; n > 0; n--, d++, s += stepU) blend(d, *s);
        }
    }
    free(copy);
}

void gfx_blit_rgb(const GfxSurface *dst, const GfxPaint *p, const int32_t *rgb, int32_t rgbLen,
                  int32_t offset, int32_t scan, int x, int y, int w, int h, int processAlpha) {
    if (w <= 0 || h <= 0 || !rgb) return;
    int dx0 = imax(x, p->cx0), dy0 = imax(y, p->cy0);
    int dx1 = imin(sat_add(x, w), p->cx1), dy1 = imin(sat_add(y, h), p->cy1);
    if (dx0 >= dx1 || dy0 >= dy1) return;
    for (int dy = dy0; dy < dy1; dy++) {
        uint32_t *d = dst->pixels + (ptrdiff_t)dy * dst->width;
        for (int dx = dx0; dx < dx1; dx++) {
            int64_t i = (int64_t)offset + (int64_t)(dy - y) * scan + (dx - x);
            if (i < 0 || i >= rgbLen) continue;
            uint32_t c = (uint32_t)rgb[i];
            if (!processAlpha) { d[dx] = c | 0xFF000000u; continue; }
            uint32_t a = c >> 24;
            if (a == 255) d[dx] = c;
            else if (a) blend(d + dx, gfx_premultiply(c));
        }
    }
}

static inline uint32_t unpremultiply(uint32_t c) {
    uint32_t a = c >> 24;
    if (a == 255 || a == 0) return a ? c : 0;
    uint32_t r = (c >> 16) & 0xFF, g = (c >> 8) & 0xFF, b = c & 0xFF;
    r = (r * 255 + a / 2) / a;
    g = (g * 255 + a / 2) / a;
    b = (b * 255 + a / 2) / a;
    if (r > 255) r = 255;
    if (g > 255) g = 255;
    if (b > 255) b = 255;
    return (a << 24) | (r << 16) | (g << 8) | b;
}

void gfx_read_rgb(const GfxSurface *src, int32_t *out, int32_t outLen, int32_t offset, int32_t scan,
                  int x, int y, int w, int h) {
    if (w <= 0 || h <= 0 || !out) return;
    for (int row = 0; row < h; row++) {
        int sy = y + row;
        if (sy < 0 || sy >= src->height) continue;
        const uint32_t *s = src->pixels + (ptrdiff_t)sy * src->width;
        for (int col = 0; col < w; col++) {
            int sx = x + col;
            if (sx < 0 || sx >= src->width) continue;
            int64_t i = (int64_t)offset + (int64_t)row * scan + col;
            if (i < 0 || i >= outLen) continue;
            out[i] = (int32_t)unpremultiply(s[sx]);
        }
    }
}

void gfx_copy_area(const GfxSurface *s, const GfxPaint *p, int xSrc, int ySrc, int w, int h, int xDst, int yDst) {
    if (w <= 0 || h <= 0) return;
    int dx0 = imax(xDst, p->cx0), dy0 = imax(yDst, p->cy0);
    int dx1 = imin(sat_add(xDst, w), p->cx1), dy1 = imin(sat_add(yDst, h), p->cy1);
    // Keep the source inside the surface too
    dx0 = imax(dx0, xDst - xSrc);
    dy0 = imax(dy0, yDst - ySrc);
    dx1 = imin(dx1, xDst - xSrc + s->width);
    dy1 = imin(dy1, yDst - ySrc + s->height);
    if (dx0 >= dx1 || dy0 >= dy1) return;
    int n = dx1 - dx0, rows = dy1 - dy0;
    int downwards = yDst > ySrc;
    for (int i = 0; i < rows; i++) {
        int dy = downwards ? dy1 - 1 - i : dy0 + i;
        int sy = dy - yDst + ySrc, sx = dx0 - xDst + xSrc;
        memmove(s->pixels + (ptrdiff_t)dy * s->width + dx0,
                s->pixels + (ptrdiff_t)sy * s->width + sx, (size_t)n * 4);
    }
}

void gfx_blit_mask(const GfxSurface *dst, const GfxPaint *p, const uint8_t *mask, int maskW, int maskH, int x, int y) {
    if (!mask) return;
    int dx0 = imax(x, p->cx0), dy0 = imax(y, p->cy0);
    int dx1 = imin(x + maskW, p->cx1), dy1 = imin(y + maskH, p->cy1);
    if (dx0 >= dx1 || dy0 >= dy1) return;
    uint32_t c = p->premul;
    for (int dy = dy0; dy < dy1; dy++) {
        const uint8_t *m = mask + (ptrdiff_t)(dy - y) * maskW + (dx0 - x);
        uint32_t *d = dst->pixels + (ptrdiff_t)dy * dst->width + dx0;
        for (int n = dx1 - dx0; n > 0; n--, m++, d++) {
            uint32_t cov = *m;
            if (cov == 255) blend(d, c);
            else if (cov) blend(d, scale_pixel(c, cov));
        }
    }
}

void gfx_store_rgb(GfxSurface *dst, const int32_t *rgb, int32_t rgbLen, int processAlpha) {
    if (!rgb) return;
    int64_t n = (int64_t)dst->width * dst->height;
    if (n > rgbLen) n = rgbLen;
    int anyAlpha = 0;
    for (int64_t i = 0; i < n; i++) {
        uint32_t c = (uint32_t)rgb[i];
        if (!processAlpha) { dst->pixels[i] = c | 0xFF000000u; continue; }
        if ((c >> 24) != 255) anyAlpha = 1;
        dst->pixels[i] = gfx_premultiply(c);
    }
    dst->hasAlpha = processAlpha ? anyAlpha : 0;
}

void gfx_downscale_rgba(const uint8_t *rgba, int sw, int sh, uint32_t *dst, int dw, int dh, int dstStride, int keepAlpha) {
    if (sw <= 0 || sh <= 0 || dw <= 0 || dh <= 0) return;
    for (int y = 0; y < dh; y++) {
        int sy0 = (int)((int64_t)y * sh / dh), sy1 = (int)((int64_t)(y + 1) * sh / dh);
        if (sy1 <= sy0) sy1 = sy0 + 1;
        uint32_t *d = dst + (ptrdiff_t)y * dstStride;
        for (int x = 0; x < dw; x++) {
            int sx0 = (int)((int64_t)x * sw / dw), sx1 = (int)((int64_t)(x + 1) * sw / dw);
            if (sx1 <= sx0) sx1 = sx0 + 1;
            uint32_t r = 0, g = 0, b = 0, a = 0, n = 0;
            for (int yy = sy0; yy < sy1 && yy < sh; yy++) {
                const uint8_t *p = rgba + ((size_t)yy * sw + sx0) * 4;
                for (int xx = sx0; xx < sx1 && xx < sw; xx++, p += 4) {
                    r += p[0]; g += p[1]; b += p[2]; a += p[3]; n++;
                }
            }
            if (!n) continue;
            uint32_t aa = keepAlpha ? a / n : 255;
            d[x] = (aa << 24) | ((r / n) << 16) | ((g / n) << 8) | (b / n);
        }
    }
}
