/*
 Copyright (c) 2013 Alun Bestor and contributors. All rights reserved.
 This source file is released under the GNU General Public License 2.0. A full copy of this license
 can be found in this XCode project at Resources/English.lproj/BoxerHelp/pages/legalese.html, or read
 online at [http://www.gnu.org/licenses/gpl-2.0.txt].
 */

#import <Cocoa/Cocoa.h>
#import "BXCollectionItemView.h"

@class BXLauncherItem;

@protocol BXLauncherItemDelegate <NSObject>

- (void) openItemInDOS: (BXLauncherItem *)item;
- (void) revealItemInFinder: (BXLauncherItem *)item;
- (void) removeItem: (BXLauncherItem *)item;

- (BOOL) canOpenItemInDOS: (BXLauncherItem *)item;
- (BOOL) canRevealItemInFinder: (BXLauncherItem *)item;
- (BOOL) canRemoveItem: (BXLauncherItem *)item;

@end

@interface BXLaunchPanelController : NSViewController <NSCollectionViewDelegate, NSTextFieldDelegate, BXLauncherItemDelegate>

@property (strong, nonatomic) IBOutlet NSCollectionView *launcherList;
@property (strong, nonatomic) IBOutlet NSScrollView *launcherScrollView;
@property (strong, nonatomic) IBOutlet NSSearchField *filter;

/// An array of NSDictionaries for every item to display in the list.
@property (readonly, strong, nonatomic) NSMutableArray<NSDictionary*> *displayedRows;

/// An array of sanitised NSStrings derived from the contents of the search field.
@property (readonly, strong, nonatomic) NSMutableArray<NSString*> *filterKeywords;

#pragma mark - Actions

- (IBAction) enterSearchText: (NSSearchField *)sender;

/// Called by `BXDOSWindowController` when it is about to switch to/away from the launcher panel.
/// Causes it to (re-)populate its program list.
- (void) willShowPanel;
- (void) didHidePanel;

@end


@class BXLauncherItem;
/// A custom collection view that uses a different prototype for drive 'headings',
/// and that supports keyboard navigation: it takes focus from the search field on tab,
/// moves a selection with the arrow keys (skipping heading rows) and launches the
/// selected row on return.
@interface BXLauncherList : NSCollectionView

@property (strong, nonatomic) IBOutlet BXLauncherItem *headingPrototype;
@property (strong, nonatomic) IBOutlet BXLauncherItem *favoritePrototype;

/// Whether the selection should be drawn as the thing that will be launched even while
/// the list itself does not have focus. Set while a search is narrowing the list, because
/// return in the search field launches the selected row from there.
@property (assign, nonatomic) BOOL highlightsSelectionWhileUnfocused;

/// Whether the selected row is currently the one that return would launch — either
/// because the list has focus, or because a search is active.
@property (readonly, nonatomic) BOOL drawsSelectionAsActive;

/// The index of the currently selected row, or `NSNotFound` if nothing is selected.
@property (readonly, nonatomic) NSUInteger selectedRowIndex;

/// Selects the specified row and scrolls it into view. Pass `NSNotFound` to deselect.
/// Does nothing if the index is out of range or the row is a heading.
- (void) selectRowAtIndex: (NSUInteger)index;

/// Selects the first row that is not a heading, if any. Called when the list takes focus
/// with nothing selected yet.
- (void) selectFirstSelectableRow;

/// Launches the selected row, if there is one and it can be launched right now.
- (IBAction) launchSelectedRow: (id)sender;

@end

@class BXLauncherItemView;
@interface BXLauncherItem : BXCollectionItem
@property (weak, nonatomic) IBOutlet id <BXLauncherItemDelegate> delegate;
@property (assign, nonatomic, getter=isLaunchable) BOOL launchable;
/// The context menu to display for this item.
@property (strong, atomic) IBOutlet NSMenu *menu;

- (IBAction) openItemInDOS: (id)sender;
- (IBAction) revealItemInFinder: (id)sender;
- (IBAction) removeItem: (id)sender;

/// Returns the menu which the specified view should display when right-clicked.
///
/// Allows the launcher item to customise the menu based on the contents of its represented object.
- (NSMenu *) menuForView: (BXLauncherItemView *)view;
@end

/// A base class for launcher items that registers mouse-hover events.
@interface BXLauncherItemView : BXCollectionItemView

/// Typecast to indicate the type of delegate this view expects.
@property (weak, nonatomic) BXLauncherItem *delegate;

/// Whether the mouse cursor is currently inside the view.
@property (assign, nonatomic, getter=isMouseInside) BOOL mouseInside;

/// Whether the item is in the process of being clicked on or otherwise triggered.
@property (assign, nonatomic, getter=isActive) BOOL active;

/// Whether the item is able to be activated.
@property (assign, nonatomic, getter=isEnabled) BOOL enabled;
@end

/// Handles the custom appearance and input behaviour of regular program items.
@interface BXLauncherRegularItemView : BXLauncherItemView
@end

/// Handles the custom appearance and input behaviour of favorites.
@interface BXLauncherFavoriteView : BXLauncherRegularItemView
@end

/// Handles the behaviour of launcher heading rows.
@interface BXLauncherHeadingView : BXLauncherItemView
@end


/// Draws the background of the navigation strip at the top of the launch panel
@interface BXLauncherNavigationHeader : NSView
@end
