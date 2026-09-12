/* 
 Copyright (c) 2013 Alun Bestor and contributors. All rights reserved.
 This source file is released under the GNU General Public License 2.0. A full copy of this license
 can be found in this XCode project at Resources/English.lproj/BoxerHelp/pages/legalese.html, or read
 online at [http://www.gnu.org/licenses/gpl-2.0.txt].
 */

#import "BXEmulatorPrivate.h"
#import "NSObject+ADBPerformExtensions.h"

#import <SDL2/SDL.h>
#import "cpu/cpu.h"
#import "config/config.h"
#import "shell/shell.h"
#import "gui/mapper.h"
#import "hardware/input/joystick.h"
#import "misc/cross.h"       // init_config_dir()


#pragma mark - Constants

//The name and path to the DOSBox shell. Used when determining the current process.
NSString * const shellProcessName = @"DOSBOX";
NSString * const shellProcessPath = @"Z:\\COMMAND.COM";
NSString * const autoexecProcessPath = @"Z:\\AUTOEXEC.BAT";


//BXEmulatorDelegate constants, defined here for want of somewhere better to put them.

NSString * const BXEmulatorWillStartNotification					= @"BXEmulatorWillStartNotification";
NSString * const BXEmulatorDidInitializeNotification				= @"BXEmulatorDidInitializeNotification";
NSString * const BXEmulatorWillRunStartupCommandsNotification		= @"BXEmulatorWillRunStartupCommandsNotification";
NSString * const BXEmulatorDidFinishNotification					= @"BXEmulatorDidFinishNotification";

NSString * const BXEmulatorWillStartProgramNotification				= @"BXEmulatorWillStartProgramNotification";
NSString * const BXEmulatorDidFinishProgramNotification				= @"BXEmulatorDidFinishProgramNotification";
NSString * const BXEmulatorDidReturnToShellNotification				= @"BXEmulatorDidReturnToShellNotification";

NSString * const BXEmulatorDidBeginGraphicalContextNotification		= @"BXEmulatorDidBeginGraphicalContextNotification";
NSString * const BXEmulatorDidFinishGraphicalContextNotification	= @"BXEmulatorDidFinishGraphicalContextNotification";

NSString * const BXEmulatorDidChangeEmulationStateNotification		= @"BXEmulatorDidChangeEmulationStateNotification";


NSString * const BXEmulatorDOSPathKey           = @"DOSPath";
NSString * const BXEmulatorIsBatchFileKey       = @"isBatchFile";
NSString * const BXEmulatorIsShellKey           = @"isShell";
NSString * const BXEmulatorDriveKey             = @"drive";
NSString * const BXEmulatorFileURLKey           = @"fileURL";
NSString * const BXEmulatorLogicalURLKey        = @"URL";
NSString * const BXEmulatorLaunchArgumentsKey   = @"arguments";
NSString * const BXEmulatorLaunchDateKey        = @"launchDate";
NSString * const BXEmulatorExitDateKey          = @"exitDate";

NSString * const BXDOSBoxErrorDomain = @"BXDOSBoxErrorDomain";


NSStringEncoding BXDisplayStringEncoding	= CFStringConvertEncodingToNSStringEncoding(kCFStringEncodingDOSLatin1);
NSStringEncoding BXDirectStringEncoding		= NSUTF8StringEncoding;



#pragma mark - External function definitions

//defined in dos_execute.cpp
extern const char* RunningProgram;

#if (C_DYNAMIC_X86)
//defined in core_dyn_x86.cpp
void CPU_Core_Dyn_X86_Cache_Init(bool enable_cache);
void CPU_Core_Dyn_X86_SetFPUMode(bool dh_fpu);

#elif (C_DYNREC)
//defined in core_dynrec.cpp
void CPU_Core_Dynrec_Cache_Init(bool enable_cache);
#endif


#pragma mark - Implementation

// Replaces DOSBox's CPU_OldCycleMax, removed in 0.83: it only ever backed
// Boxer's own save/restore of the cycle count around auto-speed changes.
// The fixed speed to return to when the user comes back from 'max'. Seeded
// with DOSBox's own real-mode default (CpuCyclesRealModeDefault) so that
// coming back from max before any fixed speed was ever set lands somewhere
// sensible rather than at the 50-cycle floor.
static int boxer_savedCycleMax = 3000;

@implementation BXEmulator
{
    CommandLine *commandLine;
    Config *configuration;
}
@synthesize processName = _processName;
@synthesize lastProcess = _lastProcess;
- (NSArray<NSDictionary<NSString *,id> *> *)runningProcesses
{
    return [[[NSArray alloc] initWithArray:_runningProcesses copyItems:YES] autorelease];
}
@synthesize delegate = _delegate;
@synthesize videoHandler = _videoHandler;
@synthesize mouse = _mouse;
@synthesize keyboard = _keyboard;
@synthesize printer = _printer;
@synthesize cancelled = _cancelled;
@synthesize executing = _executing;
@synthesize initialized = _initialized;
@synthesize paused = _paused;

