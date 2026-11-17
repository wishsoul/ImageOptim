#import "PngFilterAccelerator.h"
#import "PngFilterScore.h"
#import "ProcessorBudget.h"
#import "png_filter_score_kernel.h"
#import "log.h"

#import <AppKit/AppKit.h>
#import <Metal/Metal.h>

@implementation PngFilterAccelerator

+ (id<MTLComputePipelineState>)pipelineWithDevice:(id<MTLDevice> __strong *)deviceOut {
    static id<MTLDevice> device;
    static id<MTLComputePipelineState> pipeline;
    static dispatch_once_t once;

    dispatch_once(&once, ^{
        NSError *error = nil;
        id<MTLLibrary> library;
        id<MTLFunction> function;

        device = MTLCreateSystemDefaultDevice();
        if (!device) {
            return;
        }
        library = [device newDefaultLibraryWithBundle:[NSBundle bundleForClass:self] error:&error];
        if (!library) {
            IOWarn("Metal PNG filter library unavailable: %@", error);
            device = nil;
            return;
        }
        function = [library newFunctionWithName:@"png_filter_wins"];
        if (!function) {
            IOWarn("Metal PNG filter function png_filter_wins is missing");
            device = nil;
            return;
        }
        pipeline = [device newComputePipelineStateWithFunction:function error:&error];
        if (!pipeline) {
            IOWarn("Metal PNG filter pipeline failed: %@", error);
            device = nil;
        }
    });

    if (deviceOut) {
        *deviceOut = device;
    }
    return pipeline;
}

+ (BOOL)metalAvailable {
    return [self pipelineWithDevice:NULL] != nil;
}

