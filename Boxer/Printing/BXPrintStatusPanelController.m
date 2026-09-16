/*
 Copyright (c) 2013 Alun Bestor and contributors. All rights reserved.
 This source file is released under the GNU General Public License 2.0. A full copy of this license
 can be found in this XCode project at Resources/English.lproj/BoxerHelp/pages/legalese.html, or read
 online at [http://www.gnu.org/licenses/gpl-2.0.txt].
 */

#import "BXPrintStatusPanelController.h"
#import "BXPrintSession.h"
#import "ADBGeometry.h"
#import "ADBForwardCompatibility.h"
#import <QuartzCore/QuartzCore.h>
#import <CoreImage/CIFilter.h>

@implementation BXPrintStatusPanelController

- (void) windowDidLoad
{
    //The panel is resizable so that more of the printout can be seen at once; the paper
    //inside it can also be rolled by hand. It will not usefully go below the size it was
    //designed at, so that is the floor. -setFrameAutosaveName: below remembers whatever
    //size the user settles on.
    self.window.minSize = NSMakeSize(480, 320);
    self.window.movableByWindowBackground = YES;
    ((NSPanel *)self.window).becomesKeyOnlyIfNeeded = YES;
    self.window.frameAutosaveName = @"PrintStatusPanel";
    self.window.level = NSNormalWindowLevel;
    
    self.window.animationBehavior = NSWindowAnimationBehaviorUtilityWindow;
    self.window.collectionBehavior |= NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorFullScreenAuxiliary;
}


#pragma mark -
#pragma mark UI bindings

+ (NSString *) localizedNameForPort: (BXEmulatedPrinterPort)port
{
    switch (port)
    {
        case BXPrinterPortLPT1:
            return NSLocalizedString(@"LPT1", @"Localized name for parallel port 1");
            break;
            
        case BXPrinterPortLPT2:
            return NSLocalizedString(@"LPT2", @"Localized name for parallel port 2");
            break;
            
        case BXPrinterPortLPT3:
            return NSLocalizedString(@"LPT3", @"Localized name for parallel port 3");
            break;
    }
}

+ (NSSet *) keyPathsForValuesAffectingPrinterStatus
{
    return [NSSet setWithObjects: @"numPages", @"inProgress", nil];
}

- (NSString *) printerStatus
{
    //Print session has not been started
    if (self.numPages == 0)
    {
        return NSLocalizedString(@"The emulated printer is currently idle.", @"Status text shown in print status panel when the emulated printer has not printed anything yet in the current print session.");
    }
    //In the middle of printing
    else
    {
        NSString *format;
        if (self.inProgress)
        {
            format = NSLocalizedString(@"Preparing page %u…", @"Status text shown in print status panel when the emulated printer is in the middle of printing a page. %u is the current page number being printed.");
        }
        else
        {
            if (self.numPages > 1)
            {
                format = NSLocalizedString(@"%u pages are ready to print.", @"Status text shown in print status panel when multiple pages have been prepared. %u is the number of pages prepared so far.");
            }
            else
            {
                format = NSLocalizedString(@"1 page is ready to print.", @"Status text shown in print status panel when a single page has been prepared.");
            }
        }
        
        return [NSString stringWithFormat: format, self.numPages];
    }
}

+ (NSSet *) keyPathsForValuesAffectingPrinterInstructions
{
    return [NSSet setWithObjects: @"localizedPaperName", @"activePrinterPort", nil];
}

- (NSString *) printerInstructions
{
    NSString *portName = [self.class localizedNameForPort: self.activePrinterPort];
    NSString *format = NSLocalizedString(@"Instruct your DOS program to print to %1$@ using %2$@ paper.", @"Explanatory text shown while the printer is idle. %1$@ is the localized name of the port the user should choose in DOS (e.g. “LPT1”.) %2$@ is the localized name of the paper type they should choose in DOS (e.g. “A4”, “Letter”.)");
    
    return [NSString stringWithFormat: format, portName, self.localizedPaperName];
}

