//
//  BXMetalRenderingView.m
//  Boxer
//
//  Created by Stuart Carnie on 7/10/20.
//  
//

@import QuartzCore;
@import OpenEmuShaders;

#import "ADBGeometry.h"
#import "BXMetalRenderingView+Private.h"
#import "BXVideoFrame.h"
#import "BXMetalLayer.h"
#import "BXIntegerScaling.h"
#import "../BXVerificationInstrumentation.h"

/// Only send 1 frame at once to the GPU.
/// Since we aren't synced to the display, even one more
/// is enough to block in nextDrawable for more than a frame
/// and cause audio skipping.
/// TODO(sgc): implement triple buffering
#define MAX_INFLIGHT 1

@interface BXMetalRenderingView() {
    
}

@property (nonatomic, readwrite) NSArray<OEShaderParamGroup *> *parameterGroups;

@end

@implementation BXMetalRenderingView {
    CAMetalLayer    *_videoLayer;
    OEFilterChain   *_filterChain;
    dispatch_semaphore_t    _inflightSemaphore;
    NSInteger               _skippedFrames;
    id<MTLDevice>           _device;
    id<MTLCommandQueue>     _commandQueue;
    MTLClearColor           _clearColor;
    
    BOOL _inViewportAnimation;
    BOOL _managesViewport;
    NSSize _maxViewportSize;
    NSRect _viewportRect;
    NSRect _targetViewportRect;
    BXRenderingStyle _renderingStyle;
    BXIntegerScalingMode _integerScalingMode;
    NSString *_selectedShaderPresetPath;
    // BOXER-FORK: cache the last integer-scaling viewport to skip identical updates.
    MTLViewport _cachedIntegerScalingViewport;
    BOOL _cachedIntegerScalingViewportValid;
}

@synthesize currentFrame=_currentFrame;
@synthesize maxFrameSize=_maxFrameSize;

- (instancetype)initWithCoder:(NSCoder *)coder {
    if (self = [super initWithCoder: coder]) {
        [self initDefaults];
    }
    return self;
}

- (instancetype)initWithFrame:(NSRect)frameRect {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    
    if (self = [super initWithFrame: frameRect device:device]) {
        [self initDefaults];
    }
    return self;
}

- (OEFilterChain *)filterChain {
    return _filterChain;
}

- (void)initDefaults {
    _inflightSemaphore = dispatch_semaphore_create(MAX_INFLIGHT);
    _device = self.device;
    self.framebufferOnly = YES;
    self.presentsWithTransaction = NO;
    self.paused = NO;
    
    _commandQueue      = [_device newCommandQueue];
    _clearColor        = MTLClearColorMake(0, 0, 0, 1);
    _filterChain = [[OEFilterChain alloc] initWithDevice:_device];
    [_filterChain setDefaultFilteringLinear:NO];
    
    // some reasonable default
    [_filterChain setSourceRect:CGRectMake(0, 0, 648, 480) aspect:CGSizeMake(4, 3)];
    self.renderingStyle = BXRenderingStyleNormal;
    _integerScalingMode = BXIntegerScalingModeOff;
    
    self.wantsLayer = YES;
    
    _videoLayer = (CAMetalLayer *)self.layer;
    
    [self updateRenderState];
    
    _maxFrameSize = NSMakeSize(16384, 16384);
}

- (BOOL)supportsRenderingStyle:(BXRenderingStyle)style {
    return YES;
}