@synthesize commandQueue = _commandQueue;
@synthesize emulationThread = _emulationThread;
@synthesize clearsScreenBeforeCommandExecution = _clearsScreenBeforeCommandExecution;

@synthesize activeMIDIDevice = _activeMIDIDevice;
@synthesize requestedMIDIDeviceDescription = _requestedMIDIDeviceDescription;
@synthesize autodetectsMT32 = _autodetectsMT32;
@synthesize masterVolume = _masterVolume;
@synthesize keyBuffer = _keyBuffer;
@synthesize waitingForCommandInput = _waitingForCommandInput;


#pragma mark - Global tracking variables

/// The singleton emulator instance. Returned by [BXEmulator currentEmulator].
static BXEmulator *_currentEmulator = nil;

/// Whether an emulator instance has been started yet. No other emulators can be started after this.
static BOOL _hasStartedEmulator = NO;


#pragma mark - Class methods

//Returns the currently executing emulator instance, for DOSBox coalface functions to talk to.
+ (BXEmulator *) currentEmulator
{
	return [[_currentEmulator retain] autorelease];
}

//Whether it is safe to launch a new emulator instance.
+ (BOOL) canLaunchEmulator;
{
	return !_hasStartedEmulator;
}

// 0.83 deprecated `cycles` in favour of `cpu_cycles`, which takes a bare number
// or "max" -- not the "fixed N" the old setting used. See D39 in FINDINGS.md.
+ (NSString *) configStringForFixedSpeed: (NSInteger)speed
								  isAuto: (BOOL)isAutoSpeed
{
	if (isAutoSpeed) return @"max";
	else return [NSString stringWithFormat: @"%ld", (long)speed];
}

+ (NSString *) configStringForCoreMode: (BXCoreMode)mode
{
	switch (mode)
	{
		case BXCoreNormal:
			return @"normal";
		case BXCoreFull:
			return @"full";
		case BXCoreDynamic:
			return @"dynamic";
		case BXCoreSimple:
			return @"simple";
		default:
			return @"auto";
	}
}

+ (NSString *) configStringForGameportTimingMode: (BXGameportTimingMode)mode
{
	return (mode == BXGameportTimingClockBased) ? @"true" : @"false";
}


#pragma mark - Key-value binding helper methods

//Every property depends on whether we're executing or not
+ (NSSet *) keyPathsForValuesAffectingValueForKey: (NSString *)key
{
	NSSet *keyPaths = [super keyPathsForValuesAffectingValueForKey: key];
	if (![key isEqualToString: @"isExecuting"]) keyPaths = [keyPaths setByAddingObject: @"isExecuting"];
	return keyPaths;
}



#pragma mark - Initialization and teardown

- (id) init
{
	if ((self = [super init]))
	{
        _runningProcesses       = [[NSMutableArray alloc] initWithCapacity: 1];
		_commandQueue           = [[NSMutableArray alloc] initWithCapacity: 4];
		_driveCache             = [[NSMutableDictionary alloc] initWithCapacity: DOS_DRIVES];
		_pendingSysexMessages   = [[NSMutableArray alloc] initWithCapacity: 4];
        
        self.masterVolume = 1.0f;
		
        self.keyboard = [[[BXEmulatedKeyboard alloc] init] autorelease];
        self.mouse = [[[BXEmulatedMouse alloc] init] autorelease];
        
        self.videoHandler = [[[BXVideoHandler alloc] init] autorelease];
		self.videoHandler.emulator = self;
        
        self.keyBuffer = [[[BXKeyBuffer alloc] init] autorelease];
    }
	return self;
}

- (void) dealloc
{
    [self.printer unbind: @"delegate"];
    
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wnonnull"
    self.processName = nil;
    self.lastProcess = nil;
    self.activeMIDIDevice = nil;
    self.requestedMIDIDeviceDescription = nil;
    
    self.keyboard = nil;
    self.mouse = nil;
    self.joystick = nil;
    self.printer = nil;
    self.videoHandler = nil;
    self.keyBuffer = nil;
    
    [_runningProcesses release]; _runningProcesses = nil;
    [_driveCache release]; _driveCache = nil;
    [_commandQueue release]; _commandQueue = nil;
    [_pendingSysexMessages release]; _pendingSysexMessages = nil;
	
	[super dealloc];
#pragma clang diagnostic pop
}


#pragma mark - Controlling emulation state

- (void) start
{
    NSAssert(_hasStartedEmulator == NO && _currentEmulator == nil,
             @"A second emulation session cannot be started after one has already been started.");
    
	if (self.isCancelled) return;
    
    self.emulationThread = [NSThread currentThread];
	
	//Record ourselves as the current emulator instance for DOSBox to talk to
    _currentEmulator = [self retain];
	_hasStartedEmulator = YES;
	
	[self _postNotificationName: BXEmulatorWillStartNotification
			   delegateSelector: @selector(emulatorWillStart:)
					   userInfo: nil];
	
	self.executing = YES;
	
	//Start DOSBox's main loop
	[self _startDOSBox];
	
	self.executing = NO;
	
	if (_currentEmulator == self)
    {
        [_currentEmulator release];
        _currentEmulator = nil;
	}
    
	[self _postNotificationName: BXEmulatorDidFinishNotification
			   delegateSelector: @selector(emulatorDidFinish:)
					   userInfo: nil];
}

