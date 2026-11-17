#ifndef IO_PNG_FILTER_SCORE_KERNEL_H
#define IO_PNG_FILTER_SCORE_KERNEL_H

/* Shared by the CPU scorer and the Metal compute shader. Integer only, so
   fast-math cannot change which filter wins. */

#if !defined(__METAL_VERSION__)
#include <stdint.h>
#endif

#if defined(__METAL_VERSION__)
#define IO_FILTER_PTR device
#else
#define IO_FILTER_PTR
#endif

typedef struct io_png_filter_params {
    uint32_t height;
    uint32_t row_stride;
    uint32_t row_bytes;
    uint32_t bytes_per_pixel;
} io_png_filter_params;

static inline uint32_t io_filter_abs8(uint8_t value) {
    return value < 128 ? (uint32_t)value : (uint32_t)(256u - value);
}

static inline uint8_t io_filter_paeth(uint8_t left, uint8_t up, uint8_t up_left) {
    int prediction = (int)left + (int)up - (int)up_left;
    int distance_left = prediction - (int)left;
    int distance_up = prediction - (int)up;
    int distance_up_left = prediction - (int)up_left;
    if (distance_left < 0) distance_left = -distance_left;
    if (distance_up < 0) distance_up = -distance_up;
    if (distance_up_left < 0) distance_up_left = -distance_up_left;
    if (distance_left <= distance_up && distance_left <= distance_up_left) {
        return left;
    }
    if (distance_up <= distance_up_left) {
        return up;
    }
    return up_left;
}

/* Minimum sum of absolute differences, PNG filter codes 0-4.
   Equal sums keep the lower code so CPU and GPU picks match. */
static inline int io_best_filter_for_row(const IO_FILTER_PTR uint8_t *row,
                                          const IO_FILTER_PTR uint8_t *previous,
                                          int has_previous,
                                          uint32_t row_bytes,
                                          uint32_t bytes_per_pixel) {
    uint64_t sums[5];
    uint32_t i;
    int filter;

    sums[0] = 0;
    sums[1] = 0;
    sums[2] = 0;
    sums[3] = 0;
    sums[4] = 0;

    if (!row || row_bytes == 0 || bytes_per_pixel == 0) {
        return 0;
    }

    for (i = 0; i < row_bytes; i++) {
        uint8_t pixel = row[i];
        uint8_t left = i >= bytes_per_pixel ? row[i - bytes_per_pixel] : 0;
        uint8_t up = 0;
        uint8_t up_left = 0;
        uint8_t average;
        uint8_t paeth;

        if (has_previous && previous) {
            up = previous[i];
            if (i >= bytes_per_pixel) {
                up_left = previous[i - bytes_per_pixel];
            }
        }

        average = (uint8_t)(((unsigned)left + (unsigned)up) / 2u);
        paeth = io_filter_paeth(left, up, up_left);

        sums[0] += io_filter_abs8(pixel);
        sums[1] += io_filter_abs8((uint8_t)(pixel - left));
        sums[2] += io_filter_abs8((uint8_t)(pixel - up));
        sums[3] += io_filter_abs8((uint8_t)(pixel - average));
        sums[4] += io_filter_abs8((uint8_t)(pixel - paeth));
    }

    filter = 0;
    for (i = 1; i < 5; i++) {
        if (sums[i] < sums[filter]) {
            filter = (int)i;
        }
    }
    return filter;
}

#endif
