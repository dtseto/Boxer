/* 
 Copyright (c) 2013 Alun Bestor and contributors. All rights reserved.
 This source file is released under the GNU General Public License 2.0. A full copy of this license
 can be found in this XCode project at Resources/English.lproj/BoxerHelp/pages/legalese.html, or read
 online at [http://www.gnu.org/licenses/gpl-2.0.txt].
 */


//The BXUIControls category is responsible for bridging the session's UI elements with the
//underlying session, emulator and gamebox features. Most of its methods are UI-facing.

#import <Cocoa/Cocoa.h>
#import "BXSession.h"

/// The CPU-class thresholds the speed slider bands onto, taken from the ladder
/// in 0.83's own `cpu_cycles` help so that Boxer and DOSBox Staging describe the
/// same speed the same way:
///
///     8088 (4.77 MHz)  300     486DX-33          12000
///     286-8            700     486DX/2-66        25000
///     286-12          1500     Pentium 90        50000
///     386SX-20        3000     Pentium MMX-166  100000
///     386DX-33        6000     Pentium II 300   200000
///     386DX-40        8000
///
/// The floor is DOSBox's own CpuCyclesMin rather than a CPU class: plenty of
/// early games need to run slower than an 8088.
enum
{
	BXMaxSpeedThreshold		= 200000,	//Pentium II 300
	BXPentiumSpeedThreshold	= 50000,	//Pentium 90
	BX486SpeedThreshold		= 12000,	//486DX-33
	BX386SpeedThreshold		= 3000,		//386SX-20
	BX286SpeedThreshold		= 700,		//286-8
	BXMinSpeedThreshold		= 50		//CpuCyclesMin
};

/// The increments the CPU speed slider snaps to within each band above.
enum
{
	BXPentiumSpeedIncrement	= 10000,
	BX486SpeedIncrement		= 2500,
	BX386SpeedIncrement		= 500,
	BX286SpeedIncrement		= 100,
	BXMinSpeedIncrement		= 50
};

/// Stands in for "as fast as the host can manage" (0.83's `cpu_cycles = max`).
#define BXAutoSpeed -1

typedef NS_ENUM(NSInteger, BXPlaybackMode) {
    BXPaused,
    BXPlaying,
};

@class BXEmulator;

/// The \c BXUIControls category is responsible for bridging the session's UI elements with the
/// underlying session, emulator and gamebox features. Most of its methods are UI-facing.
@interface BXSession (BXUIControls)

#pragma mark -
#pragma mark Properties

/// The CPU speed, as a fixed cycles number or BXAutoSpeed (if autoSpeed is YES).
@property (assign, nonatomic) NSInteger CPUSpeed;

/// Whether the CPU runs as fast as the host can manage.
@property (assign, nonatomic, getter=isAutoSpeed) BOOL autoSpeed;

/// The slider speed snaps the CPU speed to fixed increments and bumps it to
/// maximum at the top of its range. Used by the speed slider in the CPU panel.
@property (assign, nonatomic) NSInteger sliderSpeed;

/// Localised human-readable description of the current CPU speed.
@property (readonly, nonatomic) NSString *speedDescription;

/// Whether the last speed change could not be applied to the running emulator,
/// so the CPU panel should offer to restart the session. NO when there is
/// nothing to apply it to yet.
@property (readonly, nonatomic) BOOL speedChangeNeedsRestart;

/// Whether the CPU is in dynamic core mode
@property (assign, nonatomic, getter=isDynamic) BOOL dynamic;


/// The current playback mode: paused or playing. Used for UI bindings.
@property (assign, nonatomic) BXPlaybackMode playbackMode;

/// The title to use for the "Player Data" submenu in the File menu when this session is active.
@property (readonly, nonatomic) NSString *playerDataMenuLabel;

#pragma mark -
#pragma mark Class methods

/// Returns the increment the slider should use within the band the given speed
/// falls into. increasing affects which band a speed exactly on a threshold
/// belongs to.
+ (NSInteger) incrementAmountForSpeed: (NSInteger)speed goingUp: (BOOL)increasing;

/// Returns a speed snapped to the increment for its band.
+ (NSInteger) snappedSpeed: (NSInteger)rawSpeed;

/// Returns a localised format string describing the CPU class (AT, 386,
/// Pentium...) corresponding to the specified speed.
+ (NSString *) cpuClassFormatForSpeed: (NSInteger)speed;

/// Returns a version of the above pre-formatted with the specified speed.
+ (NSString *) descriptionForSpeed: (NSInteger)speed;


#pragma mark -
#pragma mark Interface actions and validation

/// Pause/unpause the emulation. Will show a paused/unpaused bezel notification.
- (IBAction) togglePaused: (id)sender;

/// Pause the emulation if it was not already paused. Will show a paused bezel
/// notification if the emulation was previously running, otherwise will have no effect.
- (IBAction) pause: (id)sender;

/// Resume the emulation if it was paused. Will show an unpaused bezel notification
/// if the emulation was previously paused, otherwise will have no effect.
- (IBAction) resume: (id)sender;

/// Caps the speed within minimum and maximum limits.
- (BOOL) validateCPUSpeed: (NSNumber **)ioValue error: (NSError **)outError;

/// Snaps the speed to set increments, and switches to maximum above the top of
/// the slider's range.
- (BOOL) validateSliderSpeed: (NSNumber **)ioValue error: (NSError **)outError;

/// Paste data from the clipboard into the DOS session.
- (IBAction) paste: (id)sender;

/// Whether we can accept pasted data from the specified pasteboard.
- (BOOL) canPasteFromPasteboard: (NSPasteboard *)pboard;

/// Save a screenshot to the desktop.
- (IBAction) saveScreenshot: (id)sender;


/// Cycle forward/backward through all drive queues.
- (IBAction) mountNextDrivesInQueues: (id)sender;
- (IBAction) mountPreviousDrivesInQueues: (id)sender;

/// Cycle all mounted drives to their next queued images. Triggered by Cmd+F4 keyboard shortcut.
- (IBAction) cycleMountedDiscsForward: (id)sender;

/// Whether we have any drive queues that can be cycled. Used for UI bindings.
- (BOOL) canCycleDrivesInQueues;

/// Discard/merge the current game data.
/// The game be relaunched after the operation is complete.
- (IBAction) revertShadowedChanges: (id)sender;
- (IBAction) mergeShadowedChanges: (id)sender;

/// Import/export the current game data.
/// The game will be relaunched after importing is complete.
- (IBAction) importGameState: (id)sender;
- (IBAction) exportGameState: (id)sender;

/// Restart the emulation by closing and reopening the document.
/// This will show a confirmation first if there are programs running or drives being imported.
- (IBAction) performRestart: (id)sender;
- (IBAction) performRestartAtLaunchPanel: (id)sender;


#pragma mark - Documentation

- (IBAction) showDocumentationBrowser: (id)sender;
- (IBAction) hideDocumentationBrowser: (id)sender;
- (IBAction) toggleDocumentationBrowser: (id)sender;


#pragma mark - Responding to UI changes

/// Called when the user has manually changed the state of the program panel.
/// This records the state of the program panel to use next time the user starts up this gamebox.
- (void) userDidToggleProgramPanel;

/// Called when the user has manually toggled full screen mode.
/// This records the fullscreen/windowed to use next time the user starts up this gamebox.
- (void) userDidToggleFullScreen;

/// Called when the user manually switches from/to the launch panel to/from the DOS prompt.
- (void) userDidToggleLaunchPanel;

/// Called when the mouse is locked or unlocked from the window. Hides/re-shows subsidiary windows.
- (void) didToggleMouseLocked;

@end
