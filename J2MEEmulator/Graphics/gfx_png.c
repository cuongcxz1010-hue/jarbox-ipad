//
//  gfx_png.c
//  JarBox Graphics Engine — PNG decoder and encoder
//
//  J2ME games ship almost only PNG. Decoding them here (instead of through
//  ImageIO) keeps colours exact: no colour management or gamma conversion,
//  which matters to games that compare pixel values read back with getRGB.
//

#include "Graphics/gfx_core.h"
#include "../minijvm/utils/miniz.h"
#include <stdlib.h>
#include <string.h>

static inline uint32_t be32(const uint8_t *p) {
    return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) | ((uint32_t)p[2] << 8) | p[3];
}

static inline uint8_t paeth(int a, int b, int c) {
    int p = a + b - c, pa = abs(p - a), pb = abs(p - b), pc = abs(p - c);
    if (pa <= pb && pa <= pc) return (uint8_t)a;
    return (uint8_t)(pb <= pc ? b : c);
}

/// Undo PNG scanline filters for one (sub)image in place.
static int unfilter(uint8_t *raw, size_t rawLen, int rowBytes, int rows, int bpp) {
    if ((size_t)(rowBytes + 1) * (size_t)rows > rawLen) return 0;
    uint8_t *prev = NULL;
    uint8_t *line = raw;
    for (int y = 0; y < rows; y++, line += rowBytes + 1) {
        int f = line[0];
        uint8_t *cur = line + 1;
        switch (f) {
            case 0: break;
            case 1:
                for (int i = bpp; i < rowBytes; i++) cur[i] = (uint8_t)(cur[i] + cur[i - bpp]);
                break;
            case 2:
                if (prev) for (int i = 0; i < rowBytes; i++) cur[i] = (uint8_t)(cur[i] + prev[i]);
                break;
            case 3:
                for (int i = 0; i < rowBytes; i++) {
                    int a = i >= bpp ? cur[i - bpp] : 0, b = prev ? prev[i] : 0;
                    cur[i] = (uint8_t)(cur[i] + (a + b) / 2);
                }
                break;
            case 4:
                for (int i = 0; i < rowBytes; i++) {
                    int a = i >= bpp ? cur[i - bpp] : 0, b = prev ? prev[i] : 0;
                    int c = (i >= bpp && prev) ? prev[i - bpp] : 0;
                    cur[i] = (uint8_t)(cur[i] + paeth(a, b, c));
                }
                break;
            default:
                return 0;
        }
        prev = cur;
    }
    return 1;
}

typedef struct {
    int colorType, depth, channels;
    const uint8_t *palette;
    uint32_t paletteLen;
    const uint8_t *trns;
    uint32_t trnsLen;
    int hasAlpha;
} PngInfo;

static inline int sample(const uint8_t *row, int index, int depth) {
    switch (depth) {
        case 8:  return row[index];
        case 16: return row[index * 2];
        case 4:  return (row[index >> 1] >> (((~index) & 1) * 4)) & 15;
        case 2:  return (row[index >> 2] >> (((~index) & 3) * 2)) & 3;
        default: return (row[index >> 3] >> ((~index) & 7)) & 1;
    }
}

static inline int sample16(const uint8_t *row, int index) {
    return (row[index * 2] << 8) | row[index * 2 + 1];
}

/// Colour of pixel x of an unfiltered row, premultiplied.
static inline uint32_t row_pixel(const uint8_t *row, int x, PngInfo *png) {
    uint32_t a = 255, r, g, b;
    switch (png->colorType) {
        case 0: {       // gray
            int v = sample(row, x, png->depth);
            int full = png->depth == 16 ? sample16(row, x) : v;
            if (png->trnsLen >= 2) {
                int t = (png->trns[0] << 8) | png->trns[1];
                if (full == t) a = 0;
            }
            int shown = png->depth >= 8 ? v : v * 255 / ((1 << png->depth) - 1);
            r = g = b = (uint32_t)shown;
            break;
        }
        case 2: {       // RGB
            r = (uint32_t)sample(row, x * 3, png->depth);
            g = (uint32_t)sample(row, x * 3 + 1, png->depth);
            b = (uint32_t)sample(row, x * 3 + 2, png->depth);
            if (png->trnsLen >= 6) {
                int rr, gg, bb;
                if (png->depth == 16) {
                    rr = sample16(row, x * 3); gg = sample16(row, x * 3 + 1); bb = sample16(row, x * 3 + 2);
                } else {
                    rr = (int)r; gg = (int)g; bb = (int)b;
                }
                if (rr == ((png->trns[0] << 8) | png->trns[1]) && gg == ((png->trns[2] << 8) | png->trns[3]) &&
                    bb == ((png->trns[4] << 8) | png->trns[5])) a = 0;
            }
            break;
        }
        case 3: {       // palette
            uint32_t i = (uint32_t)sample(row, x, png->depth);
            if (i * 3 + 2 >= png->paletteLen) { r = g = b = 0; break; }
            r = png->palette[i * 3]; g = png->palette[i * 3 + 1]; b = png->palette[i * 3 + 2];
            if (i < png->trnsLen) a = png->trns[i];
            break;
        }
        case 4: {       // gray + alpha
            r = g = b = (uint32_t)sample(row, x * 2, png->depth);
            a = (uint32_t)sample(row, x * 2 + 1, png->depth);
            break;
        }
        default: {      // RGBA
            r = (uint32_t)sample(row, x * 4, png->depth);
            g = (uint32_t)sample(row, x * 4 + 1, png->depth);
            b = (uint32_t)sample(row, x * 4 + 2, png->depth);
            a = (uint32_t)sample(row, x * 4 + 3, png->depth);
            break;
        }
    }
    if (a != 255) png->hasAlpha = 1;
    return gfx_premultiply((a << 24) | (r << 16) | (g << 8) | b);
}

