#import "ImageOptimController.h"
#import "FilesController.h"
#import "ProcessorBudget.h"
#import "RevealButtonCell.h"
#import "Backend/Job.h"
#import "JobProxy.h"
#import "File.h"
#import "Backend/Workers/Worker.h"
#import "PrefsController.h"
#import "MyTableView.h"
#import "SharedPrefs.h"
#include <mach/mach_host.h>
#include <mach/host_info.h>
#import <Quartz/Quartz.h>

#if __MAC_OS_X_VERSION_MAX_ALLOWED >= 260000
@interface ImageOptimController () <NSToolbarDelegate>
@end
#endif

static BOOL IOIsMacOS26(void) {
    return [[NSProcessInfo processInfo] isOperatingSystemAtLeastVersion:(NSOperatingSystemVersion){26, 0, 0}];
}

@implementation ImageOptimController

extern int quitWhenDone;

static const char *kIMPreviewPanelContext = "preview";

@synthesize filesController;

- (void)applicationWillFinishLaunching:(NSNotification *)unused {
    if (quitWhenDone) {
        [NSApp hide:self];
    }

    NSMutableDictionary *defs = [NSMutableDictionary dictionaryWithContentsOfFile:[[NSBundle mainBundle] pathForResource:@"defaults" ofType:@"plist"]];

    NSUInteger processorCount = [[NSProcessInfo processInfo] activeProcessorCount];
    BOOL lowPriority = [[NSUserDefaults standardUserDefaults] boolForKey:@"RunLowPriority"];
    NSUInteger maxTasks = (NSUInteger)[ProcessorBudget recommendedFileConcurrencyForLowPriority:lowPriority];
    if (maxTasks < 1) {
        maxTasks = processorCount;
    }

    defs[@"RunConcurrentFiles"] = @(maxTasks);
    defs[@"RunConcurrentDirscans"] = @((int)ceil((double)processorCount / 3.9));

    // Keep this tied to logical CPUs. Performance-core count on a base M-series
    // Mac is 4, and that machine should not take the old "slow Mac" tool defaults.
    if (processorCount <= 4) {
        defs[@"PngOutEnabled"] = @(NO);
        if (processorCount <= 2) {
            defs[@"PngCrush2Enabled"] = @(NO);
        }
    }

    NSUserDefaults *userDefaults = [NSUserDefaults standardUserDefaults];
    [userDefaults registerDefaults:defs];

    [self initStatusbarWithDefaults:userDefaults];
    [self adoptLiquidGlassIfNeeded];

    IOSharedPrefsCopy(userDefaults);

    [filesController configureWithTableView:tableView];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(observeNotification:) name:kJobQueueFinished object:filesController];

    NSArray *monospaceFontColumns = @[
        fileColumn,
        sizeColumn,
        originalSizeColumn,
        savingsColumn,
        bestToolColumn,
    ];
    for (NSTableColumn *column in monospaceFontColumns) {
        NSFont *font = [NSFont systemFontOfSize:13];
        if ([NSFont respondsToSelector:@selector(monospacedDigitSystemFontOfSize:weight:)]) {
            if (@available(macOS 10.11, *)) {
                font = [NSFont monospacedDigitSystemFontOfSize:13 weight:NSFontWeightRegular];
            } else {
                // Fallback on earlier versions
            }
        }
        [column.dataCell setFont:font];
    }

    [NSApp setServicesProvider:self];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self name:kJobQueueFinished object:filesController];
    [credits removeObserver:self forKeyPath:@"effectiveAppearance"];
}

- (void)handleServices:(NSPasteboard *)pboard
              userData:(NSString *)userData
                 error:(NSString **)error {
    NSArray *paths = [pboard propertyListForType:NSFilenamesPboardType];
    if (paths && [paths count] > 0) {
        [filesController performSelectorInBackground:@selector(addPaths:) withObject:paths];
        return;
    }

    NSURL *url = [pboard propertyListForType:NSPasteboardTypeFileURL];
    if (url) {
        NSArray *urls = @[url];
        [filesController performSelectorInBackground:@selector(addURLs:) withObject:urls];
    }
}