- (void) cancel
{
    if (self.emulationThread && [NSThread currentThread] != self.emulationThread)
    {
        [self performSelector: _cmd onThread: self.emulationThread withObject: nil waitUntilDone: NO];
    }
    else
    {
        if (self.isExecuting && !self.isCancelled)
        {
            //Immediately kill audio output to avoid hanging notes
            [self pause];
        
            //Tells DOSBox to close the current shell at the end of the commandline input loop
            DOS_Shell *shell = self._currentShell;
            if (shell) DOSBOX_RequestShutdown();
        }

        self.cancelled = YES;
    }
}

+ (NSSet *) keyPathsForValuesAffectingConcurrent
{
    return [NSSet setWithObject: @"emulationThread"];
}

- (BOOL) isConcurrent
{
    return (self.emulationThread && self.emulationThread != [NSThread mainThread]);
}


- (NSURL *) baseURL
{
    NSString *cwdPath = [[NSFileManager defaultManager] currentDirectoryPath];
    if (cwdPath)
        return [NSURL fileURLWithPath: cwdPath];
    else
        return nil;
}

- (void) setBaseURL: (NSURL *)URL
{
    [[NSFileManager defaultManager] changeCurrentDirectoryPath: URL.path];
}



#pragma mark - Introspecting emulation state

- (NSDictionary *) currentProcess
{
    NSDictionary *currentProcess;
    
    @synchronized(_runningProcesses)
    {
        currentProcess = [[_runningProcesses lastObject] retain];
    }
    return [currentProcess autorelease];
}

+ (NSSet *) keyPathsForValuesAffectingCurrentProcess
{
    return [NSSet setWithObject: @"runningProcesses"];
}

- (BOOL) isAtPrompt
{
    if (!self.isExecuting) return NO;
    if (!self.isInitialized) return NO;
    
    NSDictionary *currentProcess = self.currentProcess;
    if (currentProcess && ![self processIsShell: currentProcess])
        return NO;
    
    return self.isWaitingForCommandInput;
}

+ (NSSet *) keyPathsForValuesAffectingIsAtPrompt
{
    return [NSSet setWithObjects: @"isInitialized", @"currentProcess", @"isWaitingForCommandInput", nil];
}

- (BOOL) isRunningAutoexec
{
    for (NSDictionary *processInfo in self.runningProcesses)
    {
        if ([self processIsAutoexec: processInfo])
            return YES;
    }
    return NO;
}

+ (NSSet *) keyPathsForValuesAffectingIsRunningAutoexec
{
    return [NSSet setWithObject: @"runningProcesses"];
}

- (BOOL) isRunningActiveProcess
{
    NSDictionary *currentProcess = self.currentProcess;
    return currentProcess && ![self processIsShell: currentProcess] && ![self processIsBatchFile: currentProcess];
}

+ (NSSet *) keyPathsForValuesAffectingIsRunningActiveProcess
{
    return [NSSet setWithObject: @"currentProcess"];
}

- (BOOL) processIsInternal: (NSDictionary *)processInfo
{
    NSString *dosPath = [processInfo objectForKey: BXEmulatorDOSPathKey];
    //Count any programs on drive Z as being internal
	return [dosPath characterAtIndex: 0] == 'Z';
}

- (BOOL) processIsAutoexec: (NSDictionary *)processInfo
{
    NSString *dosPath = [processInfo objectForKey: BXEmulatorDOSPathKey];
    return [dosPath isEqualToString: autoexecProcessPath];
}

- (BOOL) processIsShell: (NSDictionary *)processInfo
{
    return [[processInfo objectForKey: BXEmulatorIsShellKey] boolValue];
}

- (BOOL) processIsBatchFile: (NSDictionary *)processInfo
{
    return [[processInfo objectForKey: BXEmulatorIsBatchFileKey] boolValue];
}

#pragma mark -
#pragma mark Controlling DOSBox CPU settings

- (NSInteger) fixedSpeed
{
	return self.isExecuting ? (NSInteger)boxer_cpuCycles() : 0;
}

- (void) setFixedSpeed: (NSInteger)newSpeed
{
	if (self.isExecuting)
	{
        // Up to 0.78 this was a matter of assigning CPU_CycleMax. It is not at
        // 0.83: in the modern cycles model DOSBox re-derives CPU_CycleMax from
        // its own config struct at every real<->protected mode switch, so the
        // assignment would be undone mid-game. boxer_setCpuCycles() updates
        // whichever model is live and applies it now -- see its definition in
        // cpu.cpp, and D39 in FINDINGS.md.
        boxer_setCpuCycles((int)newSpeed);
	}
}

