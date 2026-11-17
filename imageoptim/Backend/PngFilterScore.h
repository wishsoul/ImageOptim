#ifndef IO_PNG_FILTER_SCORE_H
#define IO_PNG_FILTER_SCORE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define IO_FILTER_FAST_PATH_MIN_ROWS 64
#define IO_FILTER_FAST_PATH_MIN_PERCENT 90

typedef struct io_filter_histogram {
    uint32_t row_count;
    uint32_t wins[5];
} io_filter_histogram;

/* Score PNG filters 0-4 over packed 8-bit rows. threads <= 1 runs inline.
   row_stride is bytes from one row to the next and may include padding.
   Returns 0 on success. */
int io_score_png_filters(const uint8_t *pixels,
                         uint32_t row_bytes,
                         uint32_t row_stride,
                         uint32_t height,
                         uint32_t bytes_per_pixel,
                         int threads,
                         io_filter_histogram *out);

/* True when one basic filter wins almost every row of a large image.
   oxipng can then take its fast evaluation path without a wide search. */
int io_filter_fast_path_ok(const io_filter_histogram *histogram);

#ifdef __cplusplus
}
#endif

#endif
