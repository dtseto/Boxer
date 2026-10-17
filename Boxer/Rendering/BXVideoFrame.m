/* 
 Copyright (c) 2013 Alun Bestor and contributors. All rights reserved.
 This source file is released under the GNU General Public License 2.0. A full copy of this license
 can be found in this XCode project at Resources/English.lproj/BoxerHelp/pages/legalese.html, or read
 online at [http://www.gnu.org/licenses/gpl-2.0.txt].
 */


#import "BXVideoFrame.h"
#import "ADBGeometry.h"
#import "../BXVerificationInstrumentation.h"

const CGFloat BX4by3AspectRatio = (CGFloat)320.0 / (CGFloat)240.0;

@interface BXVideoFrame ()
@property (readwrite, assign) NSUInteger numDirtyRegions;
@end

@implementation BXVideoFrame
@synthesize frameData = _frameData;
@synthesize size = _size;
@synthesize baseResolution = _baseResolution;
@synthesize bytesPerPixel = _bytesPerPixel;
@synthesize intendedScale = _intendedScale;
@synthesize numDirtyRegions = _numDirtyRegions;
@synthesize containsText = _containsText;
@synthesize timestamp = _timestamp;
@synthesize texture = _texture;


+ (NSSize) scalingFactorForSize: (NSSize)frameSize toAspectRatio: (CGFloat)aspectRatio
{
	CGFloat frameAspectRatio = aspectRatioOfSize(frameSize);
	
	//If the frame isn't naturally 4:3, work out the necessary scale corrections to make it so
	if (ABS(aspectRatio - frameAspectRatio) > BXIdenticalAspectRatioDelta)
	{
		BOOL preserveHeight = (frameAspectRatio < aspectRatio);
		NSSize intendedSize = sizeToMatchRatio(frameSize, aspectRatio, preserveHeight);
		
		NSAssert1(!NSEqualSizes(intendedSize, NSZeroSize),
				  @"Invalid frame size passed to [BXFrameBuffer scalingFactorForSize:toAspectRatio:] %@", NSStringFromSize(frameSize));
		
		
		//Calculate the difference between the intended size and the real size, and that is our scaling multiplier!
		return NSMakeSize(intendedSize.width / frameSize.width,
						  intendedSize.height / frameSize.height);
	}
	//Otherwise, no corrections are required
	else return NSMakeSize(1, 1);
}


+ (id) frameWithSize: (NSSize)targetSize depth: (NSUInteger)depth
{
	return [[self alloc] initWithSize: targetSize depth: depth];
}

- (id) initWithSize: (NSSize)targetSize depth: (NSUInteger)depth
{
	return [self initWithCapacitySize: targetSize logicalSize: targetSize depth: depth];
}

- (instancetype) initWithCapacitySize: (NSSize)capacitySize
					logicalSize: (NSSize)logicalSize
						 depth: (NSUInteger)depth
{
	if ((self = [super init]))
	{
		_size			= logicalSize;
		_baseResolution	= logicalSize;
		_bytesPerPixel	= depth;
		_intendedScale	= NSMakeSize(1.0f, 1.0f);
		_numPendingDirtyRegions = 0;
		atomic_init(&_presentationState, 0);
		
		NSUInteger requiredLength = capacitySize.width * capacitySize.height * _bytesPerPixel;
		_frameData = [[NSMutableData alloc] initWithLength: requiredLength];
	}
	return self;
}

- (BOOL) configureForLogicalSize: (NSSize)logicalSize
{
	NSUInteger requiredLength = logicalSize.width * logicalSize.height * self.bytesPerPixel;
	if (requiredLength > self.frameData.length)
		return NO;

	_size = logicalSize;
	_baseResolution = logicalSize;
	_intendedScale = NSMakeSize(1.0f, 1.0f);
	return YES;
}

- (NSUInteger) pitch
{
	return self.size.width * self.bytesPerPixel;
}

- (void) useAspectRatio: (CGFloat)aspectRatio
{
	self.intendedScale = [self.class scalingFactorForSize: self.size
                                            toAspectRatio: aspectRatio];
}

- (void) useSquarePixels
{
    self.intendedScale = NSMakeSize(1, 1);
}

- (NSSize) scaledSize
{
	return NSMakeSize(round(self.size.width    * self.intendedScale.width),
					  round(self.size.height   * self.intendedScale.height));
}

//IMPLEMENTATION NOTE: sometimes the buffer size that DOSBox is using
//is already a different aspect ratio from the original resolution,
//e.g. if it is performing pixel pre-doubling to correct for wacky video modes.
//This provides an aspect-corrected version of that resolution.
- (NSSize) effectiveResolution
{
	CGFloat bufferRatio		= aspectRatioOfSize(self.size);
	CGFloat resolutionRatio	= aspectRatioOfSize(self.baseResolution);
	
	return sizeToMatchRatio(self.baseResolution, bufferRatio, resolutionRatio < bufferRatio);
}

- (NSSize) scaledResolution
{
	NSSize effectiveResolution = self.effectiveResolution;
	return NSMakeSize(round(effectiveResolution.width	* self.intendedScale.width),
					  round(effectiveResolution.height	* self.intendedScale.height));
}

- (const void *) bytes
{
	return _frameData.bytes;
}