- (NSArray<NSString *> *)availableShaderPresetPaths
{
    NSURL *shadersURL = [NSBundle.mainBundle.resourceURL URLByAppendingPathComponent:@"Shaders" isDirectory:YES];
    NSDirectoryEnumerator<NSURL *> *enumerator = [[NSFileManager defaultManager]
        enumeratorAtURL:shadersURL
        includingPropertiesForKeys:@[NSURLIsRegularFileKey]
        options:(NSDirectoryEnumerationSkipsHiddenFiles | NSDirectoryEnumerationSkipsPackageDescendants)
        errorHandler:nil];

    if (enumerator == nil)
    {
        return @[];
    }

    NSMutableArray<NSString *> *presetPaths = [NSMutableArray array];
    for (NSURL *presetURL in enumerator)
    {
        NSNumber *isRegularFile = nil;
        [presetURL getResourceValue:&isRegularFile forKey:NSURLIsRegularFileKey error:nil];
        if (!isRegularFile.boolValue || ![presetURL.pathExtension.lowercaseString isEqualToString:@"slangp"])
        {
            continue;
        }

        NSString *relativePath = [presetURL.path substringFromIndex:shadersURL.path.length];
        relativePath = [relativePath stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"/"]];
        if (relativePath.length > 0)
        {
            [presetPaths addObject:relativePath];
        }
    }

    [presetPaths sortUsingComparator:^NSComparisonResult(NSString *first, NSString *second) {
        return [first.lastPathComponent localizedStandardCompare:second.lastPathComponent];
    }];
    return presetPaths;
}

- (NSString *)selectedShaderPresetPath
{
    return _selectedShaderPresetPath;
}

- (BOOL)loadShaderPresetAtPath:(NSString *)presetPath
{
    if (presetPath.length == 0 || ![self.availableShaderPresetPaths containsObject:presetPath])
    {
        return NO;
    }

    NSURL *shadersURL = [NSBundle.mainBundle.resourceURL URLByAppendingPathComponent:@"Shaders" isDirectory:YES];
    NSURL *presetURL = [shadersURL URLByAppendingPathComponent:presetPath];
    NSError *error = nil;
    if (![_filterChain setShaderFromURL:presetURL error:&error])
    {
        NSLog(@"Could not load shader preset at %@: %@", presetPath, error.localizedDescription);
        return NO;
    }

    _selectedShaderPresetPath = [presetPath copy];
    self.parameterGroups = _filterChain.shader.parameterGroups;
    return YES;
}

- (void)setRenderingStyle:(BXRenderingStyle)renderingStyle {
    [self willChangeValueForKey:@"renderingStyle"];

    // BOXER-FORK: restore the prior style when the requested shader load fails.
    BXRenderingStyle previousRenderingStyle = _renderingStyle;
    BOOL shaderLoaded = NO;
    
    _renderingStyle = renderingStyle;
    
    switch (renderingStyle) {
    case BXRenderingStyleNormal: {
        shaderLoaded = [self loadShaderPresetAtPath:@"Pixellate/Pixellate.slangp"];
        break;
    }
        
    case BXRenderingStyleCRT: {
        shaderLoaded = [self loadShaderPresetAtPath:@"CRT Geom/CRT Geom.slangp"];
        break;
    }
        
    case BXRenderingStyleSmoothed: {
        shaderLoaded = [self loadShaderPresetAtPath:@"Smooth/Smooth.slangp"];
        break;
    }
    }

    if (!shaderLoaded) {
        // BOXER-FORK: surface shader load failure and restore the active style.
        NSLog(@"[BoxerShaderDiag] shader load failed for rendering style %ld; restoring previous style %ld",
              (long)renderingStyle, (long)previousRenderingStyle);
        _renderingStyle = previousRenderingStyle;
        NSAssert(NO, @"shader load failed for style %ld", (long)renderingStyle);
    }
    
    [self didChangeValueForKey:@"renderingStyle"];
    [self updateIntegerScalingForFrame:self.currentFrame];
    
}

- (void)setIntegerScalingMode:(BXIntegerScalingMode)integerScalingMode
{
    if (_integerScalingMode == integerScalingMode) {
        return;
    }
    _integerScalingMode = integerScalingMode;
    [self updateIntegerScalingForFrame:self.currentFrame];
}

