/*
 Copyright (c) 2013 Alun Bestor and contributors. All rights reserved.
 This source file is released under the GNU General Public License 2.0. A full copy of this license
 can be found in this XCode project at Resources/English.lproj/BoxerHelp/pages/legalese.html, or read
 online at [http://www.gnu.org/licenses/gpl-2.0.txt].
 */

//Private API for use by BXEmulatedJoystick subclasses

#import "BXEmulatedJoystick.h"
#import "ADBHIDEvent.h"
#import <math.h>
#import "dosbox_config.h"
#import "misc/types.h"
#import "hardware/input/joystick.h"


enum
{
	BXGameportStick1,
	BXGameportStick2
};

enum
{	
	BXGameportButton1,
	BXGameportButton2
};

typedef NS_ENUM(NSUInteger, BXGameportAxis)
{	
	BXGameportXAxis,
	BXGameportYAxis,
	BXGameportX2Axis,
	BXGameportY2Axis,
    
    BXWheelWheelAxis            = BXGameportXAxis,
    BXWheelCombinedPedalAxis    = BXGameportYAxis,
    BXWheelAcceleratorAxis      = BXGameportX2Axis,
    BXWheelBrakeAxis            = BXGameportY2Axis
};


typedef NS_OPTIONS(NSUInteger, BXGameportButtonMask)
{
	BXNoGameportButtonsMask = 0,
	BXGameportButton1Mask = 1U << 0,
	BXGameportButton2Mask = 1U << 1,
	BXGameportButton3Mask = 1U << 2,
	BXGameportButton4Mask = 1U << 3,
	BXAllGameportButtonsMask = BXGameportButton1Mask | BXGameportButton2Mask | BXGameportButton3Mask | BXGameportButton4Mask
};


#define BXGameportAxisMin -1.0f
#define BXGameportAxisMax 1.0f
#define BXGameportAxisCentered 0.0f


/// Converts one of our -1.0...+1.0 axis positions into the raw SDL axis value
/// that DOSBox's gameport takes. **Every** call to JOYSTICK_Move_X/Y must go
/// through this.
///
/// IMPLEMENTATION NOTE: this scaling is the whole of D64, and its absence was
/// the joystick regression. Boxer was written against DOSBox 0.74, whose
/// JOYSTICK_Move_X/Y took a float from -1.0 to +1.0, and it passed its own axis
/// positions straight through. DOSBox Staging changed those to take an int16_t
/// from -32768 to 32767 (upstream 27d403aeb, "Use SDL's native joystick axis
/// values in function arguments") and these call sites were never updated, so
/// the float was converted by truncation: every axis arrived as 0, or at full
/// deflection as +/-1, out of +/-32767. The gameport never left centre.
///
/// The bounds are asymmetric because DOSBox's own position_to_percent() is: it
/// divides by 32767 for positive values and 32768 for negative ones. Scaling
/// this way makes us its exact inverse, and therefore the inverse of
/// -positionForGameportAxis: too -- that one needs no conversion, since
/// JOYSTICK_GetMove_X/Y already return a double from -1.0 to +1.0.
static inline int16_t BXGameportAxisValueForPosition(float position)
{
	const float clamped = fmaxf(fminf(position, BXGameportAxisMax), BXGameportAxisMin);
	const float scale = (clamped < 0.0f) ? 32768.0f : 32767.0f;
	return (int16_t)lroundf(clamped * scale);
}



#pragma mark -
#pragma mark Private method declarations

@interface BXBaseEmulatedJoystick ()

/// The pressed/released state of all emulated buttons
@property (assign) BXGameportButtonMask pressedButtons;

/// Process the press/release of a joystick button.
- (void) setButton: (BXEmulatedJoystickButton)button
           toState: (BOOL)pressed;

/// Called by buttonPressed: after a delay to release the pressed button.
- (void) releaseButton: (NSNumber *)button;

/// A helper method for normalizing an 8-way POV direction to the closest cardinal (NSEW) BXEmulatedPOVDirection
/// constant, taking into account which cardinal POV direction it was in before. This makes the corners 'sticky',
/// so that e.g. N to NE will return N, while E to NE will return E. This reduces unintentional switching.
+ (BXEmulatedPOVDirection) closest4WayDirectionForPOV: (BXEmulatedPOVDirection)direction
                                          previousPOV: (BXEmulatedPOVDirection)oldDirection;

/// Move the specified axis to the specified position.
- (void) setPosition: (float)position forGameportAxis: (BXGameportAxis)axis;
- (float) positionForGameportAxis: (BXGameportAxis)axis;

@end