static void appendFormatNameIfLossyEnabled(NSUserDefaults *defs, NSString *name, NSString *key, NSMutableArray *arr) {
    NSInteger q = [defs integerForKey:key];
    if (q > 0 && q < 100) {
        [arr addObject:[NSString stringWithFormat:@"%@ %ld%%", name, q]];
    }
}

- (void)initStatusbarWithDefaults:(NSUserDefaults *)defs {
    // Raised drawing was for the textured bottom bar. On Liquid Glass the label sits on the window background.
    NSBackgroundStyle backgroundStyle = IOIsMacOS26() ? NSBackgroundStyleNormal : NSBackgroundStyleRaised;
    [[statusBarLabel cell] setBackgroundStyle:backgroundStyle];

    static BOOL overallAvg = NO;
    static NSString *defaultText;
    defaultText = statusBarLabel.stringValue;
    NSByteCountFormatter *sizeFormatter = [[NSByteCountFormatter alloc] init];

    static NSNumberFormatter *percFormatter;
    percFormatter = [NSNumberFormatter new];

    if (quitWhenDone) {
        defaultText = NSLocalizedString(@"ImageOptim will quit when optimizations are complete", @"status bar");
    }

    [percFormatter setMaximumFractionDigits:1];
    [percFormatter setNumberStyle:NSNumberFormatterPercentStyle];

    statusBarUpdateQueue = dispatch_source_create(DISPATCH_SOURCE_TYPE_DATA_OR, 0, 0,
                                                  dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0));
    dispatch_source_set_event_handler(statusBarUpdateQueue, ^{
        NSString *str = defaultText;
        BOOL selectable = NO;
        @synchronized(self->filesController) {
            long long bytesTotal = 0, optimizedTotal = 0;
            double optimizedFractionTotal = 0, maxOptimizedFraction = 0;
            NSUInteger optimizedFileCount = 0;
            BOOL anyBusyFiles = false;

            NSArray *content = [self->filesController content];
            for (JobProxy *f in content) {
                assert([f isKindOfClass:[JobProxy class]]);

                if (!anyBusyFiles && [f isBusy]) {
                    anyBusyFiles = YES;
                }

                const NSUInteger bytes = [f.byteSizeOriginal unsignedIntegerValue];
                const NSUInteger optimized = [f.byteSizeOptimized unsignedIntegerValue];
                if (bytes && optimized && (bytes != optimized || [f isDone])) {
                    const double optimizedFraction = 1.0 - (double)optimized / (double)bytes;
                    if (optimizedFraction > maxOptimizedFraction) {
                        maxOptimizedFraction = optimizedFraction;
                    }
                    optimizedFractionTotal += optimizedFraction;
                    bytesTotal += bytes;
                    optimizedTotal += optimized;
                    optimizedFileCount++;
                }
            }

            if (optimizedFileCount > 1 && bytesTotal) {
                const double savedTotal = 1.0 - (double)optimizedTotal / (double)bytesTotal;
                const double savedAvg = optimizedFractionTotal / (double)optimizedFileCount;
                if (savedTotal > 0.001) {
                    if (savedTotal * 0.8 > savedAvg) {
                        overallAvg = YES;
                    } else if (savedAvg * 0.8 > savedTotal) {
                        overallAvg = NO;
                    }

                    NSString *fmtStr;
                    double avgNum;
                    if (overallAvg) {
                        fmtStr = NSLocalizedString(@"Saved %@ out of %@. %@ overall (up to %@ per file)", "total ratio, status bar");
                        avgNum = savedTotal;
                    } else {
                        fmtStr = NSLocalizedString(@"Saved %@ out of %@. %@ per file on average (up to %@)", "per file avg, status bar");
                        avgNum = savedAvg;
                    }

                    const long long bytesSaved = bytesTotal - optimizedTotal;

                    str = [NSString stringWithFormat:fmtStr,
                                                     [sizeFormatter stringFromByteCount:bytesSaved],
                                                     [sizeFormatter stringFromByteCount:bytesTotal],
                                                     [percFormatter stringFromNumber:@(avgNum)],
                                                     [percFormatter stringFromNumber:@(maxOptimizedFraction)]];
                    selectable = YES;
                }
            } else if ([defs boolForKey:@"GuetzliEnabled"]) {
                str = @"Warning: Guetzli tool enabled. Optimizations may take a very long time.";
            } else if ([defs boolForKey:@"LossyEnabled"]) {
                NSMutableArray *arr = [NSMutableArray new];
                appendFormatNameIfLossyEnabled(defs, @"JPEG", @"JpegOptimMaxQuality", arr);
                appendFormatNameIfLossyEnabled(defs, @"PNG", @"PngMinQuality", arr);
                appendFormatNameIfLossyEnabled(defs, @"GIF", @"GifQuality", arr);
                if ([arr count]) {
                    str = [NSString stringWithFormat:@"%@ (%@)",
                                                     NSLocalizedString(@"Lossy minification enabled", @"status bar"),
                                                     [arr componentsJoinedByString:@", "]];
                }
            } else if (anyBusyFiles) {
                str = @"";
            }

            // that was also in KVO, but caused deadlocks there. Here it's deferred.
            [self->filesController updateStoppableState];
        }

        dispatch_async(dispatch_get_main_queue(), ^() {
            [self->statusBarLabel setStringValue:str];
            [self->statusBarLabel setSelectable:selectable];
            [self->tableView.window.toolbar validateVisibleItems];
        });
        usleep(100000); // 1/10th of a sec to avoid updating statusbar as fast as possible (100% cpu on the statusbar alone is ridiculous)
    });
    dispatch_resume(statusBarUpdateQueue);

    [filesController addObserver:self forKeyPath:@"isBusy" options:0 context:nil];
    [filesController addObserver:self forKeyPath:@"arrangedObjects.@count" options:0 context:nil];
    [filesController addObserver:self forKeyPath:@"arrangedObjects.@sum.byteSizeOptimized" options:0 context:nil];
    [filesController addObserver:self forKeyPath:@"selectionIndexes" options:0 context:(void *)kIMPreviewPanelContext];

    [self updateStatusBar]; // Initial display

    [[NSNotificationCenter defaultCenter] addObserverForName:NSUserDefaultsDidChangeNotification
                                                      object:defs
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification *note) {
                                                      [self updateStatusBar];
                                                  }];
}