- (void)updateIntegerScalingForFrame:(BXVideoFrame *)frame
{
    if (frame == nil || self.integerScalingMode == BXIntegerScalingModeOff) {
        // BOXER-FORK: reset the deduplication cache with the output viewport.
        _cachedIntegerScalingViewportValid = NO;
        [_filterChain resetOutputViewport];
        return;
    }

    // Auto mode is intended for CRT presentation. Normal mode already uses
    // nearest filtering and should retain its existing aspect-fit behavior.
    if (self.integerScalingMode == BXIntegerScalingModeAuto &&
        self.renderingStyle != BXRenderingStyleCRT) {
        // BOXER-FORK: reset the deduplication cache with the output viewport.
        _cachedIntegerScalingViewportValid = NO;
        [_filterChain resetOutputViewport];
        return;
    }

    BXIntegerScaleResult result = BXCalculateIntegerScale(frame.scaledSize,
                                                            _videoLayer.drawableSize,
                                                            self.integerScalingMode);
    if (_cachedIntegerScalingViewportValid &&
        _cachedIntegerScalingViewport.originX == result.viewport.originX &&
        _cachedIntegerScalingViewport.originY == result.viewport.originY &&
        _cachedIntegerScalingViewport.width == result.viewport.width &&
        _cachedIntegerScalingViewport.height == result.viewport.height) {
        return;
    }

    [_filterChain setOutputViewport:result.viewport];
    // BOXER-FORK: remember the exact viewport passed to the filter chain.
    _cachedIntegerScalingViewport = result.viewport;
    _cachedIntegerScalingViewportValid = YES;
}

- (void)updateWithFrame:(BXVideoFrame *)frame {
	NSAssert([NSThread isMainThread], @"Metal frame uploads must run on the main thread");
	uint64_t updateStart = BXVerificationNow();
	if (frame == nil) {
        _currentFrame = nil;
        return;
    }

    BXVideoFrame *previousFrame = _currentFrame;
    if (previousFrame != nil && previousFrame != frame &&
        [previousFrame presentationState] == BXVideoFramePresentationStatePresenting) {
        [previousFrame finishUncommittedPresentation];
    }
    _currentFrame = frame;

    CGRect sourceRect = CGRectMake(0, 0, frame.size.width, frame.size.height);
    [_filterChain setSourceRect:sourceRect aspect:frame.scaledSize];
    [self updateIntegerScalingForFrame:frame];
    
	BOOL textureSizeChanged = (frame.texture == nil ||
	                           frame.texture.width != frame.size.width ||
	                           frame.texture.height != frame.size.height ||
	                           frame.texture.pixelFormat != MTLPixelFormatBGRA8Unorm);
	if (textureSizeChanged) {
        if (NSIsEmptyRect(self.viewportRect)) {
            NSRect viewportRect = [self viewportForFrame:frame];
            [self setViewportRect:viewportRect animated:NO];
        }
        
        // Create or replace the texture owned by this frame slot.
        MTLTextureDescriptor *td =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                           width:frame.size.width
                                                          height:frame.size.height
                                                       mipmapped:NO];
			frame.texture = [_device newTextureWithDescriptor:td];
			BXVerificationCount(BXVerificationCounterTextureCreation);
	}
	uint64_t replaceStart = BXVerificationNow();
		[frame.texture replaceRegion:MTLRegionMake2D(0, 0, sourceRect.size.width, sourceRect.size.height)
                mipmapLevel:0
                withBytes:frame.bytes
                bytesPerRow:frame.pitch];
	BXVerificationSample(BXVerificationMetricReplaceRegion, replaceStart, BXVerificationNow());
    
    // If the frame changes size or aspect ratio, and we're responsible for the viewport ourselves,
    // then smoothly animate the transition to the new size.
    if (self.managesViewport)
    {
        [self setViewportRect:[self viewportForFrame:frame] animated:YES];
    }
	[self setNeedsDisplay:YES];
	BXVerificationSample(BXVerificationMetricUpdateWithFrame, updateStart, BXVerificationNow());
}