- (BOOL) isAutoSpeed
{
	return self.isExecuting ? (BOOL)boxer_isCpuCyclesMax() : NO;
}

- (void) setAutoSpeed: (BOOL)autoSpeed
{
	if (self.isExecuting && self.isAutoSpeed != autoSpeed)
	{
        if (autoSpeed)
        {
            boxer_savedCycleMax = (int)boxer_cpuCycles();
            boxer_setCpuCyclesToMax();
        }
        else
        {
            boxer_setCpuCycles(boxer_savedCycleMax);
        }
	}
}

/// Whether the speed Boxer last asked for is the speed now in force. It will
/// not be if there is no emulator running to apply it to; the CPU Inspector
/// uses this to decide whether to offer its "restart to apply" note.
- (BOOL) speedIsInEffect: (NSInteger)requestedSpeed isAuto: (BOOL)isAuto
{
    if (!self.isExecuting) return NO;
    if (isAuto) return self.isAutoSpeed;
    return !self.isAutoSpeed && self.fixedSpeed == requestedSpeed;
}

- (BOOL) usesLegacyCyclesConfig
{
    return self.isExecuting ? (BOOL)boxer_isLegacyCyclesMode() : NO;
}

- (BXCoreMode) coreMode
{
	if (self.isExecuting)
	{
		if (cpudecoder == &CPU_Core_Normal_Run ||
			cpudecoder == &CPU_Core_Normal_Trap_Run)	return BXCoreNormal;
		
#if (C_DYNAMIC_X86)
		if (cpudecoder == &CPU_Core_Dyn_X86_Run ||
			cpudecoder == &CPU_Core_Dyn_X86_Trap_Run)	return BXCoreDynamic;
#endif
		
#if (C_DYNREC)
		if (cpudecoder == &CPU_Core_Dynrec_Run ||
			cpudecoder == &CPU_Core_Dynrec_Trap_Run)	return BXCoreDynamic;
#endif
		
		if (cpudecoder == &CPU_Core_Simple_Run)			return BXCoreSimple;
		if (cpudecoder == &CPU_Core_Full_Run)			return BXCoreFull;
		
		return BXCoreUnknown;
	}
	else return BXCoreUnknown;
}
- (void) setCoreMode: (BXCoreMode)coreMode
{
	if (self.isExecuting && self.coreMode != coreMode)
	{
		switch(coreMode)
		{
			case BXCoreNormal:
				cpudecoder = &CPU_Core_Normal_Run;
				break;
				
			case BXCoreDynamic:
#if (C_DYNAMIC_X86)
				CPU_Core_Dyn_X86_Cache_Init(true);
				CPU_Core_Dyn_X86_SetFPUMode(true);
				cpudecoder = &CPU_Core_Dyn_X86_Run;
#endif
				
#if (C_DYNREC)
				CPU_Core_Dynrec_Cache_Init(true);
				cpudecoder = &CPU_Core_Dynrec_Run;
#endif
				break;
			case BXCoreSimple:	
				cpudecoder = &CPU_Core_Simple_Run;
				break;
			case BXCoreFull:
				cpudecoder = &CPU_Core_Full_Run;
				break;
		}
		
		//Prevent DOSBox from resetting the core mode after a program exits
		auto_determine_mode.auto_core = false;
		
		//Reset DOSBox's emulated cycles counters
		CPU_CycleLeft=0;
		CPU_Cycles=0;
	}
}


#pragma mark -
#pragma mark Handling changes to application focus

- (void) pause
{
	if (!self.isPaused)
	{
        if (self.emulationThread && [NSThread currentThread] != self.emulationThread)
        {
            [self performSelector: _cmd onThread: self.emulationThread withObject: nil waitUntilDone: NO];
        }
        else
        {
            @synchronized(self)
            {
                self.paused = YES;
                [self _suspendAudio];
            }
        }
	}
}

- (void) resume
{	
	if (self.isPaused)
    {
        if (self.emulationThread && [NSThread currentThread] != self.emulationThread)
        {
            [self performSelector: _cmd onThread: self.emulationThread withObject: nil waitUntilDone: NO];
        }
        else
        {
            @synchronized(self)
            {
                self.paused = NO;
                [self _resumeAudio];
            }
        }
	}
}


#pragma mark -
#pragma mark Gameport emulation

- (BXGameportTimingMode) gameportTimingMode
{
	return (BXGameportTimingMode)gameport_timed;
}

- (void) setGameportTimingMode: (BXGameportTimingMode)mode
{
    @synchronized(self)
    {
        if (gameport_timed != mode)
        {
            gameport_timed = mode;
            [self.joystick clearInput];
        }
    }
}

- (BOOL) joystickActive
{
    return _joystickActive;
}

- (void) setJoystickActive: (BOOL)flag
{
    @synchronized(self)
    {
        //TWEAK: disregard attempts to access the gameport when there's nothing connected to it.
        //This way, the joystickActive flag indicates to Boxer whether the game is *still* listening
        //to input, rather than whether the game looked for a joystick that wasn't there at startup
        //and then gave up.
        if (self.joystick || !flag)
        {
            _joystickActive = flag;
        }
    }
}

