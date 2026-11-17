//
//  BackendTests.m
//  BackendTests
//
//  Created by Kornel on 20/04/2015.
//
//

@import Cocoa;
#import <XCTest/XCTest.h>
#import "Job.h"
#import "JobQueue.h"
#import "processor_budget.h"
#import "PngFilterScore.h"

@interface BackendTests : XCTestCase

@end

@implementation BackendTests

- (void)setUp {
    [super setUp];
    // Put setup code here. This method is called before the invocation of each test method in the class.
}

- (void)tearDown {
    // Put teardown code here. This method is called after the invocation of each test method in the class.
    [super tearDown];
}

- (void)testCompressOne {
    NSURL *origPath = [[NSBundle bundleForClass:[self class]] URLForResource:@"unoptimized" withExtension:@"png"];
    NSURL *path = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:[[NSUUID UUID] UUIDString]]];

    NSFileManager *fm = [NSFileManager defaultManager];
    XCTAssertTrue([fm copyItemAtURL:origPath toURL:path error:nil]);

    Job *f = [[Job alloc] initWithFilePath:path resultsDatabase:nil];
    JobQueue *q = [[JobQueue alloc] initWithCPUs:4
                                            dirs:1
                                           files:4
                                        defaults:[NSUserDefaults standardUserDefaults]];

    [q addJob:f];
    XCTAssertTrue([f isBusy]);
    XCTAssertFalse([f isDone]);
    XCTAssertFalse([f isFailed]);
    [q wait];
    XCTAssertFalse([f isBusy]);

    NSNumber *size, *origSize;
    [path removeAllCachedResourceValues];
    [origPath removeAllCachedResourceValues];

    XCTAssertTrue([path getResourceValue:&size forKey:NSURLFileSizeKey error:nil]);
    XCTAssertTrue([origPath getResourceValue:&origSize forKey:NSURLFileSizeKey error:nil]);

    XCTAssertTrue([f isDone]);
    XCTAssertFalse([f isFailed]);
    XCTAssertFalse([f isStoppable]);

    XCTAssertLessThan(1, 2);
    XCTAssertLessThan([size integerValue], [origSize integerValue]);
    XCTAssertLessThanOrEqual(1, 2);
    XCTAssertLessThanOrEqual([size integerValue], 5552);

    XCTAssertTrue([f canRevert]);

    XCTAssertEqual([[f byteSizeOptimized] integerValue], [size integerValue]);
    XCTAssertEqual([[f byteSizeOriginal] integerValue], [origSize integerValue]);
}

- (void)testThreadBudgetMatchesCoreTopology {
    io_cpu_topology apple;
    io_cpu_topology intel;

    apple.performance_cores = 8;
    apple.efficiency_cores = 2;
    apple.logical_cpus = 10;
    XCTAssertEqual(io_recommend_queue_width(&apple, 0), 8);
    XCTAssertEqual(io_recommend_queue_width(&apple, 1), 2);
    XCTAssertEqual(io_heavy_core_budget(&apple, 0), 8);

    intel.performance_cores = 0;
    intel.efficiency_cores = 0;
    intel.logical_cpus = 8;
    XCTAssertEqual(io_recommend_queue_width(&intel, 0), 8);
    XCTAssertEqual(io_threads_for_worker(8, 8, 8), 1);
    XCTAssertEqual(io_threads_for_worker(8, 8, 1), 8);
    XCTAssertEqual(io_threads_for_worker(8, 8, 3), 3);

    io_cpu_topology current;
    io_cpu_topology_current(&current);
    XCTAssertGreaterThanOrEqual(current.logical_cpus, 1);
}

- (void)testPngFilterScoreIsStableAcrossThreads {
    uint8_t rows[3][3] = {
        {5, 5, 5},
        {6, 6, 6},
        {7, 7, 7},
    };
    io_filter_histogram histogram;
    XCTAssertEqual(io_score_png_filters(&rows[0][0], 3, 3, 3, 1, 1, &histogram), 0);
    XCTAssertEqual(histogram.wins[1], 1u);
    XCTAssertEqual(histogram.wins[4], 2u);
    XCTAssertFalse(io_filter_fast_path_ok(&histogram));

    const uint32_t width = 8;
    const uint32_t height = 128;
    uint8_t *pixels = calloc(height * width, 1);
    XCTAssertNotEqual(pixels, NULL);
    for (uint32_t y = 0; y < height; y++) {
        for (uint32_t x = 0; x < width; x++) {
            pixels[y * width + x] = (uint8_t)(y + 1);
        }
    }
    io_filter_histogram serial;
    io_filter_histogram parallel;
    XCTAssertEqual(io_score_png_filters(pixels, width, width, height, 1, 1, &serial), 0);
    XCTAssertEqual(io_score_png_filters(pixels, width, width, height, 1, 5, &parallel), 0);
    for (int filter = 0; filter < 5; filter++) {
        XCTAssertEqual(serial.wins[filter], parallel.wins[filter]);
    }
    XCTAssertGreaterThanOrEqual(parallel.wins[4], 120u);
    XCTAssertTrue(io_filter_fast_path_ok(&parallel));
    free(pixels);
}

@end
