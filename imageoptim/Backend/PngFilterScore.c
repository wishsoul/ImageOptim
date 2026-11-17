#include "PngFilterScore.h"
#include "png_filter_score_kernel.h"

#include <pthread.h>
#include <string.h>

typedef struct io_filter_slice {
    const uint8_t *pixels;
    uint32_t row_bytes;
    uint32_t row_stride;
    uint32_t bytes_per_pixel;
    uint32_t y0;
    uint32_t y1;
    uint32_t wins[5];
} io_filter_slice;

static void io_score_slice(io_filter_slice *slice) {
    uint32_t y;
    memset(slice->wins, 0, sizeof(slice->wins));
    for (y = slice->y0; y < slice->y1; y++) {
        const uint8_t *row = slice->pixels + (size_t)y * slice->row_stride;
        const uint8_t *previous = row;
        int has_previous = y > 0;
        int best;
        if (has_previous) {
            previous = row - slice->row_stride;
        }
        best = io_best_filter_for_row(row, previous, has_previous, slice->row_bytes, slice->bytes_per_pixel);
        if (best < 0 || best > 4) {
            best = 0;
        }
        slice->wins[best]++;
    }
}

static void *io_score_slice_thread(void *argument) {
    io_score_slice((io_filter_slice *)argument);
    return NULL;
}

int io_score_png_filters(const uint8_t *pixels,
                         uint32_t row_bytes,
                         uint32_t row_stride,
                         uint32_t height,
                         uint32_t bytes_per_pixel,
                         int threads,
                         io_filter_histogram *out) {
    io_filter_slice slices[32];
    pthread_t thread_ids[32];
    int started[32];
    int thread_count;
    uint32_t base;
    uint32_t remainder;
    uint32_t cursor;
    int index;

    if (out) {
        memset(out, 0, sizeof(*out));
    }
    if (!out || !pixels || height == 0 || row_bytes == 0 || bytes_per_pixel == 0 || row_stride < row_bytes) {
        return -1;
    }
    if (height > 1 && row_stride > UINT32_MAX / (height - 1)) {
        return -1;
    }

    thread_count = threads;
    if (thread_count < 1) {
        thread_count = 1;
    }
    if (thread_count > (int)height) {
        thread_count = (int)height;
    }
    if (thread_count > 32) {
        thread_count = 32;
    }

    base = height / (uint32_t)thread_count;
    remainder = height % (uint32_t)thread_count;
    cursor = 0;
    for (index = 0; index < thread_count; index++) {
        uint32_t count = base + ((uint32_t)index < remainder ? 1u : 0u);
        started[index] = 0;
        memset(&slices[index], 0, sizeof(slices[index]));
        slices[index].pixels = pixels;
        slices[index].row_bytes = row_bytes;
        slices[index].row_stride = row_stride;
        slices[index].bytes_per_pixel = bytes_per_pixel;
        slices[index].y0 = cursor;
        slices[index].y1 = cursor + count;
        cursor += count;
    }

    if (thread_count == 1) {
        io_score_slice(&slices[0]);
    } else {
        for (index = 0; index < thread_count; index++) {
            if (slices[index].y0 == slices[index].y1) {
                continue;
            }
            if (pthread_create(&thread_ids[index], NULL, io_score_slice_thread, &slices[index]) == 0) {
                started[index] = 1;
            } else {
                io_score_slice(&slices[index]);
            }
        }
        for (index = 0; index < thread_count; index++) {
            if (started[index]) {
                pthread_join(thread_ids[index], NULL);
            }
        }
    }

    out->row_count = height;
    for (index = 0; index < thread_count; index++) {
        int filter;
        for (filter = 0; filter < 5; filter++) {
            out->wins[filter] += slices[index].wins[filter];
        }
    }
    return 0;
}

int io_filter_fast_path_ok(const io_filter_histogram *histogram) {
    uint32_t best;
    int filter;
    if (!histogram || histogram->row_count < IO_FILTER_FAST_PATH_MIN_ROWS) {
        return 0;
    }
    best = 0;
    for (filter = 0; filter < 5; filter++) {
        if (histogram->wins[filter] > best) {
            best = histogram->wins[filter];
        }
    }
    return (uint64_t)best * 100u >= (uint64_t)histogram->row_count * (uint64_t)IO_FILTER_FAST_PATH_MIN_PERCENT;
}