+ (NSSet *) keyPathsForValuesAffectingHasPages
{
    return [NSSet setWithObject: @"numPages"];
}

+ (NSSet *) keyPathsForValuesAffectingCanPrint
{
    return [NSSet setWithObjects: @"hasPages", @"inProgress", nil];
}

- (BOOL) hasPages
{
    return self.numPages > 0;
}

- (BOOL) canPrint
{
    return self.hasPages && !self.inProgress;
}

@end


@interface BXPrintPreview ()

//Derived from pageLayers rather than stored, so that the two names the rest of the
//class already used keep working now that there is a whole stack behind them.
@property (readonly, nonatomic) CALayer *currentPage;
@property (readonly, nonatomic) CALayer *previousPage;
@property (strong, nonatomic) CALayer *paperFeed;
@property (strong, nonatomic) CALayer *head;

//Chassis layers, kept so they can be repositioned when the view is resized.
@property (strong, nonatomic) CALayer *rootLayer;
@property (strong, nonatomic) CALayer *backdrop;
@property (strong, nonatomic) CALayer *body;
@property (strong, nonatomic) CALayer *cover;
@property (strong, nonatomic) CALayer *lighting;
@property (strong, nonatomic) CALayer *leftClip;
@property (strong, nonatomic) CALayer *rightClip;
@property (strong, nonatomic) CALayer *clipRoller;

/// Every page printed so far, newest first: index 0 is the page being printed,
/// index 1 the one before it, and so on. Rolling the paper back reveals them.
@property (strong, nonatomic) NSMutableArray<CALayer *> *pageLayers;

@property (assign, nonatomic) CGSize pageSize;
@property (assign, nonatomic) CGSize dpi;

/// How much bigger than the artwork's design width the view currently is. Widening the
/// window zooms the paper and everything on it; making it taller just shows more paper.
@property (assign, nonatomic) CGFloat scale;

@end

@implementation BXPrintPreview
{
	CGImageRef _paperTexture;
}

//The chassis artwork is 480x480 and the panel used to be exactly that wide, so every
//layer could be placed once from -bounds and never touched again. Now that the window
//resizes, the placement has to be redone on every bounds change — see -layout — and the
//backdrop has to be split in two. The art is a flat dark void above a lighter printer
//body: stretching the void in both directions is invisible, but stretching the body
//vertically would make the printer grow a thicker lip as the window got taller. So the
//two bands are separate layers, each drawn from its own slice of the same image.
#define BXPrinterArtHeight  480.0
#define BXPrinterArtWidth   480.0
#define BXPrinterBodyHeight 193.0

//The paper texture is one 12-inch fanfold sheet at 48dpi, with the sprocket holes punched
//out of its alpha channel at a half-inch pitch. It is tiled at this size whatever the page
//length is, because the hole pitch is a property of the paper and not of the page.
#define BXPrinterPaperTextureWidth  456.0
#define BXPrinterPaperTextureHeight 576.0
#define BXPrinterBaseDPI            48.0