+ (BOOL)histogramForBitmap:(NSBitmapImageRep *)rep histogram:(io_filter_histogram *)histogram usedMetal:(BOOL *)usedMetal {
    const uint8_t *bytes;
    NSUInteger width;
    NSUInteger height;
    NSUInteger stride;
    NSUInteger bitsPerPixel;
    NSUInteger bytesPerPixel;
    NSUInteger rowBytes;
    io_png_filter_params params;
    id<MTLDevice> device = nil;
    id<MTLComputePipelineState> pipeline;

    if (usedMetal) {
        *usedMetal = NO;
    }
    if (!rep || !histogram) {
        return NO;
    }
    if (rep.bitsPerSample != 8 || rep.isPlanar || rep.numberOfPlanes != 1) {
        return NO;
    }
    if (rep.bitmapFormat & NSBitmapFormatFloatingPointSamples) {
        return NO;
    }

    bytesPerPixel = (NSUInteger)rep.samplesPerPixel;
    bitsPerPixel = (NSUInteger)rep.bitsPerPixel;
    if (bytesPerPixel < 1 || bytesPerPixel > 4 || bitsPerPixel != bytesPerPixel * 8) {
        return NO;
    }

    width = rep.pixelsWide;
    height = rep.pixelsHigh;
    stride = rep.bytesPerRow;
    rowBytes = width * bytesPerPixel;
    bytes = (const uint8_t *)rep.bitmapData;
    if (!bytes || width == 0 || height == 0 || rowBytes == 0 || stride < rowBytes) {
        return NO;
    }
    if (height > UINT32_MAX || stride > UINT32_MAX || rowBytes > UINT32_MAX) {
        return NO;
    }
    if (height > 1 && stride > UINT32_MAX / (height - 1)) {
        return NO;
    }

    params.height = (uint32_t)height;
    params.row_stride = (uint32_t)stride;
    params.row_bytes = (uint32_t)rowBytes;
    params.bytes_per_pixel = (uint32_t)bytesPerPixel;

    pipeline = [self pipelineWithDevice:&device];
    if (pipeline && device) {
        id<MTLCommandQueue> commandQueue = [device newCommandQueue];
        id<MTLBuffer> pixelBuffer = [device newBufferWithBytes:bytes
                                                        length:stride * height
                                                       options:MTLResourceStorageModeShared];
        id<MTLBuffer> winsBuffer = [device newBufferWithLength:sizeof(uint32_t) * 5
                                                       options:MTLResourceStorageModeShared];
        id<MTLBuffer> paramsBuffer = [device newBufferWithBytes:&params
                                                         length:sizeof(params)
                                                        options:MTLResourceStorageModeShared];
        id<MTLCommandBuffer> commandBuffer = [commandQueue commandBuffer];
        id<MTLComputeCommandEncoder> encoder = [commandBuffer computeCommandEncoder];
        NSUInteger threadWidth = pipeline.threadExecutionWidth;
        NSUInteger groupSize;
        NSUInteger groups;
        uint32_t *wins;

        if (commandQueue && pixelBuffer && winsBuffer && paramsBuffer && commandBuffer && encoder) {
            memset(winsBuffer.contents, 0, sizeof(uint32_t) * 5);
            if (threadWidth < 1) {
                threadWidth = 32;
            }
            groupSize = MIN(threadWidth, pipeline.maxTotalThreadsPerThreadgroup);
            if (groupSize < 1) {
                groupSize = 1;
            }
            groups = (height + groupSize - 1) / groupSize;
            [encoder setComputePipelineState:pipeline];
            [encoder setBuffer:pixelBuffer offset:0 atIndex:0];
            [encoder setBuffer:winsBuffer offset:0 atIndex:1];
            [encoder setBuffer:paramsBuffer offset:0 atIndex:2];
            [encoder dispatchThreadgroups:MTLSizeMake(groups, 1, 1)
                    threadsPerThreadgroup:MTLSizeMake(groupSize, 1, 1)];
            [encoder endEncoding];
            [commandBuffer commit];
            [commandBuffer waitUntilCompleted];
            if (commandBuffer.status == MTLCommandBufferStatusCompleted) {
                wins = (uint32_t *)winsBuffer.contents;
                uint64_t scoredRows = (uint64_t)wins[0] + wins[1] + wins[2] + wins[3] + wins[4];
                if (scoredRows == height) {
                    memset(histogram, 0, sizeof(*histogram));
                    histogram->row_count = (uint32_t)height;
                    histogram->wins[0] = wins[0];
                    histogram->wins[1] = wins[1];
                    histogram->wins[2] = wins[2];
                    histogram->wins[3] = wins[3];
                    histogram->wins[4] = wins[4];
                    if (usedMetal) {
                        *usedMetal = YES;
                    }
                    return YES;
                }
                IOWarn("Metal PNG filter scored %llu of %u rows", scoredRows, (unsigned)height);
            } else {
                IOWarn("Metal PNG filter pass failed: %@", commandBuffer.error);
            }
        }
    }

    return io_score_png_filters(bytes,
                                params.row_bytes,
                                params.row_stride,
                                params.height,
                                params.bytes_per_pixel,
                                (int)[[ProcessorBudget sharedBudget] heavyCoreBudget],
                                histogram) == 0;
}

+ (BOOL)recommendFastEvaluationForPNGAtURL:(NSURL *)url {
    NSBitmapImageRep *rep;
    io_filter_histogram histogram;
    BOOL usedMetal = NO;

    if (!url) {
        return NO;
    }
    rep = (NSBitmapImageRep *)[NSBitmapImageRep imageRepWithContentsOfURL:url];
    if (![rep isKindOfClass:[NSBitmapImageRep class]]) {
        return NO;
    }
    memset(&histogram, 0, sizeof(histogram));
    if (![self histogramForBitmap:rep histogram:&histogram usedMetal:&usedMetal]) {
        return NO;
    }
    if (io_filter_fast_path_ok(&histogram)) {
        IODebug("PNG filter fast path via %@ for %u rows",
                usedMetal ? @"Metal" : @"CPU",
                (unsigned)histogram.row_count);
        return YES;
    }
    return NO;
}

@end