- (void)updateStatusBar {
    dispatch_source_merge_data(statusBarUpdateQueue, 1);
}

- (void)awakeFromNib {
    if (quitWhenDone) {
        [NSApp hide:self];
    }

    RevealButtonCell *cell = [[tableView tableColumnWithIdentifier:@"filename"] dataCell];
    [cell setInfoButtonAction:@selector(openInFinder:)];
    [cell setTarget:tableView];

    [credits setString:@""];

    // this creates and sets the text for textview
    [self performSelectorInBackground:@selector(loadCreditsHTML:) withObject:nil];
    [credits addObserver:self forKeyPath:@"effectiveAppearance" options:0 context:nil];
#if __MAC_OS_X_VERSION_MAX_ALLOWED >= 260000
    if (@available(macOS 26.0, *)) {
        [self adoptLiquidGlassWindow];
    }
#endif
}

- (void)loadCreditsHTML:(id)_unused {
    static const char header[] = "<!DOCTYPE html>\
    <meta charset=utf-8>\
    <style>\
    html,body {font:11px/1.5 'Lucida Grande', sans-serif; color: #000; background: transparent; margin:0;}\
    </style>\
    <title>Credits</title>";

    NSMutableData *html = [NSMutableData dataWithBytesNoCopy:(void *)header length:sizeof(header) freeWhenDone:NO];
    NSString*creditsPath = [[NSBundle mainBundle] pathForResource:@"Credits" ofType:@"html"];
    NSData *credits = [NSData dataWithContentsOfFile:creditsPath];
    if (!credits) {
        return;
    }
    [html appendData:credits];
    NSAttributedString *tmpStr = [[NSAttributedString alloc]
              initWithHTML:html
        documentAttributes:nil];

    if (!tmpStr) return;
    dispatch_async(dispatch_get_main_queue(), ^() {
        @try {
            [self->credits setEditable:YES];
            [self->credits insertText:tmpStr replacementRange:NSMakeRange(0, 0)];
            [self->credits setEditable:NO];
            [self adaptCreditsAppearance];
        } @catch (id) { /*nothing*/
        }
    });
}

