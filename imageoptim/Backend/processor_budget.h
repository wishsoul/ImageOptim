#ifndef IO_PROCESSOR_BUDGET_H
#define IO_PROCESSOR_BUDGET_H

#ifdef __cplusplus
extern "C" {
#endif

typedef struct io_cpu_topology {
    int performance_cores;
    int efficiency_cores;
    int logical_cpus;
} io_cpu_topology;

void io_cpu_topology_current(io_cpu_topology *out);

/* Cores this QoS will actually run on. Performance cores for interactive work
   so Apple Silicon efficiency cores stay free for the UI; efficiency cores
   when the user asked for low priority. Intel machines report no split and
   use every logical CPU. */
int io_heavy_core_budget(const io_cpu_topology *topo, int low_priority);

/* How many heavy tool processes to run at once. Matches the core budget so
   single-thread tools (jpegtran, zopfli) occupy one fast core each. */
int io_recommend_queue_width(const io_cpu_topology *topo, int low_priority);

/* Threads one tool may use. operation_count is the CPU queue depth, including
   work that has not started, so a full batch gets one thread per core instead
   of every oxipng spawning a pool the size of the machine. */
int io_threads_for_worker(int core_budget, int queue_width, int operation_count);

#ifdef __cplusplus
}
#endif

#endif
