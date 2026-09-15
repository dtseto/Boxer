/* 
 Copyright (c) 2013 Alun Bestor and contributors. All rights reserved.
 This source file is released under the GNU General Public License 2.0. A full copy of this license
 can be found in this XCode project at Resources/English.lproj/BoxerHelp/pages/legalese.html, or read
 online at [http://www.gnu.org/licenses/gpl-2.0.txt].
 */


#import "BXVideoHandler.h"
#import "BXEmulatorPrivate.h"
#import "BXVideoFrame.h"
#import "ADBGeometry.h"

#import "gui/render/render.h"
#import "hardware/video/vga.h"


#pragma mark -
#pragma mark Really genuinely private functions

@interface BXVideoHandler ()

- (void) _syncHerculesTint;
- (void) _syncCGAHueAdjustment;
- (void) _syncCGAComposite;

@end


@implementation BXVideoHandler
@synthesize currentFrame = _currentFrame;
@synthesize emulator = _emulator;
@synthesize herculesTint = _herculesTint;
@synthesize CGAHueAdjustment = _CGAHueAdjustment;

- (id) init
{
    self = [super init];
	if (self)
	{
		_currentVideoMode = M_TEXT;
        _herculesTint = BXHerculesWhiteTint;
        _CGAComposite = BXCGACompositeAuto;
        _CGAHueAdjustment = 0.0;
	}
	return self;
}

- (NSSize) resolution
{
	NSSize size = NSZeroSize;
	if (self.emulator.isExecuting)
	{
		size.width	= (CGFloat)render.src.width;
		size.height	= (CGFloat)render.src.height;
	}
	return size;
}

//Returns whether the emulator is currently rendering in a text-only graphics mode.
- (BOOL) isInTextMode
{
	BOOL textMode = NO;
	if (self.emulator.isExecuting)
	{
		switch (_currentVideoMode)
		{
			case M_TEXT:
            case M_TANDY_TEXT:
            case M_HERC_TEXT:
                textMode = YES;
		}
	}
	return textMode;
}

+ (NSSet *) keyPathsForValuesAffectingInHerculesMode
{
    return [NSSet setWithObject: @"emulator.initialized"];
}

- (BOOL) isInHerculesMode
{
    if (self.emulator.isInitialized)
    {
        return (is_machine_hercules());
    }
    else
    {
        return NO;
    }
}

+ (NSSet *) keyPathsForValuesAffectingInCGAMode
{
    return [NSSet setWithObject: @"emulator.initialized"];
}

- (BOOL) isInCGAMode
{
    if (self.emulator.isInitialized)
        return (is_machine_cga());
    else return NO;
}

- (void) setHerculesTint: (BXHerculesTintMode)tint
{
    if (tint != _herculesTint)
    {
        _herculesTint = tint;
        [self _syncHerculesTint];
    }
}

- (void) _syncHerculesTint
{
    if (self.emulator.isInitialized)
    {
        boxer_setHerculesTintMode((uint8_t)self.herculesTint);
    }
}

@synthesize CGAComposite=_CGAComposite;

- (void)setCGAComposite:(BXCGACompositeMode)composite
{
    _CGAComposite = composite;
    [self _syncCGAComposite];
}

- (void) _syncCGAComposite
{
    if (self.emulator.isInitialized)
    {
        boxer_setCGAComponentMode((uint8_t)self.CGAComposite);
    }
}

- (void) setCGAHueAdjustment: (double)hue
{
    _CGAHueAdjustment = hue;
    [self _syncCGAHueAdjustment];
}

- (void) _syncCGAHueAdjustment
{
    if (self.emulator.isInitialized)
    {
        boxer_setCGACompositeHueOffset(self.CGAHueAdjustment);
    }
}