- (BOOL)isDarkMode {
#if __MAC_OS_X_VERSION_MAX_ALLOWED >= 101400
    if (@available(macOS 10.14, *)) {
        NSAppearanceName bestAppearance = [credits.effectiveAppearance bestMatchFromAppearancesWithNames:@[ NSAppearanceNameAqua, NSAppearanceNameDarkAqua ]];
        return [bestAppearance isEqualToString:NSAppearanceNameDarkAqua];
    }
#endif
    return false;
}

- (void)adaptCreditsAppearance {
    credits.textColor = [self isDarkMode] ? [NSColor whiteColor] : [NSColor blackColor];
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    // Defer and coalesce statusbar updates
    dispatch_source_merge_data(statusBarUpdateQueue, 1);

    if (object == credits && [keyPath isEqualToString:@"effectiveAppearance"]) {
        [self adaptCreditsAppearance];
    }

    if (context == kIMPreviewPanelContext) {
        [previewPanel reloadData];
    }
}

- (void)observeNotification:(NSNotification *)notif {
    if (!filesController.isBusy) {
        if (quitWhenDone) {
            [NSApp terminate:self];
        } else if ([[NSUserDefaults standardUserDefaults] boolForKey:@"BounceDock"]) {
            [NSApp requestUserAttention:NSInformationalRequest];
        }
    }
}

// invoked by Dock
- (void)application:(NSApplication *)sender openFiles:(NSArray *)paths {
    [filesController setRow:-1];
    [sender replyToOpenOrPrint:[filesController addPaths:paths] ? NSApplicationDelegateReplySuccess : NSApplicationDelegateReplyFailure];
}

- (IBAction)quickLookAction:(id)sender {
    [tableView performSelector:@selector(quickLook)];
}

- (IBAction)revert:(id)sender {
    [filesController revert];
}

- (IBAction)stop:(id)sender {
    [filesController stopSelected];
}

- (IBAction)startAgain:(id)sender {
    // alt-click on a button (this is used from menu too, but alternative menu item covers that anyway
    BOOL onlyOptimized = !!([[NSApp currentEvent] modifierFlags] & NSEventModifierFlagOption);
    [filesController startAgainOptimized:onlyOptimized];
}

- (IBAction)startAgainOptimized:(id)sender {
    [filesController startAgainOptimized:YES];
}

- (IBAction)clearComplete:(id)sender {
    [filesController clearComplete];
}

- (IBAction)showPrefs:(id)sender {
    if (!prefsController) {
        prefsController = [PrefsController new];
    }
    [prefsController showWindow:self];
}

- (IBAction)showLossyPrefs:(id)sender {
    if (!prefsController) {
        prefsController = [PrefsController new];
    }
    [prefsController showLossySettings:sender];
}

- (IBAction)openApiHomepage:(id)sender {
    [self openURL:@"https://imageoptim.com/app-api"];
}

- (IBAction)openHomepage:(id)sender {
    [self openURL:@"https://imageoptim.com"];
}

- (IBAction)viewSource:(id)sender {
    [self openURL:@"https://imageoptim.com/source"];
}

- (IBAction)openDonationPage:(id)sender {
    [self openURL:@"https://imageoptim.com/donate.html"];
}

- (void)openURL:(NSString *)stringURL {
    [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:stringURL]];
}

- (IBAction)browseForFiles:(id)sender {
    NSOpenPanel *oPanel = [NSOpenPanel openPanel];

    [oPanel setAllowsMultipleSelection:YES];
    [oPanel setCanChooseDirectories:YES];
    [oPanel setResolvesAliases:YES];
    [oPanel setAllowedFileTypes:[filesController fileTypes]];

    [oPanel beginSheetModalForWindow:[tableView window]
                   completionHandler:^(NSInteger returnCode) {
                       if (returnCode == NSModalResponseOK) {
                           NSWindow *myWindow = [self->tableView window];
                           [myWindow setStyleMask:[myWindow styleMask] | NSWindowStyleMaskResizable];
                           [self->filesController setRow:-1];
                           [self->filesController addURLs:oPanel.URLs];
                       }
                   }];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)theApplication {
    return YES;
}

