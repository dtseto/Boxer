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

/// Whether the CPU is in dynamic core mode
@property (assign, nonatomic, getter=isDynamic) BOOL dynamic;


/// The current playback mode: paused or playing. Used for UI bindings.
@property (assign, nonatomic) BXPlaybackMode playbackMode;

/// The title to use for the "Player Data" submenu in the File menu when this session is active.
@property (readonly, nonatomic) NSString *playerDataMenuLabel;

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
