//
//  gfx_platform.h
//  JarBox Graphics Engine — services implemented per platform
//  (gfx_platform_ios.m on iOS; tools/hostrun on the desktop test host).
//

#ifndef GFX_PLATFORM_H
#define GFX_PLATFORM_H

#include "gfx_core.h"

#ifdef __cplusplus
extern "C" {
#endif

/// Show a finished frame. Must copy the pixels before returning.
void gfx_platform_present(const GfxSurface *screen);

/// Decode a non-PNG image (JPEG, GIF, BMP…). Returns 1 and a malloc'd premultiplied buffer.
int gfx_platform_decode_image(const uint8_t *data, int32_t length, int32_t *w, int32_t *h,
                              uint32_t **pixels, int32_t *hasAlpha);

void gfx_platform_vibrate(int durationMs);

/// Release per-session platform state.
void gfx_platform_reset(void);

#ifdef __cplusplus
}
#endif

#endif /* GFX_PLATFORM_H */