- (void)applicationWillTerminate:(NSNotification *)n {
    [filesController cleanup];
}

- (NSString *)version {
    return [[NSBundle mainBundle] infoDictionary][@"CFBundleShortVersionString"];
}

// Quick Look panel support
- (BOOL)acceptsPreviewPanelControl:(QLPreviewPanel *)panel;
{
    return YES;
}

- (void)beginPreviewPanelControl:(QLPreviewPanel *)panel {
    // This document is now responsible of the preview panel
    // It is allowed to set the delegate, data source and refresh panel.
    previewPanel = panel;
    panel.delegate = self;
    panel.dataSource = self;
}

- (void)endPreviewPanelControl:(QLPreviewPanel *)panel {
    // This document loses its responsisibility on the preview panel
    // Until the next call to -beginPreviewPanelControl: it must not
    // change the panel's delegate, data source or refresh it.
    previewPanel = nil;
}

// Quick Look panel data source
- (NSInteger)numberOfPreviewItemsInPreviewPanel:(QLPreviewPanel *)panel {
    return [[filesController selectedObjects] count];
}

- (id<QLPreviewItem>)previewPanel:(QLPreviewPanel *)panel previewItemAtIndex:(NSInteger)index {
    return [filesController selectedObjects][index];
}

// Quick Look panel delegate
- (BOOL)previewPanel:(QLPreviewPanel *)panel handleEvent:(NSEvent *)event {
    // redirect all key down events to the table view
    if ([event type] == NSEventTypeKeyDown) {
        [tableView keyDown:event];
        return YES;
    }
    return NO;
}

- (BOOL)validateMenuItem:(NSMenuItem *)menuItem {
    SEL action = [menuItem action];
    if (action == @selector(startAgain:)) {
        return [filesController canStartAgainOptimized:NO];
    } else if (action == @selector(startAgainOptimized:)) {
        return [filesController canStartAgainOptimized:YES];
    } else if (action == @selector(clearComplete:)) {
        return [filesController canClearComplete];
    } else if (action == @selector(revert:)) {
        return [filesController canRevert];
    } else if (action == @selector(stop:)) {
        return [filesController isStoppable];
    }

    return [menuItem isEnabled];
}

// This delegate method provides the rect on screen from which the panel will zoom.
- (NSRect)previewPanel:(QLPreviewPanel *)panel sourceFrameOnScreenForPreviewItem:(id<QLPreviewItem>)item {
    NSInteger index = [[filesController arrangedObjects] indexOfObject:item];
    if (index == NSNotFound) {
        return NSZeroRect;
    }

    NSRect iconRect = [tableView frameOfCellAtColumn:0 row:index];

    // check that the icon rect is visible on screen
    NSRect visibleRect = [tableView visibleRect];

    if (!NSIntersectsRect(visibleRect, iconRect)) {
        return NSZeroRect;
    }

    // convert icon rect to screen coordinates
    iconRect.origin = [tableView convertPoint:iconRect.origin toView:nil];
    iconRect = [tableView.window convertRectToScreen:iconRect];

    return iconRect;
}

#pragma mark Liquid Glass

// Adopting Liquid Glass: https://developer.apple.com/documentation/TechnologyOverviews/adopting-liquid-glass
// macOS 26 moves navigation into the system toolbar and drops the legacy vibrancy plate.
// The nib's bottom bar stays in place on older systems.

- (void)adoptLiquidGlassIfNeeded {
    [self adoptLiquidGlassMenuIcons];
#if __MAC_OS_X_VERSION_MAX_ALLOWED >= 260000
    if (@available(macOS 26.0, *)) {
        [self adoptLiquidGlassWindow];
    }
#endif
}