- (void) awakeFromNib
{
    //A US fanfold sheet until Page Setup says otherwise.
    _pageSizeInInches = NSMakeSize(8.5, 12.0);
    self.scale = 1.0;
    self.dpi = CGSizeMake(BXPrinterBaseDPI, BXPrinterBaseDPI);
    self.pageSize = CGSizeMake(_pageSizeInInches.width * self.dpi.width,
                               _pageSizeInInches.height * self.dpi.height);
    self.feedOffset = 0;
    self.headOffset = 0;
    self.pageLayers = [NSMutableArray arrayWithCapacity: 8];
    
    NSImage *paper = [NSImage imageNamed: @"PrinterPaper"];
    _paperTexture = [paper CGImageForProposedRect: NULL context: nil hints: nil];
    
    //Slice the chassis art into its two bands up front. contentsRect would express the
    //same thing in one layer each, but its interaction with an NSImage's several
    //representations is not worth relying on; two CGImages are unambiguous.
    NSImage *chassis = [NSImage imageNamed: @"PrinterBackground"];
    CGImageRef chassisImage = [chassis CGImageForProposedRect: NULL context: nil hints: nil];
    CGFloat chassisHeight = CGImageGetHeight(chassisImage);
    CGFloat chassisWidth = CGImageGetWidth(chassisImage);
    CGFloat bodyPixels = chassisHeight * (BXPrinterBodyHeight / BXPrinterArtHeight);
    
    //CGImage coordinates run from the top down, so the void is the first slice.
    CGImageRef voidImage = CGImageCreateWithImageInRect(chassisImage,
                                                        CGRectMake(0, 0, chassisWidth, chassisHeight - bodyPixels));
    CGImageRef bodyImage = CGImageCreateWithImageInRect(chassisImage,
                                                        CGRectMake(0, chassisHeight - bodyPixels, chassisWidth, bodyPixels));
    
    CALayer *root = [CALayer layer];
    root.frame = NSRectToCGRect(self.bounds);
    root.delegate = self;
    root.masksToBounds = YES;
    
    //The dark void the paper feeds out of. contentsRect takes the top band of the
    //artwork only; kCAGravityResize then stretches that band to whatever size the
    //window is, which a flat texture survives.
    self.backdrop = [CALayer layer];
    self.backdrop.contents = (__bridge id)voidImage;
    self.backdrop.contentsGravity = kCAGravityResize;
    self.backdrop.delegate = self;
    
    //The printer body, pinned to the bottom at its natural height so it never stretches
    //vertically, however tall the window gets.
    self.body = [CALayer layer];
    self.body.contents = (__bridge id)bodyImage;
    self.body.contentsGravity = kCAGravityResize;
    self.body.anchorPoint = CGPointMake(0.5, 0);
    self.body.delegate = self;
    
    self.cover = [CALayer layer];
    self.cover.contents = [NSImage imageNamed: @"PrinterCover"];
    self.cover.contentsGravity = kCAGravityResize;
    self.cover.anchorPoint = CGPointMake(0.5, 0);
    self.cover.compositingFilter = [CIFilter filterWithName: @"CIMultiplyBlendMode"];
    self.cover.delegate = self;
    
    self.lighting = [CALayer layer];
    self.lighting.contents = [NSImage imageNamed: @"PrinterLighting"];
    self.lighting.contentsGravity = kCAGravityResize;
    self.lighting.anchorPoint = CGPointMake(0.5, 1);
    self.lighting.compositingFilter = [CIFilter filterWithName: @"CISoftLightBlendMode"];
    self.lighting.delegate = self;
    
    self.paperFeed = [CALayer layer];
    self.paperFeed.anchorPoint = CGPointMake(0.5, 0);
    self.paperFeed.delegate = self;
    self.paperFeed.shadowOffset = CGSizeMake(0, -2);
    self.paperFeed.shadowRadius = 3;
    self.paperFeed.shadowOpacity = 0.66;
    self.paperFeed.needsDisplayOnBoundsChange = YES;
    
    self.head = [CALayer layer];
    self.head.backgroundColor = CGColorGetConstantColor(kCGColorBlack);
    self.head.bounds = CGRectMake(0, 0, 30, 12);
    self.head.anchorPoint = CGPointMake(0.5, 0);
    self.head.delegate = self;
    
    self.leftClip = [CALayer layer];
    self.leftClip.contents = [NSImage imageNamed: @"PrinterClip"];
    self.leftClip.bounds = CGRectMake(0, 0, 50, 104);
    self.leftClip.anchorPoint = CGPointMake(0, 0.5);
    self.leftClip.delegate = self;
    
    self.rightClip = [CALayer layer];
    self.rightClip.contents = self.leftClip.contents;
    self.rightClip.bounds = self.leftClip.bounds;
    self.rightClip.anchorPoint = CGPointMake(0, 0.5);
    self.rightClip.affineTransform = CGAffineTransformMakeScale(-1, 1);
    self.rightClip.delegate = self;
    
    self.clipRoller = [CALayer layer];
    self.clipRoller.backgroundColor = CGColorGetConstantColor(kCGColorBlack);
    self.clipRoller.delegate = self;
    self.clipRoller.shadowOffset = CGSizeZero;
    self.clipRoller.shadowOpacity = 1;
    self.clipRoller.shadowRadius = 30;
    
    [root addSublayer: self.backdrop];
    [root addSublayer: self.body];
    [root addSublayer: self.clipRoller];
    [root addSublayer: self.paperFeed];
    //Page layers are inserted above the paper feed as they are printed, by -_addPageLayer.
    //We don't bother showing the print head for now because it usually moves too fast for any animation to be visible 
    //[root addSublayer: self.head];
    [root addSublayer: self.cover];
    [root addSublayer: self.leftClip];
    [root addSublayer: self.rightClip];
    [root addSublayer: self.lighting];
    
    CGImageRelease(voidImage);
    CGImageRelease(bodyImage);
    
    //Keep our own reference: -addPageLayer inserts into this as pages are printed, and
    //-layer is not guaranteed to still be the layer we handed over once wantsLayer is set.
    self.rootLayer = root;
    self.layer = root;
    self.wantsLayer = YES;
    
    //For 10.9: fixes crash when using compositing filters.
    self.layerUsesCoreImageFilters = YES;
    
    //The first page exists before anything is printed to it.
    [self _addPageLayer];
    
    [self _layoutChassis];
    [self _syncPagePosition];
    [self _syncHeadPosition];
}

