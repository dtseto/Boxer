//
//  BXIntegerScaling.m
//  Boxer
//

#import "BXIntegerScaling.h"
#import <math.h>

static BXIntegerScaleResult BXFullDrawableResult(CGSize drawableSize)
{
    BXIntegerScaleResult result = {0};
    result.viewport = (MTLViewport){
        .originX = 0.0,
        .originY = 0.0,
        .width = drawableSize.width,
        .height = drawableSize.height,
        .znear = 0.0,
        .zfar = 1.0,
    };
    result.scaledSize = drawableSize;
    result.origin = CGPointZero;
    return result;
}

BXIntegerScaleResult BXCalculateIntegerScale(CGSize sourceSize,
                                             CGSize drawableSize,
                                             BXIntegerScalingMode mode)
{
    if (sourceSize.width <= 0.0 || sourceSize.height <= 0.0 ||
        drawableSize.width <= 0.0 || drawableSize.height <= 0.0 ||
        mode == BXIntegerScalingModeOff) {
        return BXFullDrawableResult(drawableSize);
    }

    double horizontalScale = drawableSize.width / sourceSize.width;
    double verticalScale = drawableSize.height / sourceSize.height;
    double scaleFactor;

    switch (mode) {
        case BXIntegerScalingModeVertical:
            scaleFactor = floor(verticalScale);
            break;
        case BXIntegerScalingModeHorizontal:
            scaleFactor = floor(horizontalScale);
            break;
        case BXIntegerScalingModeAuto: {
            // Auto is a vertical CRT mode. Keep whole-number factors by
            // default, but permit the two DOSBox Staging half-steps that
            // preserve more screen area while keeping scanlines regular.
            if (verticalScale > 5.0) {
                return BXFullDrawableResult(drawableSize);
            }

            scaleFactor = floor(verticalScale);
            if (scaleFactor >= 3.0 && scaleFactor < 5.0 &&
                verticalScale - scaleFactor >= 0.5) {
                scaleFactor += 0.5;
            }
            break;
        }
        default:
            scaleFactor = floor(fmin(horizontalScale, verticalScale));
            break;
    }

    scaleFactor = MAX(scaleFactor, 1.0);

    CGSize scaledSize = CGSizeMake(sourceSize.width * scaleFactor,
                                   sourceSize.height * scaleFactor);

    // The selected axis is constrained, but the viewport must still contain
    // the complete aspect-corrected image. If it does not fit, disable the
    // constraint just as DOSBox Staging does.
    if (scaledSize.width > drawableSize.width || scaledSize.height > drawableSize.height) {
        return BXFullDrawableResult(drawableSize);
    }

    CGPoint origin = CGPointMake(floor((drawableSize.width - scaledSize.width) / 2.0),
                                 floor((drawableSize.height - scaledSize.height) / 2.0));

    BXIntegerScaleResult result = {0};
    result.viewport = (MTLViewport){
        .originX = origin.x,
        .originY = origin.y,
        .width = scaledSize.width,
        .height = scaledSize.height,
        .znear = 0.0,
        .zfar = 1.0,
    };
    result.scaleFactor = scaleFactor;
    result.scaledSize = scaledSize;
    result.origin = origin;
    return result;
}

BOOL BXIntegerScaleIsTooSmall(CGSize sourceSize, CGSize drawableSize, NSUInteger minimumScale)
{
    if (sourceSize.height <= 0.0 || drawableSize.height <= 0.0) {
        return YES;
    }
    return floor(drawableSize.height / sourceSize.height) < minimumScale;
}