- (void)adoptLiquidGlassMenuIcons {
    if (!IOIsMacOS26()) {
        return;
    }
    static BOOL applied = NO;
    if (applied || [NSApp mainMenu] == nil) {
        return;
    }
    if (@available(macOS 11.0, *)) {
        NSDictionary<NSString *, NSString *> *symbols = @{
            NSStringFromSelector(@selector(browseForFiles:)) : @"plus",
            NSStringFromSelector(@selector(startAgain:)) : @"arrow.clockwise",
            NSStringFromSelector(@selector(startAgainOptimized:)) : @"arrow.clockwise",
            NSStringFromSelector(@selector(stop:)) : @"stop.circle",
            NSStringFromSelector(@selector(revert:)) : @"arrow.uturn.backward",
            NSStringFromSelector(@selector(quickLookAction:)) : @"eye",
            NSStringFromSelector(@selector(openInFinder:)) : @"folder",
            NSStringFromSelector(@selector(showPrefs:)) : @"gearshape",
            NSStringFromSelector(@selector(clearComplete:)) : @"trash",
            NSStringFromSelector(@selector(copyAsDataURI:)) : @"link",
        };
        [self applyLiquidGlassIconsInMenu:[NSApp mainMenu] symbols:symbols];
        if (tableView.menu) {
            [self applyLiquidGlassIconsInMenu:tableView.menu symbols:symbols];
        }
        applied = YES;
    }
}

- (void)applyLiquidGlassIconsInMenu:(NSMenu *)menu symbols:(NSDictionary<NSString *, NSString *> *)symbols {
    if (@available(macOS 11.0, *)) {
        for (NSMenuItem *item in menu.itemArray) {
            if (item.submenu) {
                [self applyLiquidGlassIconsInMenu:item.submenu symbols:symbols];
            }
            if ([item isSeparatorItem] || item.image != nil || item.action == NULL) {
                continue;
            }
            NSString *symbol = symbols[NSStringFromSelector(item.action)];
            if (!symbol) {
                continue;
            }
            NSImage *image = [NSImage imageWithSystemSymbolName:symbol accessibilityDescription:item.title];
            if (image) {
                item.image = image;
            }
        }
    }
}

- (BOOL)validateToolbarItem:(NSToolbarItem *)item {
    if (item.action == @selector(startAgain:)) {
        return [filesController canStartAgainOptimized:NO];
    }
    return YES;
}

#if __MAC_OS_X_VERSION_MAX_ALLOWED >= 260000

static NSString *const IOToolbarAddIdentifier = @"ImageOptim.add";
static NSString *const IOToolbarAgainIdentifier = @"ImageOptim.again";
static NSString *const IOToolbarSettingsIdentifier = @"ImageOptim.settings";