//Positions everything that depends on the view's size. Called once at load and again on
//every resize, with implicit animations off — otherwise each layer crawls to its new
//position and a live resize looks like jelly.
- (void) _layoutChassis
{
    CGRect bounds = NSRectToCGRect(self.bounds);
    CGFloat midX = CGRectGetMidX(bounds);
    CGFloat clipHeight = 106;
    
    //Width drives the zoom; height only decides how much paper is on show.
    CGFloat oldScale = self.scale;
    CGFloat newScale = (bounds.size.width > 0) ? (bounds.size.width / BXPrinterArtWidth) : 1.0;
    self.scale = newScale;
    self.dpi = CGSizeMake(BXPrinterBaseDPI * newScale, BXPrinterBaseDPI * newScale);
    self.pageSize = CGSizeMake(self.pageSizeInInches.width * self.dpi.width,
                               self.pageSizeInInches.height * self.dpi.height);
    
    //Keep the same part of the printout under the user's eye across a zoom, rather than
    //having the paper jump because the offset is in points and the points changed size.
    if (oldScale > 0 && newScale != oldScale)
        _rollOffset *= (newScale / oldScale);
    
    [CATransaction begin];
    [CATransaction setDisableActions: YES];
    
    self.rootLayer.frame = bounds;
    //Nothing may escape the printer: the panel's buttons sit directly beneath this view.
    self.rootLayer.masksToBounds = YES;
    
    for (CALayer *page in self.pageLayers)
        page.bounds = CGRectMake(0, 0, self.pageSize.width, self.pageSize.height);
    
    self.backdrop.frame = bounds;
    
    self.body.bounds = CGRectMake(0, 0, bounds.size.width, BXPrinterBodyHeight);
    self.body.position = CGPointMake(midX, 0);
    
    self.cover.bounds = CGRectMake(0, 0, bounds.size.width, 36);
    self.cover.position = CGPointMake(midX, 0);
    
    self.lighting.bounds = CGRectMake(0, 0, bounds.size.width, 240);
    self.lighting.position = CGPointMake(midX, bounds.size.height);
    
    self.leftClip.position = CGPointMake(0, clipHeight);
    self.rightClip.position = CGPointMake(bounds.size.width, clipHeight);
    
    self.clipRoller.bounds = CGRectMake(0, 0, bounds.size.width, 96);
    self.clipRoller.position = CGPointMake(midX, clipHeight);
    
    //The paper is as wide as its texture, which includes the sprocket strips; the page
    //printed on it is narrower.
    self.paperFeed.bounds = CGRectMake(0, 0, BXPrinterPaperTextureWidth * newScale, bounds.size.height);
    self.paperFeed.position = CGPointMake(midX, 0);
    [self.paperFeed setNeedsDisplay];
    
    [CATransaction commit];
}

