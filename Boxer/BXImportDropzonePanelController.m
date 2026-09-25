/* 
 Copyright (c) 2013 Alun Bestor and contributors. All rights reserved.
 This source file is released under the GNU General Public License 2.0. A full copy of this license
 can be found in this XCode project at Resources/English.lproj/BoxerHelp/pages/legalese.html, or read
 online at [http://www.gnu.org/licenses/gpl-2.0.txt].
 */


#import "BXImportDropzonePanelController.h"
#import "BXImportWindowController.h"
#import "BXImportDropzone.h"
#import "BXImportSession.h"
#import "BXBlueprintPanel.h"
#import "BXAppController.h"

#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>


@implementation BXImportDropzonePanelController

#pragma mark -
#pragma mark Initialization and deallocation

- (void) awakeFromNib
{
	//Set up the dropzone panel to support drag-drop operations
	[self.view registerForDraggedTypes: @[NSPasteboardTypeFileURL]];
    
    //Disabled as this was causing CATransaction errors.
    //self.spinner.usesThreadedAnimation = YES;
	//Since the spinner is on a separate view that's only added to the window
	//when it's spinnin' time, we can safely start it animating now
	[self.spinner startAnimation: self];
}


#pragma mark -
#pragma mark UI actions

- (IBAction) showImportPathPicker: (id)sender
{
	NSOpenPanel *openPanel	= [NSOpenPanel openPanel];
	
    openPanel.delegate = self;
    openPanel.canChooseFiles = YES;
    openPanel.canChooseDirectories = YES;
    openPanel.treatsFilePackagesAsDirectories = NO;
    openPanel.message = NSLocalizedString(@"Choose a DOS game folder, CD-ROM, disc image or zipped eXoDOS game to import:",
                                          @"Help text shown at the top of choose-a-folder-to-import panel.");
    
    openPanel.prompt = NSLocalizedString(@"Import",
                                         @"Label shown on accept button in choose-a-folder-to-import panel.");
	
    //allowedFileTypes has been deprecated since macOS 12 in favour of content
    //types, and it is the reason a zipped eXoDOS game could not be selected
    //here even though the importer accepts one: the drop target and this panel
    //are gated by the same +acceptedSourceTypes, so what one takes the other
    //should offer.
    NSMutableArray<UTType *> *contentTypes = [NSMutableArray array];
    for (NSString *identifier in [BXImportSession acceptedSourceTypes])
    {
        //Not every identifier the importer accepts is declared on the system:
        //com.apple.disk-image-ndif resolves to nil here, and dropping it would
        //quietly stop offering NDIF images that the old API accepted as a bare
        //string. An imported type stands in for one nothing has declared.
        UTType *type = [UTType typeWithIdentifier: identifier];
        if (!type) type = [UTType importedTypeWithIdentifier: identifier];
        if (type) [contentTypes addObject: type];
    }
    openPanel.allowedContentTypes = contentTypes;
    
    [openPanel beginSheetModalForWindow: self.view.window
                      completionHandler: ^(NSInteger result) {
                          if (result == NSModalResponseOK)
                          {
                              //Ensure the open panel is closed before we continue,
                              //in case importFromSourcePath: decides to display errors.
                              [openPanel orderOut: self];
                              
                              [self.controller.document importFromSourceURL: openPanel.URL];
                          }
                      }];
}

- (IBAction) showImportDropzoneHelp: (id)sender
{
	[(BXBaseAppController *)[NSApp delegate] showHelpAnchor: @"import-drop-game"];
}


#pragma mark -
#pragma mark Drag-drop handlers

- (NSDragOperation) draggingEntered: (id <NSDraggingInfo>)sender
{
	NSPasteboard *pboard = sender.draggingPasteboard;
    NSArray *dragClasses = @[[NSURL class]];
    NSDictionary *dragOptions = @{ NSPasteboardURLReadingFileURLsOnlyKey : @(YES) };
	if ([pboard canReadObjectForClasses: dragClasses options: dragOptions])
	{
		NSArray *droppedURLs = [pboard readObjectsForClasses: dragClasses
                                                     options: dragOptions];
        
		for (NSURL *URL in droppedURLs)
		{
			//If any of the dropped files cannot be imported, reject the drop.
			//Asked of the class, as the welcome window's drop target does: via
			//`self.controller.document.class` this would silently reject every
			//drop if the session were ever missing.
			if (![BXImportSession canImportFromSourceURL: URL])
                return NSDragOperationNone;
		}
		
        self.dropzone.highlighted = YES;
        
		return NSDragOperationCopy;
	}
	else return NSDragOperationNone;
}

- (BOOL) performDragOperation: (id <NSDraggingInfo>)sender
{
	NSPasteboard *pboard = sender.draggingPasteboard;
	
    NSArray *droppedURLs = [pboard readObjectsForClasses: @[[NSURL class]]
                                                 options: @{ NSPasteboardURLReadingFileURLsOnlyKey : @(YES) }];
    
    BXImportSession *importer = self.controller.document;
    for (NSURL *URL in droppedURLs)
    {
        if ([BXImportSession canImportFromSourceURL: URL])
        {
            //Defer import to give the drag operation and animations time to clean up
            [importer performSelector: @selector(importFromSourceURL:) withObject: URL afterDelay: 0.5];
            return YES;
        }
    }
    
	return NO;
}

- (void)draggingExited: (id <NSDraggingInfo>)sender
{
    self.dropzone.highlighted = NO;
}

@end
