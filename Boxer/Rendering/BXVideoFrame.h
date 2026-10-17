/* 
 Copyright (c) 2013 Alun Bestor and contributors. All rights reserved.
 This source file is released under the GNU General Public License 2.0. A full copy of this license
 can be found in this XCode project at Resources/English.lproj/BoxerHelp/pages/legalese.html, or read
 online at [http://www.gnu.org/licenses/gpl-2.0.txt].
 */


#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <stdatomic.h>

/// The standard 4:3 aspect ratio of old displays
extern const CGFloat BX4by3AspectRatio; 

/// Aspect ratios with a difference smaller than this will be considered equivalent
#define BXIdenticalAspectRatioDelta	0.025f

/// The maximum number of regions that can be flagged as dirty.
/// This is set to the maximum vertical resolution expected from a DOS game.
#define MAX_DIRTY_REGIONS 1024

typedef NS_ENUM(int, BXVideoFramePresentationState) {
    BXVideoFramePresentationStateFree = 0,
    BXVideoFramePresentationStateRendering = 1,
    BXVideoFramePresentationStateReady = 2,
    BXVideoFramePresentationStatePresenting = 3,
    BXVideoFramePresentationStateCommitted = 4
};

/// @brief BXVideoFrame is a renderer-agnostic framebuffer for DOSBox to draw frames into.
///
/// @discussion It keeps track of the frame's resolution, bit depth and intended
/// display scale.
@interface BXVideoFrame : NSObject
{
	NSMutableData *_frameData;
	NSSize _size;
	NSSize _baseResolution;
	NSUInteger _bytesPerPixel;
	NSSize _intendedScale;
    BOOL _containsText;
    
    NSRange _dirtyRegions[MAX_DIRTY_REGIONS];
    NSUInteger _numDirtyRegions;
    
	NSTimeInterval _timestamp;

	/// Presentation ownership is managed with C11 atomics so the producer,
	/// main thread, and Metal completion handler can exchange this frame
	/// without a lock.
	_Atomic(int) _presentationState;

	/// The source texture owned by this frame slot. It is reused only when the
	/// slot is free and its dimensions and format still match.
	id<MTLTexture> _texture;

	/// Dirty regions captured from Staging before its dirtyBlocks pointer
	/// becomes invalid. They are applied to the public dirty-region list on
	/// the main thread before presentation.
	NSRange _pendingDirtyRegions[MAX_DIRTY_REGIONS];
	NSUInteger _numPendingDirtyRegions;
}

#pragma mark -
#pragma mark Properties

/// The size of the video frame in pixels.
@property (readonly) NSSize size;

/// The number of bytes per pixel. The total size in bytes of the frame
/// is bytesPerPixel * size.width * size.height.
@property (readonly) NSUInteger bytesPerPixel;

/// The width in bytes of one scanline in the buffer.
/// This is equal to size.width * bytesPerPixel.
@property (readonly) NSUInteger pitch;

/// The original game resolution represented by the frame.
/// This may not be the correspond to the pixel size, if DOSBox is applying its own scaling.
@property (assign) NSSize baseResolution;

/// The scaling factor to apply to the frame to reach the desired aspect ratio.
@property (assign) NSSize intendedScale;

/// The size of the frame with aspect ratio correction applied (i.e. scaled by intendedScale.)
@property (readonly) NSSize scaledSize;

/// The base resolution corrected to the same aspect ratio as the pixel size:
/// e.g. a 640x200 frame is intended to be doubled vertically, for an effective
/// resolution of 640x400. (Note that this stretching is distinct from intendedScale,
/// which applies aspect ratio correction to e.g. stretch 640x400 to 640x480.)
@property (readonly) NSSize effectiveResolution;

/// The effective resolution of the frame with full aspect ratio correction applied.
@property (readonly) NSSize scaledResolution;

/// Whether the framebuffer is a text-mode frame. Provided by the emulator as a
/// scaling/aspect-ratio hint for downstream consumers. 
@property (assign) BOOL containsText;

/// The absolute time which this frame represents. Updated each time a frame update is completed by the emulator.
@property (assign) CFAbsoluteTime timestamp;

/// Read-only/mutable pointers to the frame's data.
@property (readonly) NSMutableData *frameData;
@property (readonly) const void *bytes NS_RETURNS_INNER_POINTER;
@property (readonly) void *mutableBytes NS_RETURNS_INNER_POINTER;

/// The number of ranges of dirty lines. Incremented by setNeedsDisplayInRegion:
/// and reset to 0 by clearDirtyRegions. See the dirty region functions below.
@property (readonly, assign) NSUInteger numDirtyRegions;

@property (nonatomic, strong) id<MTLTexture> texture;


#pragma mark -
#pragma mark Class helpers

/// Returns the scaling factor necessary to translate the specified size
/// to match the specified aspect ratio
+ (NSSize) scalingFactorForSize: (NSSize)frameSize toAspectRatio: (CGFloat)aspectRatio;

#pragma mark -
#pragma mark Initializers

+ (instancetype) frameWithSize: (NSSize)targetSize depth: (NSUInteger)depth;
- (instancetype) initWithSize: (NSSize)targetSize depth: (NSUInteger)depth;

/// Creates a frame with a preallocated pixel capacity and an initial logical size.
- (instancetype) initWithCapacitySize: (NSSize)capacitySize
					logicalSize: (NSSize)logicalSize
						 depth: (NSUInteger)depth;

/// Changes the logical framebuffer size without reallocating, provided it fits
/// within the capacity used at initialization.
- (BOOL) configureForLogicalSize: (NSSize)logicalSize;


#pragma mark -
#pragma mark Methods

/// Sets the frame to use the specified intended aspect ratio.
/// This does not affect the underlying image data, just the intended scaled size and resolution.
- (void) useAspectRatio: (CGFloat)aspectRatio;

/// Resets the aspect ratio of the frame to use unscaled square pixels.
- (void) useSquarePixels;


#pragma mark -
#pragma mark Flagging scanlines of the frame as dirty.

- (void) setNeedsDisplayInRegion: (NSRange)range;
- (void) clearDirtyRegions;

- (NSRange) dirtyRegionAtIndex: (NSUInteger)region;

/// Captures Staging's transient dirty-block array synchronously.
- (void) captureDirtyBlocks: (const uint16_t *)dirtyBlocks;

/// Rebuilds the public dirty-region list on the main thread.
- (void) applyPendingDirtyRegions;

/// Lock-free frame ownership transitions used by the adapter.
- (BOOL) tryBeginRendering;
- (BOOL) publishForPresentation;
- (BOOL) tryBeginPresentation;
- (BOOL) markCommitted;
- (BOOL) discardIfReady;
- (BOOL) finishUncommittedPresentation;
- (BOOL) finishCommittedPresentation;
- (BOOL) isFree;
- (int) presentationState;

@end