- (void)drawRect:(NSRect)dirtyRect {
    BXVideoFrame *frame = _currentFrame;
    if (frame == nil || frame.texture == nil) {
        return;
    }

    // AppKit may issue another draw for a frame that has already been submitted.
    // Such a frame is owned by the GPU until its completion handler runs; do not
    // wait, acquire another drawable, or submit a second command buffer for it.
    if ([frame presentationState] != BXVideoFramePresentationStatePresenting) {
        return;
    }
    
    @autoreleasepool {
        if (dispatch_semaphore_wait(_inflightSemaphore, DISPATCH_TIME_NOW) != 0) {
            _skippedFrames++;
            BXVerificationCount(BXVerificationCounterFrameDroppedSemaphore);
            BXVideoFrame *droppedFrame = frame;
            if (![droppedFrame finishUncommittedPresentation] &&
                [droppedFrame presentationState] == BXVideoFramePresentationStateCommitted) {
                BXVerificationCount(BXVerificationCounterSemaphoreDropOnCommittedFrame);
            }
	        } else {
			uint64_t drawableStart = BXVerificationNow();
	            id<CAMetalDrawable> drawable = _videoLayer.nextDrawable;
			BXVerificationSample(BXVerificationMetricNextDrawable, drawableStart, BXVerificationNow());
	            if (drawable != nil) {
				uint64_t encodeStart = BXVerificationNow();
				[_filterChain setSourceTexture:frame.texture];
	            id<MTLCommandBuffer> commandBuffer = [_commandQueue commandBuffer];
	            commandBuffer.label = @"video frame";
	            [_filterChain renderOffscreenPassesWithCommandBuffer:commandBuffer];
	            BXVerificationSample(BXVerificationMetricCommandEncode, encodeStart, BXVerificationNow());

	                MTLRenderPassDescriptor *rpd = [MTLRenderPassDescriptor new];
                rpd.colorAttachments[0].clearColor = _clearColor;
                // TODO: Use MTLLoadActionDontCare
                // We can use MTLLoadActionDontCare when source texture
                // is same aspect ratio as drawable (i.e. windowed)
	                rpd.colorAttachments[0].loadAction = MTLLoadActionClear;
	                rpd.colorAttachments[0].texture    = drawable.texture;
	                id<MTLRenderCommandEncoder> rce = [commandBuffer renderCommandEncoderWithDescriptor:rpd];
                [_filterChain renderFinalPassWithCommandEncoder:rce];
                [rce endEncoding];
                
                BXVideoFrame *presentedFrame = frame;
                __block dispatch_semaphore_t inflight = _inflightSemaphore;
                __block uint64_t commitTime = 0;
                [commandBuffer addCompletedHandler:^(id<MTLCommandBuffer> _) {
                    NSAssert(presentedFrame != nil, @"A committed command buffer must capture a frame");
                    dispatch_semaphore_signal(inflight);
                    if ([presentedFrame presentationState] == BXVideoFramePresentationStateFree)
                        BXVerificationCount(BXVerificationCounterPrematureCommittedFree);
                    [presentedFrame finishCommittedPresentation];
                    BXVerificationCount(BXVerificationCounterGPUCompletion);
                    BXVerificationSample(BXVerificationMetricGPUCompletion, commitTime, BXVerificationNow());
                }];
                
                [commandBuffer presentDrawable:drawable];
                uint64_t commitStart = BXVerificationNow();
                commitTime = commitStart;
					if (![presentedFrame markCommitted]) {
						dispatch_semaphore_signal(self->_inflightSemaphore);
						return;
					}
					[commandBuffer commit];
				BXVerificationSample(BXVerificationMetricCommandBufferCommit, commitStart, BXVerificationNow());
            } else {
                dispatch_semaphore_signal(self->_inflightSemaphore);
                BXVerificationCount(BXVerificationCounterFrameDroppedNoDrawable);
                [frame finishUncommittedPresentation];
            }
        }
    }
}

#pragma mark - Viewport / Bounds

