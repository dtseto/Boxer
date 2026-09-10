/* 
 Copyright (c) 2013 Alun Bestor and contributors. All rights reserved.
 This source file is released under the GNU General Public License 2.0. A full copy of this license
 can be found in this XCode project at Resources/English.lproj/BoxerHelp/pages/legalese.html, or read
 online at [http://www.gnu.org/licenses/gpl-2.0.txt].
 */


#import "BXEmulatedMouse.h"

#import "dosbox_config.h"
#import "misc/video.h"
#import "hardware/input/mouse.h"
#import "BXCoalface.h"   // boxer_notifyMouseScreenParams()


#pragma mark -
#pragma mark Private method declarations

@interface BXEmulatedMouse ()
@property (readwrite, assign) BXMouseButtonMask pressedButtons;

- (void) setButton: (BXMouseButton)button toState: (BOOL)pressed;
- (void) releaseButton: (NSNumber *)button;

@end


#pragma mark -
#pragma mark Implementation

@implementation BXEmulatedMouse
{
	NSTimeInterval _lastButtonDown[BXMouseButtonMax];

	/// The canvas size last reported to DOSBox's mouse subsystem, so that a
	/// resize is passed on but an unchanged canvas is not re-sent on every move.
	NSSize _lastReportedCanvasSize;
}

- (id) init
{
	if ((self = [super init]))
	{
		_active			= NO;
		_position		= NSMakePoint(0.5f, 0.5f);
		_pressedButtons	= BXNoMouseButtonsMask;
        
        _lastButtonDown[BXMouseButtonLeft] = 0;
        _lastButtonDown[BXMouseButtonRight] = 0;
        _lastButtonDown[BXMouseButtonMiddle] = 0;
	}
	return self;
}

#pragma mark -
#pragma mark Controlling response state

- (void) clearInput
{
	[self buttonUp: BXMouseButtonLeft];
	[self buttonUp: BXMouseButtonRight];
	[self buttonUp: BXMouseButtonMiddle];
}

- (void) setActive: (BOOL)flag
{
	if (_active != flag)
	{
		//If mouse support is disabled while we still have mouse buttons pressed,
		//then release those buttons before continuing.
		if (!flag) [self clearInput];
		
		_active = flag;
	}
}

- (void) movedTo: (NSPoint)point
			  by: (NSPoint)delta
		onCanvas: (NSRect)canvas
	 whileLocked: (BOOL)locked
{
	if (self.isActive)
	{
		//Boxer reports both the position and the delta normalised to the canvas;
		//DOSBox wants them in canvas coordinates.
		NSPoint canvasDelta = NSMakePoint(delta.x * canvas.size.width,
										  delta.y * canvas.size.height);

		//The absolute position has to be in the same coordinate space as the
		//draw rectangle handed to MOUSE_NewScreenParams(), i.e. canvas points.
		//Up to 0.78 DOSBox took a 0.0-to-1.0 position here and scaled it
		//itself; 0.83 does not, and passing a normalised value made every
		//position clamp to the top-left corner -- which
		//update_cursor_absolute_position() reads as "the cursor is outside the
		//window", so the DOS cursor never moved.
		NSPoint canvasPoint = NSMakePoint(point.x * canvas.size.width,
										  point.y * canvas.size.height);

		//Keep the mouse subsystem's idea of the canvas up to date: it is where
		//the DOS driver's maximum cursor position comes from, and the window
		//can be resized at any time. Cheap, and idempotent when unchanged.
		if (!NSEqualSizes(canvas.size, _lastReportedCanvasSize))
		{
			_lastReportedCanvasSize = canvas.size;
			boxer_notifyMouseScreenParams((float)canvas.size.width,
			                              (float)canvas.size.height,
			                              (float)canvasPoint.x,
			                              (float)canvasPoint.y);
		}

        // 0.83 renamed this and dropped the trailing 'locked' argument: whether
        // the pointer is captured is now tracked by the mouse subsystem itself
        // (GFX_SetMouseCapture), not passed in per event.
        MOUSE_EventMoved(canvasDelta.x,
                         canvasDelta.y,
                         canvasPoint.x,
                         canvasPoint.y);
	}
}

- (void) setButton: (BXMouseButton)button
		   toState: (BOOL)pressed
{
    NSAssert1(button < BXMouseButtonMax,
              @"Invalid mouse button number %ld passed to setButton:toState:", (long)button);
    
	//Ignore button presses while we're inactive
	if (!self.isActive) return;
	
	BXMouseButtonMask buttonMask = 1U << button;

    //Whether or not we actually need to toggle the button,
    //cancel any pending button release in response.
    [NSObject cancelPreviousPerformRequestsWithTarget: self
                                             selector: @selector(releaseButton:)
                                               object: @(button)];
    
    //If we do actually need to toggle the button, then update DOSBox's state
	if ([self buttonIsDown: button] != pressed)
	{
		if (pressed)
		{
			MOUSE_EventButton((MouseButtonId)button, true);
            self.pressedButtons |= buttonMask;
            
            _lastButtonDown[button] = [NSDate timeIntervalSinceReferenceDate];
		}
        else
        {
            //Check how long the button was held down before releasing.
            //If it's been soon enough that the game may not have had time
            //to register the press, then hold the release until our minimum
            //duration is up.
            
            //This fixes games that poll the current state of the mouse
            //instead of looking at the mouse event queue, and so which may
            //overlook very quick clicks like those generated by touchpads.
            
            NSTimeInterval buttonPressDuration = [NSDate timeIntervalSinceReferenceDate] - _lastButtonDown[button];
            NSTimeInterval durationRemaining = BXMouseButtonPressDurationMinimum - buttonPressDuration;
            
            if (durationRemaining > 0)
            {
                [self performSelector: @selector(releaseButton:)
                           withObject: @(button)
                           afterDelay: durationRemaining];
            }
            else
            {
                MOUSE_EventButton((MouseButtonId)button, false);
                self.pressedButtons &= ~buttonMask;
                
                _lastButtonDown[button] = 0;
            }
        }
	}
}

- (void) buttonDown: (BXMouseButton)button
{
	[self setButton: button toState: YES];
}

- (void) buttonUp: (BXMouseButton)button
{
	[self setButton: button toState: NO];
}

- (BOOL) buttonIsDown: (BXMouseButton)button
{
    NSAssert1(button < BXMouseButtonMax,
              @"Invalid mouse button number %ld passed to setButton:toState:", (long)button);
    
	NSUInteger buttonMask = 1U << button;
	
	return (self.pressedButtons & buttonMask) == buttonMask;
}


- (void) buttonPressed: (BXMouseButton)button
{
	[self buttonPressed: button forDuration: BXMouseButtonPressDurationDefault];
}

- (void) buttonPressed: (BXMouseButton)button forDuration: (NSTimeInterval)duration
{
	[self buttonDown: button];
	
	[self performSelector: @selector(releaseButton:)
			   withObject: @(button)
			   afterDelay: duration];
}

- (void) releaseButton: (NSNumber *)button
{
	[self buttonUp: (BXMouseButton)button.unsignedIntegerValue];
}

@end
