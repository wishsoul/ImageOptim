//
//  AdvCompWorker.m
//
//  Created by porneL on 30.wrz.07.
//

#import "OxiPngWorker.h"
#import "../Job.h"
#import "../TempFile.h"
#import "../File.h"
#import "../PngFilterAccelerator.h"

@implementation OxiPngWorker

- (instancetype)initWithLevel:(NSInteger)level stripMetadata:(BOOL)aStrip file:(Job *)aJob {
    if (self = [super initWithFile:aJob]) {
        optlevel = MAX(2, MIN(level, 6));
        strip = aStrip;
    }
    return self;
}


-(NSInteger)settingsIdentifier {
    return 2*(optlevel*2 + strip);
}

-(BOOL)optimizeFile:(File *)file toTempPath:(NSURL *)temp {
    NSMutableArray *args = [NSMutableArray arrayWithObjects: [NSString stringWithFormat:@"-o%d",(int)(optlevel ? optlevel : 6)],
                            @"-i0", @"-a",
                            @"--out",temp.path,@"--",file.path,nil];
    if (strip) {
        [args insertObject:@"--strip=safe" atIndex:0];
    }

    // Levels 3 and 4 turn off oxipng's fast filter evaluation and spend the
    // time on a wide search. When one PNG filter already dominates a large
    // image, that search rarely changes the winner, so use --fast.
    if ((optlevel == 3 || optlevel == 4) && [file isLarge] && file.byteSize <= 32u * 1024u * 1024u) {
        if ([PngFilterAccelerator recommendFastEvaluationForPNGAtURL:file.path]) {
            [args insertObject:@"--fast" atIndex:0];
        }
    }

    // Lease after the filter scan so the count includes files that arrived
    // while this image was being decoded.
    NSInteger threads = [self parallelJobThreads];
    [args insertObject:[NSString stringWithFormat:@"%d", (int)threads] atIndex:0];
    [args insertObject:@"-t" atIndex:0];

    if (![self taskForKey:@"OptiPng" bundleName:@"oxipng" arguments:args]) {
        return NO;
    }

    NSFileHandle *devnull = [NSFileHandle fileHandleWithNullDevice];

    [task setStandardInput:devnull];
    [task setStandardError:devnull];
    [task setStandardOutput:devnull];

    [self launchTask];

    BOOL ok = [self waitUntilTaskExit];

    if (!ok) return NO;

    return [job setFileOptimized:[file tempCopyOfPath:temp] toolName:@"OxiPNG"];
}

@end