- (void)adoptLiquidGlassWindow API_AVAILABLE(macos(26.0)) {
    static BOOL applied = NO;
    NSWindow *window = tableView.window;
    if (applied || !window) {
        return;
    }

    NSView *content = window.contentView;
    NSScrollView *scroll = tableView.enclosingScrollView;
    NSButton *addButton = [self buttonWithAction:@selector(browseForFiles:) inView:content];
    NSButton *againButton = [self buttonWithAction:@selector(startAgain:) inView:content];
    NSButton *settingsButton = [self buttonWithAction:@selector(showLossyPrefs:) inView:content];
    NSProgressIndicator *progress = nil;
    for (NSView *subview in content.subviews) {
        if ([subview isKindOfClass:[NSProgressIndicator class]]) {
            progress = (NSProgressIndicator *)subview;
            break;
        }
    }
    if (!content || !scroll || !statusBarLabel || !addButton || !againButton || !settingsButton || !progress) {
        return;
    }
    applied = YES;

    NSMutableSet *legacyButtons = [NSMutableSet set];
    [legacyButtons addObject:addButton];
    [legacyButtons addObject:againButton];
    [legacyButtons addObject:settingsButton];
    [self deactivateConstraintsInView:content referencingViews:legacyButtons];
    for (NSButton *button in legacyButtons) {
        [self retireLegacyBarButton:button];
    }

    for (NSLayoutConstraint *constraint in [content.constraints copy]) {
        BOOL pinsScrollToBottom = (constraint.firstItem == content && constraint.firstAttribute == NSLayoutAttributeBottom &&
                                    constraint.secondItem == scroll && constraint.secondAttribute == NSLayoutAttributeBottom);
        BOOL pinsScrollToTop = (constraint.firstItem == scroll && constraint.firstAttribute == NSLayoutAttributeTop &&
                                 constraint.secondItem == content && constraint.secondAttribute == NSLayoutAttributeTop);
        if (pinsScrollToBottom) {
            constraint.active = NO;
        } else if (pinsScrollToTop) {
            constraint.constant = 0;
        }
    }

    [self clearLegacyVisualEffectInView:content];

    NSViewLayoutRegion *region = [NSViewLayoutRegion safeAreaLayoutRegionWithCornerAdaptation:NSViewLayoutRegionAdaptivityAxisHorizontal];
    NSLayoutGuide *corners = [content layoutGuideForLayoutRegion:region] ?: content.safeAreaLayoutGuide;
    NSMutableArray<NSLayoutConstraint *> *installed = [NSMutableArray array];
    [installed addObject:[statusBarLabel.leadingAnchor constraintEqualToAnchor:corners.leadingAnchor]];
    [installed addObject:[statusBarLabel.bottomAnchor constraintEqualToAnchor:corners.bottomAnchor constant:-8]];
    [installed addObject:[scroll.bottomAnchor constraintEqualToAnchor:statusBarLabel.topAnchor constant:-8]];
    if (progress) {
        [installed addObject:[progress.centerYAnchor constraintEqualToAnchor:statusBarLabel.centerYAnchor]];
        [installed addObject:[progress.trailingAnchor constraintEqualToAnchor:corners.trailingAnchor]];
        if (![self view:progress hasConstraintToView:statusBarLabel inView:content]) {
            [installed addObject:[progress.leadingAnchor constraintGreaterThanOrEqualToAnchor:statusBarLabel.trailingAnchor constant:8]];
        }
    }
    [NSLayoutConstraint activateConstraints:installed];

    scroll.automaticallyAdjustsContentInsets = YES;
    [window setContentBorderThickness:0 forEdge:NSMinYEdge];
    window.styleMask |= NSWindowStyleMaskFullSizeContentView;
    window.toolbarStyle = NSWindowToolbarStyleUnified;
    window.titlebarSeparatorStyle = NSTitlebarSeparatorStyleNone;

    NSToolbar *toolbar = [[NSToolbar alloc] initWithIdentifier:@"ImageOptimMain"];
    toolbar.delegate = self;
    toolbar.allowsUserCustomization = NO;
    toolbar.autosavesConfiguration = NO;
    toolbar.displayMode = NSToolbarDisplayModeIconOnly;
    window.toolbar = toolbar;

    if (window.minSize.height < 200) {
        window.minSize = NSMakeSize(MAX(window.minSize.width, 411), 200);
    }
}

- (NSButton *)buttonWithAction:(SEL)action inView:(NSView *)view {
    for (NSView *subview in view.subviews) {
        if ([subview isKindOfClass:[NSButton class]] && [(NSButton *)subview action] == action) {
            return (NSButton *)subview;
        }
    }
    return nil;
}

- (void)deactivateConstraintsInView:(NSView *)container referencingViews:(NSSet *)views {
    if ([views count] == 0) {
        return;
    }
    NSMutableArray *matched = [NSMutableArray array];
    for (NSLayoutConstraint *constraint in container.constraints) {
        if ([views containsObject:constraint.firstItem] || [views containsObject:constraint.secondItem]) {
            [matched addObject:constraint];
        }
    }
    [NSLayoutConstraint deactivateConstraints:matched];
}

- (BOOL)view:(NSView *)first hasConstraintToView:(NSView *)second inView:(NSView *)container {
    for (NSLayoutConstraint *constraint in container.constraints) {
        BOOL links = (constraint.firstItem == first && constraint.secondItem == second) ||
                     (constraint.firstItem == second && constraint.secondItem == first);
        if (links) {
            return YES;
        }
    }
    return NO;
}