- (BXJoystickSupportLevel) joystickSupport
{
	switch (joytype)
	{
		case JOY_DISABLED:
		case JOY_NONE_FOUND:
		case JOY_ONLY_FOR_MAPPING:
			return BXNoJoystickSupport;
			break;
		case JOY_2AXIS:
			return BXJoystickSupportSimple;
			break;
		default:
			return BXJoystickSupportFull;
	}
}

- (id <BXEmulatedJoystick>) joystick
{
    @synchronized(self)
    {
        [_joystick retain];
    }
    return [_joystick autorelease];
}

- (void) setJoystick: (id <BXEmulatedJoystick>)newJoystick
{
    @synchronized(self)
    {
        if (self.joystick != newJoystick)
        {
            //Detach the existing joystick...
            if (_joystick)
            {
                [_joystick willDisconnect];
                [_joystick release];
            }
            
            _joystick = [newJoystick retain];
            
            //...and prepare the new one
            if (_joystick)
            {
                [_joystick didConnect];
            }
        }
    }
}

- (BOOL) validateJoystick: (id <BXEmulatedJoystick> *)ioValue error: (NSError **)outError
{
	id <BXEmulatedJoystick> newJoystick = *ioValue;
    Class joystickClass = [newJoystick class];
	
	//Nil values are just fine, skip all the other checks 
	if (!newJoystick) return YES;
	
	//Not actually a joystick class
	if (![newJoystick conformsToProtocol: @protocol(BXEmulatedJoystick)])
	{
		if (outError)
		{
			NSString *descriptionFormat = NSLocalizedString(@"“%@” is not a valid joystick type.",
															@"Format for error message when choosing an unrecognised joystick type. %@ is the classname of the chosen joystick type.");
			
			NSString *description = [NSString stringWithFormat: descriptionFormat, NSStringFromClass(joystickClass)];
			
			NSDictionary *userInfo = [NSDictionary dictionaryWithObjectsAndKeys:
									  description, NSLocalizedDescriptionKey,
									  joystickClass, BXEmulatedJoystickClassKey,
									  nil];
			
			*outError = [NSError errorWithDomain: BXEmulatedJoystickErrorDomain
											code: BXEmulatedJoystickInvalidType
										userInfo: userInfo];
		}
		return NO;
	}
	
	//Joystick class valid but not supported by the current session
	if (self.joystickSupport == BXNoJoystickSupport || 
		(self.joystickSupport == BXJoystickSupportSimple && [joystickClass requiresFullJoystickSupport]))
	{
		if (outError)
		{
			NSString *localizedName	= [joystickClass localizedName];
			
			NSString *descriptionFormat = NSLocalizedString(@"Joysticks of type “%1$@” are not supported by the current session.",
															@"Format for error message when choosing an unsupported joystick type. %1$@ is the localized name of the chosen joystick type.");
			
			NSString *description = [NSString stringWithFormat: descriptionFormat, localizedName];
			
			NSDictionary *userInfo = [NSDictionary dictionaryWithObjectsAndKeys:
									  description, NSLocalizedDescriptionKey,
									  joystickClass, BXEmulatedJoystickClassKey,
									  nil];
			
			*outError = [NSError errorWithDomain: BXEmulatedJoystickErrorDomain
											code: BXEmulatedJoystickUnsupportedType
										userInfo: userInfo];
		}
		return NO; 
	}
	
	//Joystick type is fine, go ahead
	return YES;
}

#pragma mark -
#pragma mark Audio setter methods


- (void) setMasterVolume: (float)volume
{
    volume = std::max(0.0f, volume);
    volume = MIN(volume, 1.0f);
    
    if (self.masterVolume != volume)
    {
        _masterVolume = volume;
        [self _syncVolume];
    }
}

- (void) setRequestedMIDIDeviceDescription: (NSDictionary *)newDescription
{
    if (![_requestedMIDIDeviceDescription isEqual: newDescription])
    {
        [_requestedMIDIDeviceDescription release];
        _requestedMIDIDeviceDescription = [newDescription retain];

        //Enable MT-32 autodetection if the description doesn't have a specific music type in mind.
        BXMIDIMusicType musicType = BXMIDIMusicType([[newDescription objectForKey: BXMIDIMusicTypeKey] integerValue]);
        self.autodetectsMT32 = (musicType == BXMIDIMusicAutodetect);
    }
}

