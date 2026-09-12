/* 
 Copyright (c) 2013 Alun Bestor and contributors. All rights reserved.
 This source file is released under the GNU General Public License 2.0. A full copy of this license
 can be found in this XCode project at Resources/English.lproj/BoxerHelp/pages/legalese.html, or read
 online at [http://www.gnu.org/licenses/gpl-2.0.txt].
 */

#import <AppKit/AppKit.h> //For NSApp
#import <Carbon/Carbon.h> //For keycodes
#import <IOKit/hidsystem/ev_keymap.h> //For media key codes

#import "BXKeyboardEventTap.h"
#import "ADBContinuousThread.h"


@interface BXKeyboardEventTap ()

/// The dedicated thread on which our tap runs. Only used if @c usesDedicatedThread is YES.
@property (strong) ADBContinuousThread *tapThread;

//Overridden to be read-write.
@property (readwrite) BXKeyboardEventTapStatus status;
@property (readwrite) BOOL restartNeeded;

///Our CGEventTap callback. Receives the BXKeyboardEventTap instance as the userInfo parameter, and passes handling directly on to it.
static CGEventRef _handleEventFromTap(CGEventTapProxy proxy, CGEventType type, CGEventRef event, void *userInfo);

/// Receives keyboard and system events and asks our delegate whether to let them go through
/// or swallow them whole.
- (CGEventRef) _handleEvent: (CGEventRef)event
                     ofType: (CGEventType)type
                  fromProxy: (CGEventTapProxy)proxy;

/// Creates an event tap, and starts up a dedicated thread to monitor it (if @c usesDedicatedThread is YES)
/// or adds it to the main thread (if @c usesDedicatedThread is NO).
- (void) _startTapping;

/// Removes the tap and cancels any dedicated thread we were running it on.
- (void) _stopTapping;

/// Runs continuously on tapThread, listening to the tap until _stopTapping is called and the thread is cancelled.
- (void) _runTapInDedicatedThread;

/// Attempts to find our current tap in @c CGGetTapList() and checks what event types it was actually permitted to listen to.
- (BXKeyboardEventTapStatus) _reportedStatusOfEventTap;

@end


@implementation BXKeyboardEventTap
{
	CFMachPortRef _tap;
	CFRunLoopSourceRef _source;
}

- (id) init
{
    self = [super init];
    if (self)
    {
        self.usesDedicatedThread = NO;
    }
    return self;
}

- (void) dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver: self];
    
    [self _stopTapping];
}

- (void) setEnabled: (BOOL)flag
{
    if (_enabled != flag)
    {
        _enabled = flag;
        
        if (flag)
            [self _startTapping];
        else
            [self _stopTapping];
    }
}

- (void) setUsesDedicatedThread: (BOOL)usesDedicatedThread
{
    if (usesDedicatedThread != self.usesDedicatedThread)
    {
        BOOL wasTapping = self.status != BXKeyboardEventTapNotTapping;
        if (wasTapping)
        {
            [self _stopTapping];
        }
        
        _usesDedicatedThread = usesDedicatedThread;
        
        if (wasTapping)
        {
            [self _startTapping];
        }
    }
}

+ (BOOL) canCaptureKeyEvents
{
    return AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)@{(__bridge NSString*)kAXTrustedCheckOptionPrompt: @NO});
}

- (BXKeyboardEventTapStatus) _reportedStatusOfEventTap
{
    uint32_t i, numTaps = 0;
    CGGetEventTapList(0, NULL, &numTaps);
    
    BXKeyboardEventTapStatus status = BXKeyboardEventTapNotTapping;
    if (numTaps > 0)
    {
        CGEventTapInformation *taps = malloc(sizeof(CGEventTapInformation) * numTaps);
        CGGetEventTapList(numTaps, taps, &numTaps);
        
        pid_t processID = [NSProcessInfo processInfo].processIdentifier;
        for (i=0; i<numTaps; i++)
        {
            CGEventTapInformation tap = taps[i];
            
            //FIXME: this assumes our process only has a single tap going at once.
            //Unfortunately we have no other way to determine if this tap is our own or not.
            if (tap.tappingProcess == processID)
            {
                CGEventMask keyEvents = CGEventMaskBit(kCGEventKeyUp) | CGEventMaskBit(kCGEventKeyDown);
                CGEventMask systemEvents = CGEventMaskBit(NX_SYSDEFINED);
                
                if ((tap.eventsOfInterest & keyEvents) == keyEvents)
                {
                    status = BXKeyboardEventTapTappingAllKeyboardEvents;
                }
                else if ((tap.eventsOfInterest & systemEvents) == systemEvents)
                {
                    status = BXKeyboardEventTapTappingSystemEventsOnly;
                }
                else
                {
                    status = BXKeyboardEventTapNotTapping;
                }
                
                break;
            }
        }
        free(taps);
    }
    
    return status;
}