//Reinitialises DOSBox's graphical subsystem and redraws the render region.
//This is called after resizing the session window or toggling rendering options.
- (void) reset
{
	if (self.emulator.isInitialized)
	{
        if (self.emulator.emulationThread != [NSThread currentThread])
        {
            [self performSelector: _cmd
                         onThread: self.emulator.emulationThread
                       withObject: nil
                    waitUntilDone: NO];
        }
        else
        {
            if (_frameInProgress) [self finishFrame];
            
            if (_callback) _callback(GFX_CallbackReset);
            //CPU_Reset_AutoAdjust();
        }
	}
}

- (void) shutdown
{
	[self finishFrame];
	if (_callback) _callback(GFX_CallbackStop);
}


#pragma mark -
#pragma mark DOSBox callbacks

- (void) prepareForOutputSize: (NSSize)outputSize
             pixelAspectRatio: (CGFloat)pixelAspectRatio
                 withCallback: (GFX_Callback_t)newCallback
{
	//Synchronise our record of the current video mode with the new video mode
	BOOL wasTextMode = self.isInTextMode;
	if (_currentVideoMode != vga.mode)
	{
		[self willChangeValueForKey: @"inTextMode"];
		_currentVideoMode = vga.mode;
		[self didChangeValueForKey: @"inTextMode"];
	}
	BOOL nowTextMode = self.isInTextMode;
	
	//If we were in the middle of a frame then cancel it
	_frameInProgress = NO;
	
	_callback = newCallback;
	
	//Check if we can reuse our existing framebuffer: if not, create a new one
	if (!NSEqualSizes(outputSize, self.currentFrame.size))
	{
        self.currentFrame = [BXVideoFrame frameWithSize: outputSize depth: 4];
	}
	
    self.currentFrame.baseResolution = self.resolution;
    self.currentFrame.containsText = nowTextMode;
    self.currentFrame.pixelAspectRatio = pixelAspectRatio;
	
	//Send notifications if the display mode has changed
	
	if (wasTextMode && !nowTextMode)
		[self.emulator _postNotificationName: BXEmulatorDidBeginGraphicalContextNotification
                            delegateSelector: @selector(emulatorDidBeginGraphicalContext:)
                                    userInfo: nil];
	
	else if (!wasTextMode && nowTextMode)
		[self.emulator _postNotificationName: BXEmulatorDidFinishGraphicalContextNotification
                            delegateSelector: @selector(emulatorDidFinishGraphicalContext:)
                                    userInfo: nil];
}

- (BOOL) startFrameWithBuffer: (void **)buffer pitch: (int *)pitch
{
	if (_frameInProgress) 
	{
		NSLog(@"Tried to start a new frame while one was still in progress!");
		return NO;
	}
	
	if (!self.currentFrame)
	{
		NSLog(@"Tried to start a frame before any framebuffer was created!");
		return NO;
	}
	
	*buffer	= self.currentFrame.mutableBytes;
    *pitch	= (int)self.currentFrame.pitch;
	
	_frameInProgress = YES;
	return YES;
}

- (void) finishFrame
{
	if (self.currentFrame)
	{
        // Up to 0.78 DOSBox handed us an array of alternating clean/dirty line
        // counts here. 0.83's render pipeline no longer tracks which lines
        // changed -- RENDER_EndUpdate calls GFX_EndUpdate() with no arguments --
        // so every frame is published whole. Nothing ever consumed the dirty
        // regions anyway: Boxer's renderer has always uploaded the entire frame,
        // and BXVideoFrame's dirty-region API has now been deleted. See D21.
        self.currentFrame.timestamp = CFAbsoluteTimeGetCurrent();
        [self.emulator _didFinishFrame: self.currentFrame];
	}
    
	_frameInProgress = NO;
}

- (NSUInteger) paletteEntryWithRed: (NSUInteger)red
							 green: (NSUInteger)green
							  blue: (NSUInteger)blue;
{
	//Copypasta straight from sdlmain.cpp.
	return ((blue << 0) | (green << 8) | (red << 16)) | (255U << 24);
}


@end