- (void) setActiveMIDIDevice: (id<BXMIDIDevice>)device
{
    if (device != self.activeMIDIDevice)
    {
        [_activeMIDIDevice release];
        _activeMIDIDevice = [device retain];

        //If the device supports mixing, create a DOSBox mixer channel for it.
        if ([device conformsToProtocol: @protocol(BXAudioSource)])
        {
            [self _addMIDIMixerChannelWithSampleRate: [(id <BXAudioSource>)device sampleRate]];
        }
        //Otherwise, disable and remove any existing mixer channel.
        else
        {
            [self _removeMIDIMixerChannel];
        }
        
#ifdef BOXER_DEBUG
        //When debugging, display an LCD message so that we know MT-32 mode has kicked in
        if (device.supportsMT32Music)
            [self sendMT32LCDMessage: @"BOXER:::MT-32 Active"];
#endif
    }
}

- (void) setDelegate: (id <BXEmulatorDelegate, BXEmulatorFileSystemDelegate, BXEmulatorAudioDelegate, BXEmulatedPrinterDelegate>)delegate
{
    _delegate = delegate;
    self.printer.delegate = delegate;
}

@end



#pragma mark -
#pragma mark Private methods

@implementation BXEmulator (BXEmulatorInternals)

- (DOS_Shell *) _currentShell
{
	return currentShell;
}

- (void) _postNotificationName: (NSString *)name
			  delegateSelector: (SEL)selector
					  userInfo: (NSDictionary *)userInfo
{
    //Always post notifications on the main thread.
    if (![NSThread isMainThread])
    {
        [self performSelectorOnMainThread: _cmd waitUntilDone: NO withValues: &name, &selector, &userInfo];
    }
    else
    {
        NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
        NSNotification *notification = [NSNotification notificationWithName: name
                                                                     object: self
                                                                   userInfo: userInfo];
        
        if ([self.delegate respondsToSelector: selector])
            [self.delegate performSelector: selector withObject: notification];
        
        [center postNotification: notification];
    }
}


#pragma mark - Synchronizing emulation state

//Dispatch KVC notifications on the main thread
- (void) willChangeValueForKey: (NSString *)key
{
    if (![NSThread isMainThread])
        [self performSelectorOnMainThread: _cmd withObject: key waitUntilDone: NO];
    else
        [super willChangeValueForKey: key];
}

- (void) didChangeValueForKey: (NSString *)key
{
    if (![NSThread isMainThread])
        [self performSelectorOnMainThread: _cmd withObject: key waitUntilDone: NO];
    else
        [super didChangeValueForKey: key];
}

//Called by coalface functions to notify Boxer that the emulation state may have changed behind its back
- (void) _didChangeEmulationState
{
    if (![NSThread isMainThread])
    {
        [self performSelectorOnMainThread: _cmd withObject: nil waitUntilDone: NO];
    }
    else
    {
        [self willChangeValueForKey: @"fixedSpeed"];
        [self willChangeValueForKey: @"autoSpeed"];
        [self willChangeValueForKey: @"coreMode"];
        
        [self didChangeValueForKey: @"fixedSpeed"];
        [self didChangeValueForKey: @"autoSpeed"];
        [self didChangeValueForKey: @"coreMode"];
        
        NSString *newProcessName = [NSString stringWithCString: RunningProgram
                                                      encoding: BXDirectStringEncoding];
        
        if ([newProcessName isEqualToString: shellProcessName]) newProcessName = nil;
        self.processName = newProcessName;
        
        //Let the delegate know that the emulation state has changed behind its back, so it can re-check CPU settings
        [self _postNotificationName: BXEmulatorDidChangeEmulationStateNotification
                   delegateSelector: @selector(emulatorDidChangeEmulationState:)
                           userInfo: nil];
    }
}

- (void) _didInitialize
{
	self.initialized = YES;
	
	//These flags will only change during initialization
	[self willChangeValueForKey: @"gameportTimingMode"];
	[self willChangeValueForKey: @"joystickSupport"];
	
	[self didChangeValueForKey: @"gameportTimingMode"];
	[self didChangeValueForKey: @"joystickSupport"];
	
	//Let the delegate know that the emulation state has changed behind its back, so it can re-check CPU settings
	[self _postNotificationName: BXEmulatorDidInitializeNotification
			   delegateSelector: @selector(emulatorDidInitialize:)
					   userInfo: nil];
}

- (void) _didFinishFrame: (BXVideoFrame *)frame
{
    [self.delegate emulator: self didFinishFrame: frame];
}


#pragma mark -
#pragma mark Runloop handling

- (void) _processEvents
{
    //Let our delegate process events for us if we don't have our own thread
    if (!self.isConcurrent)
    {
        [self.delegate processEventsForEmulator: self];
    }
    else
    {
        NSDate *untilDate = self.isPaused ? [NSDate distantFuture] : [NSDate distantPast];
        
        while ([[NSRunLoop currentRunLoop] runMode: NSDefaultRunLoopMode beforeDate: untilDate])
        {
            if (self.isCancelled) break;
            if (!self.isPaused) break;
        }
    }
}

- (BOOL) _runLoopShouldContinue
{
	//If emulation has been cancelled or we otherwise want to wrest control away
	//from DOSBox, then break out of the current DOSBox run loop.
	//TWEAK: it's only safe to break out once initialization is done, since some
	//of DOSBox's initialization routines rely on running tasks on the run loop
	//and may crash if they fail to complete.
	if ((self.isCancelled || DOSBOX_IsShutdownRequested()) && self.isInitialized)
    {
        return NO;
	}
	return YES;
}

