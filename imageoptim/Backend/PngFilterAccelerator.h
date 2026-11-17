@import Foundation;

NS_ASSUME_NONNULL_BEGIN

@interface PngFilterAccelerator : NSObject

+ (BOOL)metalAvailable;

/* Decode a large PNG and score filters 0-4. Metal runs one thread per row
   when a GPU is present; otherwise the same scorer runs across CPU cores.
   YES means one filter dominates and oxipng --fast is unlikely to change
   the winner. */
+ (BOOL)recommendFastEvaluationForPNGAtURL:(NSURL *)url;

@end

NS_ASSUME_NONNULL_END