- (void) setPageSizeInInches: (NSSize)pageSizeInInches
{
    if (!NSEqualSizes(pageSizeInInches, _pageSizeInInches) &&
        pageSizeInInches.width > 0 && pageSizeInInches.height > 0)
    {
        _pageSizeInInches = pageSizeInInches;
        self.needsLayout = YES;
    }
}

- (void) layout
{
    [super layout];
    [self _layoutChassis];
    [self _syncPagePosition];
    [self _syncHeadPosition];
}

- (void) setFrameSize: (NSSize)newSize
{
    [super setFrameSize: newSize];
    self.needsLayout = YES;
}

- (void) dealloc
{
    CGImageRelease(_paperTexture);
    _paperTexture = NULL;
}

- (void) drawLayer: (CALayer *)layer inContext: (CGContextRef)ctx
{
    if (layer == self.paperFeed)
    {
        //CGContextDrawTiledImage's rect is the size and origin of ONE tile, not the area
        //to cover: it repeats that tile across the whole clip. Handing it the union of
        //every page — which is what the first version of the roll feature did — stretches
        //a single sheet over the entire printout, and with it the sprocket holes, which
        //are punched out of the texture's alpha channel. One sheet, always.
        CALayer *page = self.currentPage;
        if (!page)
            return;
        
        CGRect pageRect = [self.paperFeed convertRect: page.bounds fromLayer: page];
        CGRect tile = CGRectMake(CGRectGetMidX(pageRect) - (BXPrinterPaperTextureWidth * self.scale * 0.5),
                                 CGRectGetMaxY(pageRect) - (BXPrinterPaperTextureHeight * self.scale),
                                 BXPrinterPaperTextureWidth * self.scale,
                                 BXPrinterPaperTextureHeight * self.scale);
        
        CGContextDrawTiledImage(ctx, tile, _paperTexture);
        
        //The hole pitch is a property of the paper and the page length is not, so the two
        //only coincide on 12-inch fanfold. Draw the fold at the real page boundaries.
        [self _drawPerforationsInContext: ctx];
    }
}

//A dashed line where one page ends and the next begins, which on continuous paper is
//where it would tear.
- (void) _drawPerforationsInContext: (CGContextRef)ctx
{
    CGFloat dash[] = { 3.0 * self.scale, 3.0 * self.scale };
    CGContextSaveGState(ctx);
        CGContextSetLineWidth(ctx, 1.0);
        CGContextSetGrayStrokeColor(ctx, 0.55, 0.65);
        CGContextSetLineDash(ctx, 0, dash, 2);
        
        CGFloat inset = 0.5 * (BXPrinterPaperTextureWidth - self.pageSizeInInches.width * BXPrinterBaseDPI) * self.scale;
        for (CALayer *page in self.pageLayers)
        {
            CGRect pageRect = [self.paperFeed convertRect: page.bounds fromLayer: page];
            CGFloat y = floor(CGRectGetMinY(pageRect)) + 0.5;
            CGContextMoveToPoint(ctx, inset, y);
            CGContextAddLineToPoint(ctx, self.paperFeed.bounds.size.width - inset, y);
        }
        CGContextStrokePath(ctx);
    CGContextRestoreGState(ctx);
}

- (BOOL) layer: (CALayer *)layer shouldInheritContentsScale: (CGFloat)newScale fromWindow: (NSWindow *)window
{
    return YES;
}