- (BOOL) _installEventTapOnCurrentThread
{
    @synchronized(self)
    {
        //Captures system-defined events. We use this for intercepting media keys.
        CGEventMask systemEvents = CGEventMaskBit(NX_SYSDEFINED);
        CGEventMask eventsToCapture = systemEvents;

        //Captures keyup and keydown events. We use this for intercepting OS X hotkeys.
        //Only ask for these when Accessibility has already been granted: on recent macOS
        //versions, repeatedly attempting a privileged tap can repeatedly trigger TCC prompts.
        if (self.class.canCaptureKeyEvents)
        {
            eventsToCapture |= CGEventMaskBit(kCGEventKeyUp) | CGEventMaskBit(kCGEventKeyDown);
        }
        
        _tap = CGEventTapCreate(kCGSessionEventTap, 
                                kCGHeadInsertEventTap,
                                kCGEventTapOptionDefault,
                                eventsToCapture,
                                _handleEventFromTap,
                                (__bridge void *)self);
        
        if (_tap)
        {
            _source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, _tap, 0);
            CFRunLoopAddSource(CFRunLoopGetCurrent(), _source, kCFRunLoopCommonModes);
            
            //CGEventTapCreate will silently disable event capture for keyup/keydown events if we don't have permission to tap them.
            //However, the tap may still be installed and only capturing system events: so we need to check what events it's actually
            //tapping.
            BXKeyboardEventTapStatus reportedStatus = [self _reportedStatusOfEventTap];
            switch (reportedStatus)
            {
                case BXKeyboardEventTapTappingAllKeyboardEvents:
                    NSLog(@"Event tap created and tapping all keyboard events.");
                    self.status = reportedStatus;
                    self.restartNeeded = NO;
                    return YES;
                case BXKeyboardEventTapTappingSystemEventsOnly:
                    NSLog(@"Event tap created but tapping system events only.");
                    self.status = reportedStatus;
                    return YES;
                case BXKeyboardEventTapNotTapping:
                case BXKeyboardEventTapInstalling: //Will never be returned by _reportedStatusOfEventTap, but included anyway to suppress compiler warnings.
                    NSLog(@"Event tap created but could not capture any relevant events: discarding.");
                    [self _removeEventTapFromCurrentThread];
                    self.status = reportedStatus;
                    return NO;
            }
        }
        else
        {
            NSLog(@"Event tap could not be created");
            self.status = BXKeyboardEventTapNotTapping;
            return NO;
        }
    }
}

- (void) _removeEventTapFromCurrentThread
{
    @synchronized(self)
    {
        if (_source)
        {
            CFRunLoopSourceInvalidate(_source);
            CFRelease(_source);
            _source = NULL;
        }
        
        if (_tap)
        {
            CFMachPortInvalidate(_tap);
            CFRelease(_tap);
            _tap = NULL;
        }
        
        self.status = BXKeyboardEventTapNotTapping;
    }
}

- (void) refreshEventTap
{
    if (self.isEnabled)
    {
        [self _stopTapping];
        [self _startTapping];
    }
}

- (void) _startTapping
{
    if (self.status == BXKeyboardEventTapNotTapping)
    {
        if (!self.class.canCaptureKeyEvents)
        {
            //IMPLEMENTATION NOTE: say so. This return used to be silent, which
            //made "the tap is not installed" indistinguishable from "the tap
            //code did not run at all" -- and since an ad-hoc-signed build has
            //no Accessibility permission, that is the case on every run of a
            //development build. D46 could not be run-tested for want of this
            //one line telling us which of the two we were looking at.
            NSLog(@"Not installing event tap: Boxer has not been granted Accessibility permission. "
                  @"Grant it to this bundle in System Settings > Privacy & Security > Accessibility.");
            self.status = BXKeyboardEventTapNotTapping;
            [self.delegate eventTapDidFinishAttaching: self];
            return;
        }

        self.status = BXKeyboardEventTapInstalling;
        if (self.usesDedicatedThread)
        {
            NSLog(@"Installing event tap on dedicated thread.");
            self.tapThread = [[ADBContinuousThread alloc] initWithTarget: self
                                                                 selector: @selector(_runTapInDedicatedThread)
                                                                   object: nil];
            
            [self.tapThread start];
        }
        else
        {
            NSLog(@"Installing event tap on main thread.");
            [self _installEventTapOnCurrentThread];
            [self.delegate eventTapDidFinishAttaching: self];
        }
    }
}

- (void) _runTapInDedicatedThread
{
    @autoreleasepool {
    
    BOOL installed = [self _installEventTapOnCurrentThread];
    [self.delegate eventTapDidFinishAttaching: self];
    
    if (installed)
    {
        //Run this thread's run loop until we're told to stop: processing event-tap
        //callbacks and other messages on this thread.
        [(ADBContinuousThread *)[NSThread currentThread] runUntilCancelled];
        
        //Clean up the tap once the thread is cancelled
        [self _removeEventTapFromCurrentThread];
    }
    
    }
}

