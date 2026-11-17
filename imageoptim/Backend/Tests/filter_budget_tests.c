#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "../processor_budget.h"
#include "../PngFilterScore.h"

static int failures = 0;

static void expect_int(const char *name, int actual, int expected) {
    if (actual != expected) {
        fprintf(stderr, "FAIL %s: got %d expected %d\n", name, actual, expected);
        failures++;
    }
}

static void expect_true(const char *name, int value) {
    if (!value) {
        fprintf(stderr, "FAIL %s\n", name);
        failures++;
    }
}

static uint32_t win_sum(const io_filter_histogram *histogram) {
    return histogram->wins[0] + histogram->wins[1] + histogram->wins[2] + histogram->wins[3] + histogram->wins[4];
}

static void test_budget(void) {
    io_cpu_topology apple;
    io_cpu_topology intel;
    io_cpu_topology current;

    memset(&apple, 0, sizeof(apple));
    apple.performance_cores = 8;
    apple.efficiency_cores = 2;
    apple.logical_cpus = 10;

    memset(&intel, 0, sizeof(intel));
    intel.logical_cpus = 8;

    expect_int("apple interactive width", io_recommend_queue_width(&apple, 0), 8);
    expect_int("apple low priority width", io_recommend_queue_width(&apple, 1), 2);
    expect_int("apple interactive budget", io_heavy_core_budget(&apple, 0), 8);
    expect_int("apple low priority budget", io_heavy_core_budget(&apple, 1), 2);
    expect_int("intel width", io_recommend_queue_width(&intel, 0), 8);
    expect_int("intel low priority still uses logical", io_recommend_queue_width(&intel, 1), 8);
    expect_int("null width", io_recommend_queue_width(NULL, 0), 1);

    expect_int("full queue one thread", io_threads_for_worker(8, 8, 8), 1);
    expect_int("backlog stays one thread", io_threads_for_worker(8, 8, 100), 1);
    expect_int("single file takes the machine", io_threads_for_worker(8, 8, 1), 8);
    expect_int("two files split", io_threads_for_worker(8, 8, 2), 4);
    expect_int("three files ceil", io_threads_for_worker(8, 8, 3), 3);
    expect_int("user narrower queue", io_threads_for_worker(8, 4, 4), 2);
    expect_int("empty budget becomes one", io_threads_for_worker(0, 0, 0), 1);

    io_cpu_topology_current(&current);
    expect_true("current machine has a CPU", current.logical_cpus >= 1);
}

static void test_known_rows(void) {
    uint8_t rows[3][3] = {
        {5, 5, 5},
        {6, 6, 6},
        {7, 7, 7},
    };
    io_filter_histogram histogram;
    int status = io_score_png_filters(&rows[0][0], 3, 3, 3, 1, 1, &histogram);

    expect_int("known status", status, 0);
    expect_int("known rows", (int)histogram.row_count, 3);
    expect_int("known none", (int)histogram.wins[0], 0);
    expect_int("known sub", (int)histogram.wins[1], 1);
    expect_int("known up", (int)histogram.wins[2], 0);
    expect_int("known average", (int)histogram.wins[3], 0);
    expect_int("known paeth", (int)histogram.wins[4], 2);
    expect_int("short image is not fast", io_filter_fast_path_ok(&histogram), 0);
}

static void test_parallel_matches_and_fast_path(void) {
    enum { width = 8, height = 128, stride = 8 };
    uint8_t *pixels = calloc((size_t)height * stride, 1);
    io_filter_histogram one_thread;
    io_filter_histogram many_threads;
    io_filter_histogram zeros;
    uint8_t *zero_pixels;
    int y;
    int x;

    expect_true("pixels allocated", pixels != NULL);
    if (!pixels) {
        return;
    }
    for (y = 0; y < height; y++) {
        for (x = 0; x < width; x++) {
            pixels[(size_t)y * stride + (size_t)x] = (uint8_t)(y + 1);
        }
    }

    expect_int("serial status", io_score_png_filters(pixels, width, stride, height, 1, 1, &one_thread), 0);
    expect_int("parallel status", io_score_png_filters(pixels, width, stride, height, 1, 7, &many_threads), 0);
    expect_int("parallel row count", (int)many_threads.row_count, height);
    expect_int("parallel covers every row", (int)win_sum(&many_threads), height);
    expect_int("none matches", (int)one_thread.wins[0], (int)many_threads.wins[0]);
    expect_int("sub matches", (int)one_thread.wins[1], (int)many_threads.wins[1]);
    expect_int("up matches", (int)one_thread.wins[2], (int)many_threads.wins[2]);
    expect_int("average matches", (int)one_thread.wins[3], (int)many_threads.wins[3]);
    expect_int("paeth matches", (int)one_thread.wins[4], (int)many_threads.wins[4]);
    expect_true("vertical ramp is mostly paeth", many_threads.wins[4] >= 120);
    expect_int("vertical ramp can use fast evaluation", io_filter_fast_path_ok(&many_threads), 1);

    zero_pixels = calloc(64 * 4, 1);
    expect_true("zeros allocated", zero_pixels != NULL);
    if (zero_pixels) {
        expect_int("zero status", io_score_png_filters(zero_pixels, 4, 4, 64, 1, 3, &zeros), 0);
        expect_int("flat zero picks none", (int)zeros.wins[0], 64);
        expect_int("flat zero is fast", io_filter_fast_path_ok(&zeros), 1);
        expect_int("bad stride rejected", io_score_png_filters(zero_pixels, 4, 2, 64, 1, 1, &zeros), -1);
    }

    free(zero_pixels);
    free(pixels);
}

int main(void) {
    test_budget();
    test_known_rows();
    test_parallel_matches_and_fast_path();
    if (failures) {
        fprintf(stderr, "%d failure(s)\n", failures);
        return 1;
    }
    printf("filter budget tests passed\n");
    return 0;
}
