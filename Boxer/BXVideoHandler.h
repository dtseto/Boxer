/* 
 Copyright (c) 2013 Alun Bestor and contributors. All rights reserved.
 This source file is released under the GNU General Public License 2.0. A full copy of this license
 can be found in this XCode project at Resources/English.lproj/BoxerHelp/pages/legalese.html, or read
 online at [http://www.gnu.org/licenses/gpl-2.0.txt].
 */


//BXVideoHandler manages DOSBox's video and renderer state. Very little of its interface is
//exposed to Boxer's high-level Cocoa classes.

#import <Foundation/Foundation.h>

#if __cplusplus
#import "dosbox_config.h"
#import "misc/video.h"

// GFX_Callback_t used to come from video.h; at 0.83 it lives in
// gui/private/common.h alongside the rest of the frontend interface. That
// header is "private" only in the sense that upstream's own frontend is its
// only consumer -- Boxer *is* that frontend now, so it includes it directly
// rather than mirroring the type.
#import "gui/private/common.h"
#import "BXCoalface.h"
#endif

typedef NS_ENUM(uint8_t, BXHerculesTintMode) {
    BXHerculesWhiteTint = 0,
    BXHerculesAmberTint = 1,
    BXHerculesGreenTint = 2,
};

typedef NS_ENUM(uint8_t, BXCGACompositeMode) {
    BXCGACompositeAuto = 0,
    BXCGACompositeOn = 1,
    BXCGACompositeOff = 2,
};



@class BXEmulator;
@class BXVideoFrame;

/// BXVideoHandler manages DOSBox's video and renderer state. Very little of its interface is
/// exposed to Boxer's high-level Cocoa classes.
@interface BXVideoHandler : NSObject
{
	__unsafe_unretained BXEmulator *_emulator;
	BXVideoFrame *_currentFrame;
	
	NSInteger _currentVideoMode;
	BOOL _frameInProgress;
    
    BXHerculesTintMode _herculesTint;
    BXCGACompositeMode _CGAComposite;
    double _CGAHueAdjustment;
	
#if __cplusplus
	/// This is a C++ function pointer and should never be seen by Obj-C classes
	GFX_Callback_t _callback;
#endif
}

#pragma mark -
#pragma mark Properties

/// Our parent emulator.
@property (assign, nonatomic) BXEmulator *emulator;

/// The framebuffer we render our frames into.
@property (strong, nonatomic) BXVideoFrame *currentFrame;

@property (assign, nonatomic) BXHerculesTintMode herculesTint;
@property (assign, nonatomic) BXCGACompositeMode CGAComposite;
@property (assign, nonatomic) double CGAHueAdjustment;

/// Whether the emulator is currently rendering in a text-only mode.
@property (readonly, getter=isInTextMode) BOOL inTextMode;

/// Whether the emulator is in Hercules/CGA mode.
@property (readonly, getter=isInHerculesMode) BOOL inHerculesMode;
@property (readonly, getter=isInCGAMode) BOOL inCGAMode;

/// Returns the base resolution the DOS game is producing.
@property (readonly) NSSize resolution;


#pragma mark -
#pragma mark Control methods

/// Stops any rendering in progress and reinitialises DOSBox's graphical subsystem.
- (void) reset;

@end


#if __cplusplus

#pragma mark -
#pragma mark Almost-private functions

/// Functions in this interface should not be called outside of BXEmulator and BXCoalface.
@interface BXVideoHandler (/*BXVideoHandlerInternals*/)

/// Called by BXEmulator to prepare the renderer for shutdown.
- (void) shutdown;

/// Converts an RGB value into a BGRA palette entry. Called from
/// BoxerRenderBackend::MakePixel().
- (NSUInteger) paletteEntryWithRed: (NSUInteger)red
							 green: (NSUInteger)green
							  blue: (NSUInteger)blue;

/// Called from BoxerRenderBackend::NotifyRenderSizeChanged(). The scale
/// argument the 0.78 hook carried is gone: DOSBox's own scalers went with it,
/// and Boxer never read it.
- (void) prepareForOutputSize: (NSSize)outputSize
				 withCallback: (GFX_Callback_t)newCallback;

- (BOOL) startFrameWithBuffer: (void **)frameBuffer pitch: (int *)pitch;

/// Called from BoxerRenderBackend::EndFrame(). 0.83 removed dirty-rectangle
/// tracking from the render pipeline, so every frame is now published whole.
- (void) finishFrame;

@end

#endif