- (void) _stopTapping
{
    if (self.status != BXKeyboardEventTapNotTapping)
    {
        if (self.usesDedicatedThread && self.tapThread)
        {
            //The thread will clean itself up
            [self.tapThread cancel];

            //IMPLEMENTATION NOTE: we deliberately do not use -waitUntilFinished
            //here, which waits forever. -waitUntilFinished spin-sleeps without
            //servicing the main queue, so anything the tap thread waits on the
            //main queue for while we are cancelling deadlocks the two threads
            //against each other: the tap thread waits on the main thread and the
            //main thread waits on the tap thread. On quit that hung the app
            //outright, with no window left to explain why. See D46 in FINDINGS.md.
            //
            //The cause is fixed: handling a key event no longer touches the main
            //queue at all. -eventTap:shouldCaptureKeyEvent: answers from state
            //cached on the main thread as it changes, and the CGEvent-to-NSEvent
            //conversion above happens on the tap thread. This bounded wait stays
            //as belt and braces, since waiting at all is only a courtesy -- the
            //thread retains itself until it exits, and the system removes the tap
            //with the process.
            NSDate *started = [NSDate date];
            NSDate *deadline = [started dateByAddingTimeInterval: 0.5];
            while (self.tapThread.isExecuting && deadline.timeIntervalSinceNow > 0)
                [NSThread sleepForTimeInterval: 0.001];

            if (self.tapThread.isExecuting)
                NSLog(@"Keyboard event tap thread did not stop when asked; abandoning it.");
            else
                //This is the line that answers D46: if the tap thread is still
                //waiting on the main queue with a key event in flight, it never
                //appears and the wait runs to its deadline instead.
                NSLog(@"Keyboard event tap thread stopped after %.0fms.",
                      -started.timeIntervalSinceNow * 1000.0);

            self.tapThread = nil;
        }
        else
        {
            [self _removeEventTapFromCurrentThread];
        }
    }
}

- (CGEventRef) _handleEvent: (CGEventRef)event
                     ofType: (CGEventType)type
                  fromProxy: (CGEventTapProxy)proxy
{
    //If we're not enabled or we have no way of validating the events, give up early
    if (!self.enabled || !self.delegate)
    {
        return event;
    }
    
    switch (type)
    {
        case kCGEventKeyDown:
        case kCGEventKeyUp:
        case NX_SYSDEFINED:
        {
            BOOL shouldCapture = NO;
            
            //First try and make this into a cocoa event.
            //
            //IMPLEMENTATION NOTE: this used to be done inside a dispatch_sync to
            //the main queue. That is the other half of D46: -_stopTapping waits
            //for this thread from the main thread, so any main-queue wait here
            //can deadlock the two against each other when the tap is cancelled
            //with an event in flight. The wrapper is built on this thread
            //instead. The resulting NSEvent was already being read from this
            //thread by the delegate callbacks below, so only its construction
            //moved. The @try is kept: eventWithCGEvent: throws for events it
            //cannot represent.
            NSEvent *cocoaEvent = nil;
            @try
            {
                cocoaEvent = [NSEvent eventWithCGEvent: event];
            }
            @catch (NSException *exception)
            {
#ifdef BOXER_DEBUG
                //If the event could not be converted into a cocoa event, give up
                NSString *eventDesc = CFBridgingRelease(CFCopyDescription(event));
                NSLog(@"Could not convert CGEvent: %@", eventDesc);
#endif
            }
            
            if (cocoaEvent)
            {
                if (type == NX_SYSDEFINED)
                {
                    shouldCapture = [self.delegate eventTap: self shouldCaptureSystemDefinedEvent: cocoaEvent];
                }
                else
                {
                    shouldCapture = [self.delegate eventTap: self shouldCaptureKeyEvent: cocoaEvent];
                }
            }
            
            if (shouldCapture)
            {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [NSApp postEvent: cocoaEvent atStart: YES];
                });
                
                //This approach ought to be closer to the normal behaviour
                //of the event dispatch mechanism, but seems to result
                //in key events occasionally getting lost, causing stuck keys.
                //So we go with a more explicit NSEvent-based dispatch instead.
                /*
                 ProcessSerialNumber PSN;
                 OSErr error = GetCurrentProcess(&PSN);
                 if (error == noErr)
                 {
                 CGEventPostToPSN(&PSN, event);
                 
                 //Returning NULL cancels the original event
                 return NULL;
                 }
                 */
                
                //Returning NULL cancels the original event
                return NULL;
            }
            
            break;
        }
        
        case kCGEventTapDisabledByTimeout:
        {
            //Re-enable the event tap if it has been disabled after a timeout.
            //(This may occur if our thread has been blocked for some reason.)
            CGEventTapEnable(_tap, YES);
            break;
        }
            
        case kCGEventTapDisabledByUserInput:
        {
            //Re-enable the event tap if it has been disabled after a timeout.
            //(This may occur if our thread has been blocked for some reason.)
            CGEventTapEnable(_tap, YES);
            break;
        }
    }
    
    return event;
}

static CGEventRef _handleEventFromTap(CGEventTapProxy proxy, CGEventType type, CGEventRef event, void *userInfo)
{
    CGEventRef returnedEvent = event;
    
    @autoreleasepool {
    BXKeyboardEventTap *tap = (__bridge BXKeyboardEventTap *)userInfo;
    if (tap)
    {
        returnedEvent = [tap _handleEvent: event ofType: type fromProxy: proxy];
    }
    }
    
    return returnedEvent;
}

@end
