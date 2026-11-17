@import Foundation;

NS_ASSUME_NONNULL_BEGIN

@interface ProcessorBudget : NSObject

+ (ProcessorBudget *)sharedBudget;
+ (NSInteger)recommendedFileConcurrencyForLowPriority:(BOOL)lowPriority;

- (void)attachCPUQueue:(NSOperationQueue *)queue defaults:(NSUserDefaults *)defaults;
- (NSInteger)threadsForCPUWork;
- (NSInteger)heavyCoreBudget;

@end

NS_ASSUME_NONNULL_END