//A fresh, empty page layer, inserted at the top of the stack and directly above the
//paper feed so that it is drawn over the paper but under the chassis.
- (CALayer *) _addPageLayer
{
    CALayer *page = [CALayer layer];
    page.anchorPoint = CGPointMake(0.5, 1);
    page.bounds = CGRectMake(0, 0, self.pageSize.width, self.pageSize.height);
    page.delegate = self;
    //Not kCAGravityTop, which draws the preview at its natural pixel size and so tied the
    //layout to the session's preview DPI: raising that DPI for sharper zooming made every
    //page render half again too wide and spill off the paper. The preview is always a
    //whole page, so scaling it to the page layer is exact at any DPI.
    page.contentsGravity = kCAGravityResizeAspect;
    //Add a small shadow to thicken the preview and make it bolder
    page.shadowOffset = CGSizeZero;
    page.shadowOpacity = 0.5;
    page.shadowRadius = 0.25;
    
    [self.pageLayers insertObject: page atIndex: 0];
    [self.rootLayer insertSublayer: page above: self.paperFeed];
    
    return page;
}

- (CALayer *) currentPage
{
    return self.pageLayers.firstObject;
}

- (CALayer *) previousPage
{
    return (self.pageLayers.count > 1) ? [self.pageLayers objectAtIndex: 1] : nil;
}

- (NSImage *) currentPagePreview
{
    return self.currentPage.contents;
}

- (NSImage *) previousPagePreview
{
    return self.previousPage.contents;
}

- (void) setCurrentPagePreview: (NSImage *)preview
{
    //The preview image supplied is likely to be the same object the previous image,
    //but updated with new content; so force the layer to update itself by flipping
    //the contents momentarily to nil.
    //TODO: work out why a simple setNeedsDisplay isn't doing the job.
    self.currentPage.contents = nil;
    self.currentPage.contents = preview;
    
    //New output arrives at the print head, so take the paper back there: leaving the
    //user staring at page 2 while page 9 is being printed would be worse than the
    //interruption.
    [self rollToLivePosition: self];
}

- (void) setPreviousPagePreview: (NSImage *)preview
{
    CALayer *previous = self.previousPage;
    previous.contents = nil;
    previous.contents = preview;
}

- (void) resetPages
{
    for (CALayer *page in self.pageLayers)
        [page removeFromSuperlayer];
    
    [self.pageLayers removeAllObjects];
    _rollOffset = 0;
    
    [self _addPageLayer];
    [self _syncPagePosition];
}

- (void) _syncHeadPosition
{
    CGFloat xPos = self.pageSize.width * self.headOffset;
    self.head.position = CGPointMake(CGRectGetMinX(self.currentPage.frame) + xPos, 0);
}

- (void) _syncPagePosition
{
    //TWEAK: keep the 0-position slightly below the fold, so as not to show unprinted lines during slow printing.
    CGFloat bottomOffset = 15;
    CGFloat yPos = (self.pageSize.height * self.feedOffset) - bottomOffset - self.rollOffset;
    CGFloat midX = NSMidX(self.bounds);
    
    //Pages are stacked upwards from the current one: with an anchor point at the top
    //edge, each page's position *is* the top of the page, and page n sits exactly one
    //page height above page n-1. Rolling the paper back subtracts from all of them at
    //once, which walks the whole stack down past the roller.
    //Disable implicit movement animations on <10.7
    [CATransaction begin];
    [CATransaction setAnimationDuration: 0];
        NSUInteger i, numPages = self.pageLayers.count;
        for (i = 0; i < numPages; i++)
        {
            CALayer *page = [self.pageLayers objectAtIndex: i];
            page.position = CGPointMake(midX, yPos + (i * self.pageSize.height));
        }
    [CATransaction commit];
    
    [self.paperFeed setNeedsDisplay];
}

#pragma mark - Rolling the paper by hand

- (CGFloat) maxRollOffset
{
    //Far enough back to bring the top of the oldest page to the top of the view, and no
    //further. Rolling until that top edge reaches the *bottom* of the view would be one
    //view-height too far and would leave the user looking at blank paper above
    //everything they had printed, which is exactly what the first version did.
    NSUInteger pagesAbove = (self.pageLayers.count > 0) ? self.pageLayers.count - 1 : 0;
    CGFloat topOfOldestPage = self.pageSize.height * (self.feedOffset + pagesAbove);
    CGFloat maxOffset = topOfOldestPage - self.bounds.size.height;
    return MAX(maxOffset, 0);
}