- (void *) mutableBytes
{
	return _frameData.mutableBytes;
}

#pragma mark Region-dirtying

- (void) setNeedsDisplayInRegion: (NSRange)range
{
    NSAssert(self.numDirtyRegions < MAX_DIRTY_REGIONS,
             @"setNeedsDisplayInRegion: called when the list of dirty regions is already full.");
    
    NSUInteger nextIndex = self.numDirtyRegions;
    _dirtyRegions[nextIndex] = range;
    
    self.numDirtyRegions = nextIndex + 1;
}

- (void) captureDirtyBlocks: (const uint16_t *)dirtyBlocks
{
	_numPendingDirtyRegions = 0;
	if (!dirtyBlocks)
		return;

	NSUInteger currentOffset = 0;
	NSUInteger maxOffset = self.size.height;
	for (NSUInteger entryIndex = 0;
		 entryIndex < MAX_DIRTY_REGIONS && currentOffset < maxOffset;
		 entryIndex++)
	{
		NSUInteger regionLength = dirtyBlocks[entryIndex];
		// The first zero is a valid zero-length clean prefix. Subsequent zeroes
		// terminate Staging's alternating clean/dirty list.
		if (entryIndex > 0 && regionLength == 0)
			break;

		NSUInteger remaining = maxOffset - currentOffset;
		NSUInteger clippedLength = MIN(regionLength, remaining);
		BOOL isDirtyBlock = (entryIndex % 2 != 0);
		if (isDirtyBlock && clippedLength > 0 &&
			_numPendingDirtyRegions < MAX_DIRTY_REGIONS)
			_pendingDirtyRegions[_numPendingDirtyRegions++] = NSMakeRange(currentOffset, clippedLength);
		currentOffset += clippedLength;
		if (clippedLength != regionLength)
			break;
	}
}

- (void) applyPendingDirtyRegions
{
	[self clearDirtyRegions];
	for (NSUInteger i = 0; i < _numPendingDirtyRegions; i++)
		[self setNeedsDisplayInRegion: _pendingDirtyRegions[i]];
	_numPendingDirtyRegions = 0;
}

- (BOOL) tryBeginRendering
{
	int expected = BXVideoFramePresentationStateFree;
	return atomic_compare_exchange_strong_explicit(&_presentationState, &expected, BXVideoFramePresentationStateRendering,
									memory_order_acquire, memory_order_relaxed);
}

- (BOOL) publishForPresentation
{
	int expected = BXVideoFramePresentationStateRendering;
	return atomic_compare_exchange_strong_explicit(&_presentationState, &expected, BXVideoFramePresentationStateReady,
									memory_order_release, memory_order_relaxed);
}

- (BOOL) tryBeginPresentation
{
	int expected = BXVideoFramePresentationStateReady;
	return atomic_compare_exchange_strong_explicit(&_presentationState, &expected, BXVideoFramePresentationStatePresenting,
									memory_order_acquire, memory_order_relaxed);
}

- (BOOL) discardIfReady
{
	int expected = BXVideoFramePresentationStateReady;
	return atomic_compare_exchange_strong_explicit(&_presentationState, &expected, BXVideoFramePresentationStateFree,
									memory_order_acq_rel, memory_order_relaxed);
}

- (BOOL) markCommitted
{
	int expected = BXVideoFramePresentationStatePresenting;
	BOOL committed = atomic_compare_exchange_strong_explicit(&_presentationState, &expected, BXVideoFramePresentationStateCommitted,
											memory_order_acq_rel, memory_order_relaxed);
	if (!committed)
		BXVerificationCount(BXVerificationCounterCommittedTransitionFailure);
	return committed;
}

- (BOOL) finishUncommittedPresentation
{
    int expected = BXVideoFramePresentationStatePresenting;
    return atomic_compare_exchange_strong_explicit(&_presentationState, &expected, BXVideoFramePresentationStateFree,
											memory_order_release, memory_order_relaxed);
}

- (BOOL) finishCommittedPresentation
{
	int state = atomic_load_explicit(&_presentationState, memory_order_acquire);
	NSAssert(state == BXVideoFramePresentationStateCommitted,
			@"finishCommittedPresentation requires a COMMITTED frame, got state %d", state);
	int expected = BXVideoFramePresentationStateCommitted;
	BOOL finished = atomic_compare_exchange_strong_explicit(&_presentationState, &expected, BXVideoFramePresentationStateFree,
											memory_order_release, memory_order_relaxed);
	if (!finished)
		BXVerificationCount(BXVerificationCounterCommittedCompletionTransitionFailure);
	return finished;
}

- (BOOL) isFree
{
	return atomic_load_explicit(&_presentationState, memory_order_acquire) == BXVideoFramePresentationStateFree;
}

- (int) presentationState
{
	return atomic_load_explicit(&_presentationState, memory_order_acquire);
}

- (void) clearDirtyRegions
{
    self.numDirtyRegions = 0;
}

- (NSRange) dirtyRegionAtIndex: (NSUInteger)regionIndex
{
    NSAssert1(regionIndex < self.numDirtyRegions,
              @"dirtyRegionAtIndex: called with index out of range: %lu", (unsigned long)regionIndex);
    
    return _dirtyRegions[regionIndex];
}

@end
