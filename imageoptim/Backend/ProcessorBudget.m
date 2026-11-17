#import "ProcessorBudget.h"
#import "processor_budget.h"

#include <limits.h>

@interface ProcessorBudget ()
@property (weak) NSOperationQueue *cpuQueue;
@property (strong) NSUserDefaults *defaults;
@property (assign) io_cpu_topology topology;
@end

@implementation ProcessorBudget

+ (ProcessorBudget *)sharedBudget {
    static ProcessorBudget *budget;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        budget = [ProcessorBudget new];
    });
    return budget;
}

+ (NSInteger)recommendedFileConcurrencyForLowPriority:(BOOL)lowPriority {
    return [[self sharedBudget] heavyCoreBudgetForLowPriority:lowPriority];
}

- (instancetype)init {
    self = [super init];
    if (self) {
        io_cpu_topology_current(&_topology);
    }
    return self;
}

- (void)attachCPUQueue:(NSOperationQueue *)queue defaults:(NSUserDefaults *)defaults {
    self.cpuQueue = queue;
    self.defaults = defaults;
}

- (BOOL)isLowPriority {
    return [self.defaults boolForKey:@"RunLowPriority"];
}

- (NSInteger)heavyCoreBudgetForLowPriority:(BOOL)lowPriority {
    int budget = io_heavy_core_budget(&_topology, lowPriority ? 1 : 0);
    return budget > 0 ? budget : 1;
}

- (NSInteger)heavyCoreBudget {
    return [self heavyCoreBudgetForLowPriority:[self isLowPriority]];
}

- (NSInteger)threadsForCPUWork {
    int budget = (int)[self heavyCoreBudget];
    int width = budget;
    int operations = 1;
    NSOperationQueue *queue = self.cpuQueue;

    if (queue) {
        NSInteger queueWidth = queue.maxConcurrentOperationCount;
        if (queueWidth > 0) {
            width = (int)MIN(queueWidth, (NSInteger)INT_MAX);
        }
        NSInteger queued = queue.operationCount;
        if (queued > 0) {
            operations = (int)MIN(queued, (NSInteger)INT_MAX);
        }
    }

    int threads = io_threads_for_worker(budget, width, operations);
    return threads > 0 ? threads : 1;
}

@end
