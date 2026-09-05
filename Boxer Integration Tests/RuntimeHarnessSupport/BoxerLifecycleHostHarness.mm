// Production-linked lifecycle harness.
//
// Real entry point: -[BXEmulator(BXEmulatorInternals) _startDOSBox] in
// Boxer/BXEmulator.mm. That method owns the real Config and invokes the real
// DOSBOX_Init, Config::Init, Config::StartUp, and Config destruction paths.
//
// Fakes: the BXEmulator delegate supplies an empty configuration list. Normal
// sessions use DOSBox's existing integer killswitch after real initialization.
// Video shutdown is observed by temporarily wrapping the production method.
// No cleanup implementation is copied into this harness.

#import <Cocoa/Cocoa.h>
#import <objc/runtime.h>

#import "BXEmulator.h"
#import "BXEmulatorPrivate.h"
#import "BXVideoHandler.h"
#import "callback.h"
#import "dos_inc.h"
#import "dosbox.h"
#import "shell.h"

@interface BoxerLifecycleDelegate : NSObject <BXEmulatorDelegate, BXEmulatorFileSystemDelegate, BXEmulatorAudioDelegate>
@end

@implementation BoxerLifecycleDelegate
- (NSSize)viewportSizeForEmulator:(BXEmulator *)emulator { return NSMakeSize(640, 480); }
- (NSSize)maxFrameSizeForEmulator:(BXEmulator *)emulator { return NSMakeSize(4096, 4096); }
- (NSArray<NSURL *> *)configurationURLsForEmulator:(BXEmulator *)emulator { return @[]; }
- (void)emulator:(BXEmulator *)emulator didFinishFrame:(BXVideoFrame *)frame {}
- (void)runPreflightCommandsForEmulator:(BXEmulator *)emulator {}
- (void)runLaunchCommandsForEmulator:(BXEmulator *)emulator {}
- (void)processEventsForEmulator:(BXEmulator *)emulator { [emulator cancel]; }
- (void)emulatorWillStartRunLoop:(BXEmulator *)emulator {}
- (void)emulatorDidFinishRunLoop:(BXEmulator *)emulator {}
- (BOOL)emulator:(BXEmulator *)emulator shouldShowFileWithName:(NSString *)name { return YES; }
- (BOOL)emulator:(BXEmulator *)emulator shouldMountDriveFromURL:(NSURL *)URL { return YES; }
- (BOOL)emulator:(BXEmulator *)emulator shouldAllowWriteAccessToURL:(NSURL *)URL onDrive:(BXDrive *)drive { return YES; }
- (FILE *)emulator:(BXEmulator *)emulator openCaptureFileOfType:(NSString *)type extension:(NSString *)extension { return NULL; }
- (id<BXMIDIDevice>)MIDIDeviceForEmulator:(BXEmulator *)emulator meetingDescription:(NSDictionary<NSString *, id> *)description { return nil; }
@end

enum class BoxerLifecycleFailure {
    none,
    characterPointer,
    emulatorException,
};

static NSInteger shutdownCount = 0;
static IMP originalShutdown = NULL;

static void recordingShutdown(id self, SEL selector)
{
    ++shutdownCount;
    ((void (*)(id, SEL))originalShutdown)(self, selector);
}

static BOOL pointerIvarIsNil(id object, const char *name)
{
    Ivar ivar = class_getInstanceVariable([object class], name);
    if (!ivar) return NO;
    const uint8_t *bytes = static_cast<const uint8_t *>((__bridge const void *)object);
    return *(void **)(bytes + ivar_getOffset(ivar)) == NULL;
}

static int retainedStateResult(BXEmulator *emulator)
{
    if (control) return 11;
    if (!pointerIvarIsNil(emulator, "configuration") ||
        !pointerIvarIsNil(emulator, "commandLine")) return 12;
    for (NSUInteger index = 0; index < DOS_DRIVES; ++index)
        if (Drives[index]) return 13;
    if (currentShell) return 14;
    return 0;
}

static int runLifecycle(BoxerLifecycleFailure failure, BOOL expectException)
{
    @autoreleasepool {
        BoxerLifecycleDelegate *delegate = [BoxerLifecycleDelegate new];
        BXEmulator *emulator = [BXEmulator new];
        emulator.delegate = delegate;
        __block BOOL reachedInitializedSubsystems = NO;

        emulator.startupPhaseCallback = ^(BXEmulatorStartupPhase phase) {
            if (phase != BXEmulatorStartupPhaseSubsystemsInitialized) return;
            reachedInitializedSubsystems = YES;
            if (failure == BoxerLifecycleFailure::characterPointer) {
                static char message[] = "injected lifecycle char-pointer failure";
                throw static_cast<char *>(message);
            }
            if (failure == BoxerLifecycleFailure::emulatorException)
                throw boxer_emulatorException("injected lifecycle emulator failure", __FILE__, __func__, __LINE__);
            throw 0;
        };

        const NSInteger shutdownBefore = shutdownCount;
        BOOL raised = NO;
        @try {
            [emulator _startDOSBox];
        } @catch (NSException *exception) {
            raised = YES;
        }
        emulator.startupPhaseCallback = nil;

        if (!reachedInitializedSubsystems) return 20;
        if (raised != expectException) return 21;
        if (shutdownCount - shutdownBefore != 1) return 22;
        return retainedStateResult(emulator);
    }
}

static int runProductionLifecycleHarnessOnCurrentThread(void)
{
    shutdownCount = 0;
    Method shutdownMethod = class_getInstanceMethod([BXVideoHandler class], @selector(shutdown));
    originalShutdown = method_setImplementation(shutdownMethod, (IMP)recordingShutdown);

    int result = 0;
    @try {
        // Two complete normal cycles establish baseline teardown and reuse.
        if ((result = runLifecycle(BoxerLifecycleFailure::none, NO))) goto finished;
        if ((result = runLifecycle(BoxerLifecycleFailure::none, NO))) goto finished;

        // Each production catch path must roll back enough state for another
        // complete initialization and normal shutdown to succeed.
        if ((result = runLifecycle(BoxerLifecycleFailure::characterPointer, YES))) goto finished;
        if ((result = runLifecycle(BoxerLifecycleFailure::none, NO))) goto finished;
        if ((result = runLifecycle(BoxerLifecycleFailure::emulatorException, YES))) goto finished;
        if ((result = runLifecycle(BoxerLifecycleFailure::none, NO))) goto finished;
    } @catch (NSException *exception) {
        result = 30;
    }

finished:
    method_setImplementation(shutdownMethod, originalShutdown);
    originalShutdown = NULL;
    return result;
}

@interface BoxerLifecycleHarnessRunner : NSObject
@property(atomic) BOOL finished;
@property(atomic) int result;
- (void)run;
@end

@implementation BoxerLifecycleHarnessRunner
- (void)run
{
    @autoreleasepool {
        self.result = runProductionLifecycleHarnessOnCurrentThread();
        self.finished = YES;
    }
}
@end

extern "C" int BoxerRunProductionLifecycleHarness(void)
{
    BoxerLifecycleHarnessRunner *runner = [BoxerLifecycleHarnessRunner new];
    [runner performSelectorInBackground:@selector(run) withObject:nil];

    // Real DOSBox initialization dispatches selected work to the host run loop.
    // Keep the XCTest thread pumping it, as the production application does.
    while (!runner.finished) {
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                 beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    }
    return runner.result;
}