- (void) _runLoopWillStartWithContextInfo: (void **)contextInfo
{
    //Create an autorelease pool for this iteration of the runloop:
    //we'll drain it down in _runLoopDidFinishWithAutoreleasePool:
    if (contextInfo)
    {
        *contextInfo = [[NSAutoreleasePool alloc] init];
    }
	[self.delegate emulatorWillStartRunLoop: self];
}

- (void) _runLoopDidFinishWithContextInfo: (void *)contextInfo
{
	[self.delegate emulatorDidFinishRunLoop: self];
    
    _lastRunLoopTime = [NSDate timeIntervalSinceReferenceDate];
    
    if (contextInfo)
    {
        [(NSAutoreleasePool *)contextInfo drain];
    }
}


//This is a cut-down and mashed-up version of DOSBox's old main and GUI_StartUp functions,
//chopping out all the stuff that Boxer doesn't need or want.
/// Serialises DOSBox's process-wide setup and teardown against each other.
///
/// Boxer normally runs one session per process, but -[BXSession
/// restartShowingLaunchPanel:] closes the session and immediately opens a new
/// one in *this* process, without waiting for the old emulation thread. Since
/// DOSBox's modules -- and `control` itself -- are file-scope globals, the new
/// session's setup and the old session's teardown would otherwise run at the
/// same time on two threads and fight over the same objects. Holding this while
/// each of them runs makes the new session wait for the old one instead.
///
/// Teardown only became long enough for that to matter when it started
/// destroying DOSBox's modules properly; see -_tearDownDOSBox and D45.
static NSObject *_DOSBoxLifecycleLock(void)
{
    static NSObject *lock;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ lock = [[NSObject alloc] init]; });
    return lock;
}

- (void) _startDOSBox
{
	//Initialize the SDL modules that DOSBox will need.
	NSAssert1(!SDL_Init(SDL_INIT_AUDIO),
			  @"SDL failed to initialize with the following error: %s", SDL_GetError());
	
	try
	{
        //Once DOSBox starts, it'll take over the run loop and any objects that were allocated
        //before it starts will stay alive until it finishes. To mitigate this we wrap the
        //emulator startup sequence in an autorelease block, so that at least those objects
        //will get released before we begin emulating in earnest.
        @autoreleasepool {
        
        //See _DOSBoxLifecycleLock(): a previous session in this process may
        //still be tearing DOSBox down on its own thread, and everything below
        //touches the same process-wide globals it is destroying.
        @synchronized (_DOSBoxLifecycleLock()) {
        
            //Create a new configuration instance and feed it an empty set of parameters.
            char const *argv[0];
            commandLine = new CommandLine(0, argv);
            control.reset(new Config(commandLine));
            configuration = control.get();
            
            //Work out where DOSBox's config directory is. This has to happen
            //before the config sections are declared: several of their path
            //properties resolve their default value against it, so
            //add_dosbox_config_section() asserts without it.
            //
            //On macOS this creates ~/Library/Preferences/DOSBox if it does not
            //exist. Boxer never had a DOSBox config directory before, and this
            //is upstream's location rather than one under Boxer's own
            //Application Support folder -- see D34 in FINDINGS.md.
            init_config_dir();

            //Sets up the vast swathes of DOSBox configuration file parameters
            //and registers every module's messages.
            //
            //Up to 0.78 this was DOSBOX_Init(), which both declared the config
            //sections and initialised the modules. 0.83 split that in three, and
            //DOSBOX_Init() is now the *last* part: DOSBOX_InitModules() calls it
            //as its own first statement, and it opens with
            //get_section("dosbox"), which asserts if the sections do not exist
            //yet. Calling DOSBOX_Init() here aborted before Boxer got anywhere.
            //
            //Boxer deliberately does not call upstream's fourth registrar,
            //GFX_AddConfigSection(): it lives in the sdl_gui.cpp frontend Boxer
            //replaces and declares the [sdl] section plus the title-bar
            //settings, none of which anything Boxer compiles reads. The
            //TITLEBAR_* message strings go missing with it, which costs a
            //"Message not found" warning for a title Boxer never displays.
            DOSBOX_InitModuleConfigsAndMessages();

            //Ask our delegate for the configuration files we should be loading today.
            //This has to happen after the sections above are declared: parsing a
            //config file means assigning to properties that must already exist.
            NSArray *configURLs = [self.delegate configurationURLsForEmulator: self];
            for (NSURL *configURL in configURLs)
            {
                const char *encodedConfigPath = configURL.fileSystemRepresentation;
                control->ParseConfigFile("custom", encodedConfigPath);
            }

            //Initialise each DOSBox module based on the loaded configuration.
            //Calls DOSBOX_Init() itself, first.
            DOSBOX_InitModules();

            //Tell 0.83's mouse subsystem that the frontend is up. Without this
            //it never starts, and its startup is what installs the INT 33h DOS
            //mouse driver -- so every DOS program reports that no mouse driver
            //is present. Upstream says this from GFX_InitAndStartGui().
            boxer_notifyMouseReady();
            
            [self _didInitialize];
        }
        }
        
		//Start up the main machine. Up to 0.78 this was control->StartUp(),
		//which invoked the registered start function; 0.83 starts the shell
		//directly.
		SHELL_InitAndRun();
	}
	catch (char *errMessage)
	{
        self.executing = NO;

        // ObjC exceptions don't trigger C++ stack unwinding, so we must
        // clean up DOSBox state explicitly before raising.
        [self _tearDownDOSBox];

        NSString *reason = [NSString stringWithCString: errMessage encoding: BXDirectStringEncoding];
        [NSException raise: BXEmulatorUnrecoverableException
                    format: @"DOSBox aborted with the following error: %@", reason];
	}
    catch (boxer_emulatorException &e)
    {
        self.executing = NO;

        // ObjC exceptions don't trigger C++ stack unwinding, so we must
        // clean up DOSBox state explicitly before raising.
        [self _tearDownDOSBox];

        NSException *exception = [BXEmulatorException exceptionWithName: BXEmulatorUnrecoverableException
                                                      originalException: &e];
        [exception raise];
    }
	catch (int)
	{
		//This means that something pressed the killswitch in DOSBox and we should shut down normally.
	}
	//Any other exception is a genuine fuckup and needs to be thrown all the way up.
	
	//Clean up after DOSBox finishes.
    [self _tearDownDOSBox];
}