int gfx_png_decode(const uint8_t *data, int32_t length, int32_t *outW, int32_t *outH,
                   uint32_t **outPixels, int32_t *outHasAlpha) {
    static const uint8_t SIG[8] = {137, 80, 78, 71, 13, 10, 26, 10};
    if (length < 33 || memcmp(data, SIG, 8) != 0) return 0;

    int width = 0, height = 0, interlace = 0;
    PngInfo png;
    memset(&png, 0, sizeof(png));

    // Walk the chunks, gathering IDAT
    size_t idatSize = 0, idatCap = (size_t)length;
    uint8_t *idat = (uint8_t *)malloc(idatCap);
    if (!idat) return 0;

    int32_t pos = 8, sawHeader = 0;
    while (pos + 8 <= length) {
        uint32_t len = be32(data + pos);
        const uint8_t *type = data + pos + 4;
        if (len > (uint32_t)(length - pos - 8)) len = (uint32_t)(length - pos - 8);     // truncated: use what is there
        const uint8_t *body = data + pos + 8;
        if (!memcmp(type, "IHDR", 4) && len >= 13) {
            width = (int)be32(body);
            height = (int)be32(body + 4);
            png.depth = body[8];
            png.colorType = body[9];
            interlace = body[12];
            sawHeader = 1;
        } else if (!memcmp(type, "PLTE", 4)) {
            png.palette = body;
            png.paletteLen = len;
        } else if (!memcmp(type, "tRNS", 4)) {
            png.trns = body;
            png.trnsLen = len;
        } else if (!memcmp(type, "IDAT", 4)) {
            memcpy(idat + idatSize, body, len);
            idatSize += len;
        } else if (!memcmp(type, "IEND", 4)) {
            break;
        }
        pos += 8 + (int32_t)len + 4;
    }

    if (!sawHeader || width <= 0 || height <= 0 || width > 16384 || height > 16384 || idatSize == 0) {
        free(idat);
        return 0;
    }
    switch (png.colorType) {
        case 0: png.channels = 1; break;
        case 2: png.channels = 3; break;
        case 3: png.channels = 1; break;
        case 4: png.channels = 2; break;
        case 6: png.channels = 4; break;
        default: free(idat); return 0;
    }
    if (png.depth != 1 && png.depth != 2 && png.depth != 4 && png.depth != 8 && png.depth != 16) {
        free(idat);
        return 0;
    }

    int bitsPerPixel = png.channels * png.depth;
    int bpp = bitsPerPixel < 8 ? 1 : bitsPerPixel / 8;

    size_t rawLen = 0;
    uint8_t *raw = (uint8_t *)tinfl_decompress_mem_to_heap(idat, idatSize, &rawLen, TINFL_FLAG_PARSE_ZLIB_HEADER);
    free(idat);
    if (!raw) return 0;

    uint32_t *pixels = (uint32_t *)malloc((size_t)width * (size_t)height * 4);
    if (!pixels) { free(raw); return 0; }

    int ok = 1;
    if (!interlace) {
        int rowBytes = (int)(((int64_t)width * bitsPerPixel + 7) / 8);
        ok = unfilter(raw, rawLen, rowBytes, height, bpp);
        if (ok) {
            const uint8_t *line = raw;
            for (int y = 0; y < height; y++, line += rowBytes + 1)
                for (int x = 0; x < width; x++)
                    pixels[(size_t)y * width + x] = row_pixel(line + 1, x, &png);
        }
    } else {        // Adam7
        static const int xs[7] = {0, 4, 0, 2, 0, 1, 0}, ys[7] = {0, 0, 4, 0, 2, 0, 1};
        static const int dx[7] = {8, 8, 4, 4, 2, 2, 1}, dy[7] = {8, 8, 8, 4, 4, 2, 2};
        uint8_t *cursor = raw;
        size_t left = rawLen;
        for (int pass = 0; pass < 7 && ok; pass++) {
            int pw = width > xs[pass] ? (width - xs[pass] + dx[pass] - 1) / dx[pass] : 0;
            int ph = height > ys[pass] ? (height - ys[pass] + dy[pass] - 1) / dy[pass] : 0;
            if (pw == 0 || ph == 0) continue;
            int rowBytes = (int)(((int64_t)pw * bitsPerPixel + 7) / 8);
            size_t passBytes = (size_t)(rowBytes + 1) * (size_t)ph;
            if (passBytes > left || !unfilter(cursor, passBytes, rowBytes, ph, bpp)) { ok = 0; break; }
            const uint8_t *line = cursor;
            for (int r = 0; r < ph; r++, line += rowBytes + 1)
                for (int c = 0; c < pw; c++)
                    pixels[(size_t)(ys[pass] + r * dy[pass]) * width + xs[pass] + c * dx[pass]] = row_pixel(line + 1, c, &png);
            cursor += passBytes;
            left -= passBytes;
        }
    }
    mz_free(raw);
    if (!ok) { free(pixels); return 0; }

    *outW = width;
    *outH = height;
    *outPixels = pixels;
    *outHasAlpha = png.hasAlpha;
    return 1;
}