- (void)retireLegacyBarButton:(NSButton *)button {
    if ([button infoForBinding:NSEnabledBinding]) {
        [button unbind:NSEnabledBinding];
    }
    if ([button infoForBinding:NSHiddenBinding]) {
        [button unbind:NSHiddenBinding];
    }
    [button removeFromSuperview];
}

- (void)clearLegacyVisualEffectInView:(NSView *)view {
    if ([view isKindOfClass:[NSVisualEffectView class]]) {
        NSVisualEffectView *effect = (NSVisualEffectView *)view;
        // appearanceBased / vibrant plates sit on top of the system material and hide Liquid Glass.
        effect.appearance = nil;
        effect.state = NSVisualEffectStateInactive;
    }
    for (NSView *subview in view.subviews) {
        [self clearLegacyVisualEffectInView:subview];
    }
}

- (NSToolbarItem *)toolbar:(NSToolbar *)toolbar itemForItemIdentifier:(NSToolbarItemIdentifier)itemIdentifier willBeInsertedIntoToolbar:(BOOL)flag {
    (void)toolbar;
    (void)flag;
    if ([itemIdentifier isEqualToString:NSToolbarFlexibleSpaceItemIdentifier] ||
        [itemIdentifier isEqualToString:NSToolbarSpaceItemIdentifier]) {
        return [[NSToolbarItem alloc] initWithItemIdentifier:itemIdentifier];
    }

    NSString *label = nil;
    NSString *toolTip = nil;
    NSString *symbol = nil;
    NSString *fallback = nil;
    SEL action = NULL;
    BOOL prominent = NO;

    if ([itemIdentifier isEqualToString:IOToolbarAddIdentifier]) {
        label = NSLocalizedString(@"Add", @"toolbar item");
        toolTip = NSLocalizedString(@"Add new files or directories", @"toolbar item");
        symbol = @"plus";
        fallback = NSImageNameAddTemplate;
        action = @selector(browseForFiles:);
        prominent = YES;
    } else if ([itemIdentifier isEqualToString:IOToolbarAgainIdentifier]) {
        label = NSLocalizedString(@"Optimize Again", @"toolbar item");
        toolTip = NSLocalizedString(@"Run optimizations again", @"toolbar item");
        symbol = @"arrow.clockwise";
        fallback = NSImageNameRefreshTemplate;
        action = @selector(startAgain:);
    } else if ([itemIdentifier isEqualToString:IOToolbarSettingsIdentifier]) {
        label = NSLocalizedString(@"Settings", @"toolbar item");
        toolTip = NSLocalizedString(@"Show settings", @"toolbar item");
        symbol = @"gearshape";
        fallback = NSImageNameActionTemplate;
        action = @selector(showLossyPrefs:);
    } else {
        return nil;
    }

    NSToolbarItem *item = [[NSToolbarItem alloc] initWithItemIdentifier:itemIdentifier];
    item.label = label;
    item.paletteLabel = label;
    item.toolTip = toolTip;
    item.accessibilityLabel = toolTip;
    item.target = self;
    item.action = action;
    item.bordered = YES;
    if (@available(macOS 26.0, *)) {
        item.style = prominent ? NSToolbarItemStyleProminent : NSToolbarItemStylePlain;
    }
    NSImage *image = nil;
    if (@available(macOS 11.0, *)) {
        image = [NSImage imageWithSystemSymbolName:symbol accessibilityDescription:toolTip];
    }
    if (!image) {
        image = [NSImage imageNamed:fallback];
    }
    item.image = image;
    return item;
}

- (NSArray<NSToolbarItemIdentifier> *)toolbarDefaultItemIdentifiers:(NSToolbar *)toolbar {
    return @[
        IOToolbarAddIdentifier,
        NSToolbarFlexibleSpaceItemIdentifier,
        IOToolbarAgainIdentifier,
        IOToolbarSettingsIdentifier,
    ];
}

- (NSArray<NSToolbarItemIdentifier> *)toolbarAllowedItemIdentifiers:(NSToolbar *)toolbar {
    return [self toolbarDefaultItemIdentifiers:toolbar];
}

#endif

@end