//The counterpart to the initialisation in -_startDOSBox above: shuts down
//DOSBox, in the order upstream shuts it down in.
//
//IMPLEMENTATION NOTE: DOSBOX_DestroyModules() is new here. Up to 0.78 Boxer
//dropped the Config and left it at that, and 0.83 made that a crash: DOSBox's
//modules now own objects in file-scope statics that log from their destructors,
//so leaving them alive means they are destroyed during C++ static teardown at
//exit() -- by which time loguru's own function-local static mutex may already
//be gone. That is exactly what happened on every quit (D45): port.cpp's
//`static std::unique_ptr<IO> io_module` outlived the session, ~IO() called
//LOG_DEBUG from static teardown, and the app aborted with
//"recursive_mutex lock failed" instead of exiting.
//
//DOSBOX_DestroyModules() is upstream's own teardown, called from main.cpp right
//after SHELL_InitAndRun() returns -- the same place Boxer reaches here -- and it
//ends by resetting `control` itself, which is why the Config is no longer reset
//separately.
//
//Order matters in two places. The video handler is shut down first, while the
//render pipeline it calls into still exists; and SDL is quit last, because
//MIXER_Destroy() closes the audio device SDL owns.
- (void) _tearDownDOSBox
{
    @synchronized (_DOSBoxLifecycleLock())
    {
        //Idempotent: -tearDownForImminentExit below may have to do this from a
        //quit path that will never let -_startDOSBox return, and the ordinary
        //teardown at the end of -_startDOSBox must then not run it a second time.
        //`configuration` is cleared below and is the marker for "already done".
        if (!configuration) return;

        [self.videoHandler shutdown];

        DOSBOX_DestroyModules();
        configuration = NULL;

        SDL_Quit();

        delete commandLine;
        commandLine = NULL;
    }
}

//Last-resort teardown for a quit that is about to call exit() with DOSBox still
//running, which -_startDOSBox's own teardown above will never get to.
//
//-[NSApplication terminate:] calls exit() directly, and Boxer pumps NSApp's
//event queue from inside DOSBox's emulation loop (-[BXSession
//_processEventsUntilDate:], called from normal_loop via boxer_processEvents).
//So a Cmd-Q key equivalent is routed to terminate: *from inside* that loop:
//exit() runs with normal_loop still on the stack, -_startDOSBox never returns,
//and DOSBox's modules are left to C++ static teardown -- which is D45 exactly,
//the abort in ~IO() logging through a loguru mutex that is already gone. A quit
//by Apple Event does not do this, because it does not come back through
//sendEvent: while the loop is on the stack, which is why quitting that way looked
//clean and Cmd-Q did not. This is D60.
//
//Calling DOSBOX_DestroyModules() with normal_loop still on the stack is only
//safe because we never return to it: exit() is the next thing that runs.
+ (void) tearDownForImminentExit
{
    [_currentEmulator _tearDownDOSBox];
}

@end



#pragma mark -
#pragma mark Parallel port emulation

@implementation BXEmulator (BXParallelInternals)

- (void) _didRequestPrinterOnLPTPort: (NSUInteger)portNumber
{
    if (!self.printer)
    {
        self.printer = [[[BXEmulatedPrinter alloc] init] autorelease];
        self.printer.port = (BXEmulatedPrinterPort)(portNumber + 1);
        self.printer.delegate = self.delegate;
    }
}

@end