- (void)updateRenderState {
    [_videoLayer setBounds:self.bounds];
    NSRect rect = [self convertRectToBacking:self.bounds];
    _videoLayer.drawableSize = NSSizeToCGSize(rect.size);
    [_filterChain setDrawableSize:_videoLayer.drawableSize];
    if (self.currentFrame) {
        [self setViewportRect:[self viewportForFrame:self.currentFrame] animated:NO];
        [self updateIntegerScalingForFrame:self.currentFrame];
    }
}

- (void)setFrameSize:(NSSize)newSize {
    [super setFrameSize:newSize];
    if (!self.inLiveResize) {
        [self updateRenderState];
    }
}

- (void) viewDidEndLiveResize
{
    [self updateRenderState];
}

- (void) windowDidChangeBackingProperties: (NSNotification *)notification
{
    //[self _applyViewportToRenderer];
}

#pragma mark - Animation

+ (id) defaultAnimationForKey: (NSString *)key
{
    if ([key isEqualToString: @"viewportRect"])
    {
        CABasicAnimation *animation = [CABasicAnimation animation];
        animation.duration = 0.2;
        animation.timingFunction = [CAMediaTimingFunction functionWithName: kCAMediaTimingFunctionEaseIn];
        return animation;
    }
    else
    {
        return [super defaultAnimationForKey:key];
    }
}

- (void)animationDidStart:(CAAnimation *)anim
{
    _inViewportAnimation = YES;
}

- (void)animationDidStop:(CAAnimation *)anim finished:(BOOL)flag
{
    _inViewportAnimation = NO;
    anim.delegate = nil;
}

//Returns the rectangular region of the view into which the specified frame should be drawn.
- (NSRect)viewportForFrame:(BXVideoFrame *)frame
{
    if (frame != nil && self.managesViewport)
    {
        NSSize frameSize = frame.scaledSize;
        NSRect frameRect = NSMakeRect(0.0f, 0.0f, frameSize.width, frameSize.height);
        
        NSRect canvasRect = self.bounds;
        NSRect maxViewportRect = canvasRect;
        
        //If we have a maximum viewport size, fit the frame within that; otherwise, just fill the canvas as best we can.
        if (!NSEqualSizes(self.maxViewportSize, NSZeroSize) && sizeFitsWithinSize(self.maxViewportSize, canvasRect.size))
        {
            maxViewportRect = resizeRectFromPoint(canvasRect, self.maxViewportSize, NSMakePoint(0.5f, 0.5f));
        }
        
        NSRect fittedViewportRect = fitInRect(frameRect, maxViewportRect, NSMakePoint(0.5f, 0.5f));
        
        return fittedViewportRect;
    }
    else
    {
        return self.bounds;
    }
}

- (void) setManagesViewport:(BOOL)enabled
{
    if (_managesViewport != enabled)
    {
        _managesViewport = enabled;
        
        // Update our viewport immediately to compensate for the change
        [self setViewportRect:[self viewportForFrame:self.currentFrame]
                     animated:NO];
    }
}

- (void)setViewportRect:(NSRect)newRect
{
    if (!NSEqualRects(newRect, _viewportRect))
    {
        _viewportRect = newRect;
        [self needsDisplay];
    }
}

- (void)setViewportRect:(NSRect)newRect animated:(BOOL)animated
{
    if (!NSEqualRects(_targetViewportRect, newRect))
    {
        //If our viewport is zero (i.e. we haven't received a frame until now)
        //then just replace the viewport with the new one instead of animating to it.
        if (!animated || NSIsEmptyRect(_viewportRect))
        {
            _targetViewportRect = newRect;
            self.viewportRect = newRect;
        }
        else
        {
            _targetViewportRect = newRect;
            
            [NSAnimationContext beginGrouping]; {
                NSAnimationContext.currentContext.duration = 0.2;
                [self.animator setViewportRect:_targetViewportRect];
                [NSAnimationContext endGrouping];
            }
        }
    }
}


@end
