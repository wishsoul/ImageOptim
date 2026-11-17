#include <metal_stdlib>
using namespace metal;

#include "png_filter_score_kernel.h"

/* One thread per scanline. The winner matches io_score_png_filters. */
kernel void png_filter_wins(const device uint8_t *pixels [[buffer(0)]],
                            device atomic_uint *wins [[buffer(1)]],
                            constant io_png_filter_params &params [[buffer(2)]],
                            uint gid [[thread_position_in_grid]]) {
    const device uint8_t *row;
    const device uint8_t *previous;
    int best;

    if (gid >= params.height || params.row_bytes == 0 || params.bytes_per_pixel == 0) {
        return;
    }

    row = pixels + gid * params.row_stride;
    previous = row;
    if (gid > 0) {
        previous = row - params.row_stride;
    }
    best = io_best_filter_for_row(row, previous, gid > 0, params.row_bytes, params.bytes_per_pixel);
    if (best < 0 || best > 4) {
        best = 0;
    }
    atomic_fetch_add_explicit(&wins[best], 1u, memory_order_relaxed);
}
