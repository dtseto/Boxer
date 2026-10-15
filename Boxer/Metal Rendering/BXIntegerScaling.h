//
//  BXIntegerScaling.h
//  Boxer
//
//  Integer output scaling for the Metal renderer.
//

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, BXIntegerScalingMode) {
    BXIntegerScalingModeOff = 0,
    BXIntegerScalingModeAuto,
    BXIntegerScalingModeVertical,
    BXIntegerScalingModeHorizontal,
};

typedef struct {
    MTLViewport viewport;
    CGFloat scaleFactor;
    CGSize scaledSize;
    CGPoint origin;
} BXIntegerScaleResult;

/// Calculates a centered integer-scaled viewport in drawable pixels.
/// The source size should be the aspect-corrected output size used by the
/// renderer, not necessarily the raw emulator framebuffer size.
BXIntegerScaleResult BXCalculateIntegerScale(CGSize sourceSize,
                                             CGSize drawableSize,
                                             BXIntegerScalingMode mode);

/// Returns YES when the vertical integer scale is below the requested minimum.
BOOL BXIntegerScaleIsTooSmall(CGSize sourceSize, CGSize drawableSize, NSUInteger minimumScale);

NS_ASSUME_NONNULL_END
