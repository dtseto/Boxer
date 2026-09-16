/*
 Copyright (c) 2013 Alun Bestor and contributors. All rights reserved.
 This source file is released under the GNU General Public License 2.0. A full copy of this license
 can be found in this XCode project at Resources/English.lproj/BoxerHelp/pages/legalese.html, or read
 online at [http://www.gnu.org/licenses/gpl-2.0.txt].
 */


#import <Cocoa/Cocoa.h>
#import <QuartzCore/CALayer.h>
#import "BXEmulatedPrinter.h"

@class BXPrintPreview;

@interface BXPrintStatusPanelController : NSWindowController

/// The number of pages printed so far, including the current page.
@property (assign, nonatomic) NSUInteger numPages;

/// Whether the current page is still being printed.
@property (assign, nonatomic, getter=isInProgress) BOOL inProgress;

/// The localized descriptive name of the paper type the user should select in DOS.
@property (copy, nonatomic) NSString *localizedPaperName;

/// Which printer port the emulated printer is attached to.
@property (assign, nonatomic) BXEmulatedPrinterPort activePrinterPort;

/// The preview view into which page previews will be rendered.
@property (strong, nonatomic) IBOutlet BXPrintPreview *preview;

/// State properties for UI bindings
/// The bold status text to display in the panel: e.g. "Printer is idle", "Printing page 6", etc.
@property (copy, readonly, nonatomic) NSString *printerStatus;

/// The small explanatory text to display in the panel,
/// explaining which port to print to and which paper size to use.
@property (copy, readonly, nonatomic) NSString *printerInstructions;

/// Whether any pages have been printed so far.
@property (readonly, nonatomic) BOOL hasPages;

/// Whether the "Print" button should be enabled. Will return NO while printing is in progress.
@property (readonly, nonatomic) BOOL canPrint;

@end


@interface BXPrintPreview : NSView <CALayerDelegate>

/// The preview image for the current page.
@property (strong, nonatomic) NSImage *currentPagePreview;
/// The preview image for the previous page.
@property (strong, nonatomic) NSImage *previousPagePreview;

/// The X offset of the print head, as a percentage of
/// the total printable page width from 0.0 to 1.0.
@property (assign, nonatomic) CGFloat headOffset;

/// The Y offset of the paper head, as a percentage of
/// the total printable page height from 0.0 to 1.0.
@property (assign, nonatomic) CGFloat feedOffset;

/// How far the paper has been rolled back by hand, in points. 0 is the live position,
/// where the current page sits at the print head. Larger values roll the paper up to
/// reveal earlier pages, exactly as turning the platen knob on a real printer would.
@property (assign, nonatomic) CGFloat rollOffset;

/// The furthest the paper can be rolled back: far enough to bring the top of the
/// oldest printed page into view.
@property (readonly, nonatomic) CGFloat maxRollOffset;

/// Makes the current page into the previous page,
/// makes the current page blank, and moves the head
/// to the top of the current page. Earlier pages are kept so they can be rolled back to.
- (IBAction) startNewPage: (id)sender;

/// Rolls the paper back to the live printing position.
- (IBAction) rollToLivePosition: (id)sender;

/// Throws away every page, for the start of a new print session.
- (void) resetPages;

/// Move the head to the specified offset with a smooth animation.
- (void) animateHeadToOffset: (CGFloat)headOffset;
/// Move the paper to the specified offset with a smooth animation.
- (void) animateFeedToOffset: (CGFloat)feedOffset;

@end
