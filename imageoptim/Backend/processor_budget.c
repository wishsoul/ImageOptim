#include "processor_budget.h"

#include <string.h>
#include <unistd.h>

#if defined(__APPLE__)
#include <sys/sysctl.h>
#endif

static int io_sysctl_int(const char *name) {
#if defined(__APPLE__)
    int value = 0;
    size_t length = sizeof(value);
    if (sysctlbyname(name, &value, &length, NULL, 0) != 0 || value < 0) {
        return 0;
    }
    return value;
#else
    (void)name;
    return 0;
#endif
}

void io_cpu_topology_current(io_cpu_topology *out) {
    if (!out) {
        return;
    }
    memset(out, 0, sizeof(*out));
    out->performance_cores = io_sysctl_int("hw.perflevel0.physicalcpu");
    out->efficiency_cores = io_sysctl_int("hw.perflevel1.physicalcpu");
    out->logical_cpus = io_sysctl_int("hw.logicalcpu");
    if (out->logical_cpus <= 0) {
        long online = sysconf(_SC_NPROCESSORS_ONLN);
        out->logical_cpus = online > 0 ? (int)online : 1;
    }
}

int io_heavy_core_budget(const io_cpu_topology *topo, int low_priority) {
    return io_recommend_queue_width(topo, low_priority);
}

int io_recommend_queue_width(const io_cpu_topology *topo, int low_priority) {
    if (!topo) {
        return 1;
    }
    if (low_priority && topo->efficiency_cores > 0) {
        return topo->efficiency_cores;
    }
    if (topo->performance_cores > 0) {
        return topo->performance_cores;
    }
    if (topo->logical_cpus > 0) {
        return topo->logical_cpus;
    }
    return 1;
}

int io_threads_for_worker(int core_budget, int queue_width, int operation_count) {
    if (core_budget < 1) {
        core_budget = 1;
    }
    if (queue_width < 1) {
        queue_width = core_budget;
    }
    if (operation_count < 1) {
        operation_count = 1;
    }

    int slots = operation_count < queue_width ? operation_count : queue_width;
    if (slots < 1) {
        slots = 1;
    }

    int threads = (core_budget + slots - 1) / slots;
    if (threads < 1) {
        threads = 1;
    }
    if (threads > core_budget) {
        threads = core_budget;
    }
    return threads;
}