- (void) setRollOffset: (CGFloat)rollOffset
{
    CGFloat clamped = MIN(MAX(rollOffset, 0), self.maxRollOffset);
    if (clamped != _rollOffset)
    {
        _rollOffset = clamped;
        [self _syncPagePosition];
    }
}

- (IBAction) rollToLivePosition: (id)sender
{
    self.rollOffset = 0;
}

- (void) scrollWheel: (NSEvent *)event
{
    //A trackpad reports deltas already in points; a wheel reports them in lines, and a
    //line here means a line of text rather than a scroll view's row.
    CGFloat delta = event.scrollingDeltaY;
    if (!event.hasPreciseScrollingDeltas)
        delta *= self.dpi.height / 6.0;
    
    self.rollOffset = self.rollOffset + delta;
}

//The paper can be rolled with the keyboard too, which is the only way to do it precisely.
- (BOOL) acceptsFirstResponder
{
    return YES;
}

- (void) keyDown: (NSEvent *)event
{
    [self interpretKeyEvents: @[event]];
}

- (void) moveUp: (id)sender
{
    self.rollOffset = self.rollOffset + (self.dpi.height / 6.0);
}

- (void) moveDown: (id)sender
{
    self.rollOffset = self.rollOffset - (self.dpi.height / 6.0);
}

- (void) pageUp: (id)sender
{
    self.rollOffset = self.rollOffset + self.pageSize.height;
}

- (void) pageDown: (id)sender
{
    self.rollOffset = self.rollOffset - self.pageSize.height;
}

- (void) scrollPageUp: (id)sender    { [self pageUp: sender]; }
- (void) scrollPageDown: (id)sender  { [self pageDown: sender]; }

- (void) moveToBeginningOfDocument: (id)sender
{
    self.rollOffset = self.maxRollOffset;
}

- (void) moveToEndOfDocument: (id)sender
{
    [self rollToLivePosition: sender];
}

- (void) setFeedOffset: (CGFloat)feedOffset
{
    if (feedOffset != self.feedOffset)
    {
        _feedOffset = feedOffset;
        [self _syncPagePosition];
    }
}

- (void) setHeadOffset: (CGFloat)headOffset
{
    if (headOffset != self.headOffset)
    {
        _headOffset = headOffset;
        [self _syncHeadPosition];
    }
}

- (void) animateHeadToOffset: (CGFloat)headOffset
{
    //Don't bother animating the head's position as it moves so fast any animation would be interrupted.
    self.headOffset = headOffset;
}

- (void) animateFeedToOffset: (CGFloat)feedOffset
{
    [self.animator setFeedOffset: feedOffset];
}

+ (id) defaultAnimationForKey: (NSString *)key
{
    if ([key isEqualToString: @"feedOffset"])
    {
		CABasicAnimation *animation = [CABasicAnimation animation];
        animation.duration = 0.5;
        return animation;
    }
    
    return [super defaultAnimationForKey:key];
}

- (void) startNewPage: (id)sender
{
    //The finished page stays exactly where it is and a new blank one is pushed in front
    //of it. (This used to copy the current page's contents onto a single "previous page"
    //layer and blank the current one, which kept one page of history; keeping a layer
    //per page is what makes rolling back through the whole printout possible.)
    [self _addPageLayer];
    [self rollToLivePosition: self];
    
    //Move the feed offset immediately by one page so that the previous page
    //lines up exactly with where the old current page was. Then, start a new
    //animation from that point to the top of the new page.
    [NSAnimationContext beginGrouping];
        [NSAnimationContext currentContext].duration = 0;
        [self.animator setFeedOffset: self.feedOffset - 1.0];
    [NSAnimationContext endGrouping];
    
    [self.animator setFeedOffset: 0.0];
}

@end
