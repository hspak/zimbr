/* Compare native Cairo tiles with legacy straight-RGBA baselines outside timed work. */
#pragma once
#include "bridge.h"
#include <assert.h>
#include <stdint.h>
#include <string.h>

static int comparable_text_pixels(ZcText *text, unsigned char *pixels, int height) {
    const int width = zc_text_width(text);
#if ZIMBR_TEXT_NATIVE_ARGB
    const int pitch = zc_text_pitch(text);
    assert(pitch >= width * 4);
    for (int y = 0; y < height; y++) for (int x = 0; x < width; x++) {
        unsigned char *p = pixels + (size_t)y * pitch + x * 4;
        uint32_t argb;
        memcpy(&argb, p, sizeof(argb));
        const unsigned a = argb >> 24, r = (argb >> 16) & 255, g = (argb >> 8) & 255, b = argb & 255;
        assert(r <= a && g <= a && b <= a);
        p[0] = a ? (unsigned char)(r * 255 / a) : 0;
        p[1] = a ? (unsigned char)(g * 255 / a) : 0;
        p[2] = a ? (unsigned char)(b * 255 / a) : 0;
        p[3] = (unsigned char)a;
    }
    return pitch;
#else
    (void)pixels;
    (void)height;
    return width * 4;
#endif
}
