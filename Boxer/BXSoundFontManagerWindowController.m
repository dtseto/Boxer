#import "BXSoundFontManagerWindowController.h"
#import "BXEmulatorCore.h"
#include <string.h>

static NSURL *BXManagedSoundFontsURL(void)
{
    NSArray *urls = [[NSFileManager defaultManager] URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask];
    return [[urls.firstObject URLByAppendingPathComponent:@"Boxer" isDirectory:YES]
            URLByAppendingPathComponent:@"SoundFonts" isDirectory:YES];
}

@interface BXSoundFontManagerWindowController ()
@property(nonatomic,strong) NSStackView *stack;
@end

@implementation BXSoundFontManagerWindowController

+ (instancetype)controller
{
    static BXSoundFontManagerWindowController *controller;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        controller = [[self alloc] initWithWindow:nil];
    });
    return controller;
}

- (instancetype)initWithWindow:(NSWindow *)window
{
    NSWindow *soundFontWindow = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 560, 420)
                                                              styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                                                                backing:NSBackingStoreBuffered
                                                                  defer:NO];
    soundFontWindow.title = @"SoundFonts";
    self = [super initWithWindow:soundFontWindow];
    if (self) {
        NSView *content = soundFontWindow.contentView;
        NSTextField *help = [NSTextField labelWithString:@"SoundFonts are used by FluidSynth, Boxer’s built-in General MIDI synthesiser. GeneralUser GS is recommended."];
        help.maximumNumberOfLines = 0;
        help.lineBreakMode = NSLineBreakByWordWrapping;
        help.frame = NSMakeRect(20, 365, 520, 40);
        [content addSubview:help];

        self.stack = [[NSStackView alloc] initWithFrame:NSMakeRect(20, 80, 520, 270)];
        self.stack.orientation = NSUserInterfaceLayoutOrientationVertical;
        self.stack.alignment = NSLayoutAttributeLeading;
        self.stack.spacing = 6;
        [content addSubview:self.stack];

        NSButton *add = [NSButton buttonWithTitle:@"Add SoundFont…" target:self action:@selector(addSoundFont:)];
        add.frame = NSMakeRect(20, 25, 160, 28);
        [content addSubview:add];
    }
    return self;
}

- (void)showWindow:(id)sender
{
    [self refresh];
    [super showWindow:sender];
}

- (void)refresh
{
    NSURL *directory = BXManagedSoundFontsURL();
    [[NSFileManager defaultManager] createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil error:NULL];
    [self.stack.arrangedSubviews makeObjectsPerformSelector:@selector(removeFromSuperview)];

    NSArray *urls = [[NSFileManager defaultManager] contentsOfDirectoryAtURL:directory
                                                     includingPropertiesForKeys:@[NSURLFileSizeKey]
                                                                        options:NSDirectoryEnumerationSkipsHiddenFiles
                                                                          error:NULL];
    for (NSURL *url in [urls sortedArrayUsingComparator:^NSComparisonResult(NSURL *a, NSURL *b) {
        return [a.lastPathComponent localizedCaseInsensitiveCompare:b.lastPathComponent];
    }]) {
        if (![url.pathExtension.lowercaseString isEqualToString:@"sf2"])
            continue;
        NSNumber *size = nil;
        [url getResourceValue:&size forKey:NSURLFileSizeKey error:NULL];
        NSStackView *row = [[NSStackView alloc] initWithFrame:NSZeroRect];
        row.orientation = NSUserInterfaceLayoutOrientationHorizontal;
        row.spacing = 8;
        NSTextField *name = [NSTextField labelWithString:[NSString stringWithFormat:@"%@ (%llu KB)", url.lastPathComponent, size.unsignedLongLongValue / 1024]];
        name.frame = NSMakeRect(0, 0, 330, 24);
        [row addArrangedSubview:name];

        NSButton *defaultButton = [NSButton buttonWithTitle:@"Set as Default" target:self action:@selector(setDefault:)];
        defaultButton.identifier = url.lastPathComponent;
        [row addArrangedSubview:defaultButton];

        NSButton *removeButton = [NSButton buttonWithTitle:@"Remove" target:self action:@selector(removeSoundFont:)];
        removeButton.identifier = url.lastPathComponent;
        [row addArrangedSubview:removeButton];
        [self.stack addArrangedSubview:row];
    }
}

- (void)addSoundFont:(id)sender
{
    (void)sender;
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.allowsMultipleSelection = YES;
    panel.allowedFileTypes = @[@"sf2"];
    if ([panel runModal] != NSModalResponseOK)
        return;

    NSURL *directory = BXManagedSoundFontsURL();
    [[NSFileManager defaultManager] createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil error:NULL];
    for (NSURL *source in panel.URLs) {
        NSData *header = [NSData dataWithContentsOfURL:source options:NSDataReadingMappedIfSafe error:NULL];
        if (header.length < 12 ||
            memcmp(header.bytes, "RIFF", 4) != 0 ||
            memcmp((const uint8_t *)header.bytes + 8, "sfbk", 4) != 0)
            continue;
        NSURL *destination = [directory URLByAppendingPathComponent:source.lastPathComponent];
        [[NSFileManager defaultManager] removeItemAtURL:destination error:NULL];
        [[NSFileManager defaultManager] copyItemAtURL:source toURL:destination error:NULL];
    }
    [self refresh];
}

- (void)setDefault:(NSButton *)sender
{
    [BXEmulatorCore setDefaultSoundFontName:sender.identifier];
}

- (void)removeSoundFont:(NSButton *)sender
{
    NSURL *url = [BXManagedSoundFontsURL() URLByAppendingPathComponent:sender.identifier];
    [[NSFileManager defaultManager] trashItemAtURL:url resultingItemURL:NULL error:NULL];
    [self refresh];
}

@end