uint8_t *gfx_png_encode(const uint32_t *pixels, int width, int height, int32_t *outLen) {
    size_t stride = (size_t)width * 3;
    size_t rawSize = (stride + 1) * (size_t)height;
    uint8_t *raw = (uint8_t *)malloc(rawSize);
    if (!raw) return NULL;
    uint8_t *w = raw;
    for (int y = 0; y < height; y++) {
        *w++ = 0;
        const uint32_t *s = pixels + (size_t)y * width;
        for (int x = 0; x < width; x++) {
            uint32_t c = s[x];
            *w++ = (uint8_t)(c >> 16);
            *w++ = (uint8_t)(c >> 8);
            *w++ = (uint8_t)c;
        }
    }
    mz_ulong compLen = mz_compressBound((mz_ulong)rawSize);
    uint8_t *comp = (uint8_t *)malloc(compLen);
    if (!comp || mz_compress2(comp, &compLen, raw, (mz_ulong)rawSize, 6) != MZ_OK) {
        free(raw); free(comp);
        return NULL;
    }
    free(raw);

    size_t total = 8 + (12 + 13) + (12 + compLen) + 12;
    uint8_t *out = (uint8_t *)malloc(total);
    if (!out) { free(comp); return NULL; }
    uint8_t *o = out;

    static const uint8_t SIG[8] = {137, 80, 78, 71, 13, 10, 26, 10};
    memcpy(o, SIG, 8); o += 8;

#define PUT32(v) do { uint32_t _v = (v); o[0]=(uint8_t)(_v>>24); o[1]=(uint8_t)(_v>>16); o[2]=(uint8_t)(_v>>8); o[3]=(uint8_t)_v; o+=4; } while (0)

    uint8_t ihdr[13];
    uint32_t wbe = (uint32_t)width, hbe = (uint32_t)height;
    ihdr[0] = (uint8_t)(wbe >> 24); ihdr[1] = (uint8_t)(wbe >> 16); ihdr[2] = (uint8_t)(wbe >> 8); ihdr[3] = (uint8_t)wbe;
    ihdr[4] = (uint8_t)(hbe >> 24); ihdr[5] = (uint8_t)(hbe >> 16); ihdr[6] = (uint8_t)(hbe >> 8); ihdr[7] = (uint8_t)hbe;
    ihdr[8] = 8; ihdr[9] = 2; ihdr[10] = 0; ihdr[11] = 0; ihdr[12] = 0;

    PUT32(13);
    uint8_t *start = o;
    memcpy(o, "IHDR", 4); o += 4;
    memcpy(o, ihdr, 13); o += 13;
    PUT32((uint32_t)mz_crc32(0, start, (size_t)(o - start)));

    PUT32((uint32_t)compLen);
    start = o;
    memcpy(o, "IDAT", 4); o += 4;
    memcpy(o, comp, compLen); o += compLen;
    PUT32((uint32_t)mz_crc32(0, start, (size_t)(o - start)));
    free(comp);

    PUT32(0);
    start = o;
    memcpy(o, "IEND", 4); o += 4;
    PUT32((uint32_t)mz_crc32(0, start, (size_t)(o - start)));
#undef PUT32

    *outLen = (int32_t)(o - out);
    return out;
}
