#import "BXGameboxSettingsWindowController.h"
#import "BXEmulatorCore.h"
#import "BXConfigKey.h"
#import "BXGameboxConfigurationEditor.h"
#import "BXGamebox.h"
#import "BXSession.h"
#import "BXPreferencesController.h"

static NSInteger const BXCPUBase = 100;
static NSInteger const BXDOSBoxShaders = 200;
static NSInteger const BXOpenEmuShaders = 201;
static NSInteger const BXVersion080 = 400;
static NSInteger const BXVersion081 = 401;
static NSInteger const BXVersion0822 = 402;
static NSInteger const BXProtectedCPUCyclesMaximum = 300000;

@interface BXGameboxSettingsDocumentView : NSView
@end

@implementation BXGameboxSettingsDocumentView

- (BOOL)isFlipped
{
    return YES;
}

@end

@interface BXGameboxSettingsWindowController ()
@property(nonatomic,strong) BXGamebox *gamebox;
@property(nonatomic,weak) BXSession *session;
@property(nonatomic,strong) BXEmulatorCore *core;
@property(nonatomic,strong) BXGameboxConfigurationEditor *configurationEditor;
@property(nonatomic,strong) NSPopUpButton *cpuPopup;
@property(nonatomic,strong) NSPopUpButton *midiPopup;
@property(nonatomic,strong) NSPopUpButton *soundFontPopup;
@property(nonatomic,strong) NSTextField *soundFontWarning;
@property(nonatomic,strong) NSSlider *cpuCyclesSlider;
@property(nonatomic,strong) NSTextField *cpuCyclesLabel;
@property(nonatomic,strong) NSTextField *cpuCyclesValue;
@property(nonatomic,strong) NSButton *voodoo;
@property(nonatomic,strong) NSPopUpButton *voodooMemory;
@property(nonatomic,strong) NSButton *reelMagic;
@property(nonatomic,strong) NSButton *ess;
@property(nonatomic,strong) NSButton *adlibGold;
@property(nonatomic,strong) NSButton *ibmMFC;
@property(nonatomic,strong) NSPopUpButton *shaderSystem;
@property(nonatomic,strong) NSPopUpButton *shaderPreset;
@property(nonatomic,strong) NSButton *integerScaling;
@property(nonatomic,strong) NSButton *deinterlacing;
@property(nonatomic,strong) NSPopUpButton *versionPopup;
@property(nonatomic,strong) NSTextField *status;
@property(nonatomic,assign) BOOL installerPreflight;
@property(nonatomic,copy) void (^installerCompletion)(BOOL continueInstalling);
@end

@implementation BXGameboxSettingsWindowController

- (instancetype)initWithGamebox:(BXGamebox *)gamebox session:(BXSession *)session
{
    self = [super initWithWindow:nil];
    if (self) {
        _gamebox = gamebox;
        _session = session;
        _core = [[BXEmulatorCore alloc] initWithGamebox:gamebox session:session];
        _configurationEditor = [[BXGameboxConfigurationEditor alloc] initWithGamebox:gamebox core:_core];
    }
    return self;
}

- (void)loadWindow
{
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 600, 680)
                                                   styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                                                     backing:NSBackingStoreBuffered defer:NO];
    window.title = self.installerPreflight
        ? NSLocalizedString(@"Installer Hardware Settings", @"Installer hardware preflight title.")
        : NSLocalizedString(@"Gamebox Settings", @"Gamebox settings title.");
    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:window.contentView.bounds];
    scroll.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    scroll.hasVerticalScroller = YES;
    scroll.autohidesScrollers = NO;
    scroll.verticalScroller.scrollerStyle = NSScrollerStyleLegacy;
    NSView *document = [[BXGameboxSettingsDocumentView alloc] initWithFrame:NSMakeRect(0, 0, 560, 900)];
    NSStackView *stack = [[NSStackView alloc] initWithFrame:NSMakeRect(20, 20, 520, 850)];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeLeading;
    stack.spacing = 8;
    [document addSubview:stack];
    scroll.documentView = document;
    [scroll.contentView scrollToPoint:NSMakePoint(0, 0)];
    [scroll reflectScrolledClipView:scroll.contentView];
    [window.contentView addSubview:scroll];

    [stack addArrangedSubview:[self heading:@"CPU"]];
    self.cpuPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(0,0,500,26)];
    NSArray *titles = @[@"Auto", @"386", @"486", @"Pentium", @"Pentium MMX"];
    for (NSUInteger i=0; i<titles.count; i++) {
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:titles[i] action:NULL keyEquivalent:@""];
        item.tag = BXCPUBase + i;
        [self.cpuPopup.menu addItem:item];
    }
    [self.cpuPopup selectItemWithTag:BXCPUBase + self.core.currentCPUType];
    self.cpuPopup.target = self; self.cpuPopup.action = @selector(cpuChanged:);
    [stack addArrangedSubview:self.cpuPopup];

    if (self.core.supportsFluidSynth) {
        [stack addArrangedSubview:[self heading:@"MIDI"]];
        NSStackView *midiRow = [self row:@"MIDI device:"];
        self.midiPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(0, 0, 300, 26)];
        [self.midiPopup addItemsWithTitles:@[@"None", @"MT-32", @"FluidSynth (General MIDI)"]];
        self.midiPopup.target = self;
        self.midiPopup.action = @selector(midiDeviceChanged:);
        [midiRow addArrangedSubview:self.midiPopup];
        [stack addArrangedSubview:midiRow];

        NSStackView *soundFontRow = [self row:@"SoundFont:"];
        self.soundFontPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(0, 0, 300, 26)];
        self.soundFontPopup.target = self;
        self.soundFontPopup.action = @selector(soundFontChanged:);
        [soundFontRow addArrangedSubview:self.soundFontPopup];
        [stack addArrangedSubview:soundFontRow];
        self.soundFontWarning = [NSTextField labelWithString:@""];
        self.soundFontWarning.maximumNumberOfLines = 0;
        self.soundFontWarning.lineBreakMode = NSLineBreakByWordWrapping;
        [stack addArrangedSubview:self.soundFontWarning];
        NSButton *manageSoundFonts = [NSButton buttonWithTitle:@"Manage SoundFonts…" target:self action:@selector(manageSoundFonts:)];
        [stack addArrangedSubview:manageSoundFonts];
        [self refreshMIDIDeviceControls];
    }

    NSStackView *cpuCyclesRow = [[NSStackView alloc] initWithFrame:NSZeroRect];
    cpuCyclesRow.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    cpuCyclesRow.spacing = 8;
    self.cpuCyclesLabel = [NSTextField labelWithString:@""];
    self.cpuCyclesLabel.frame = NSMakeRect(0, 0, 180, 22);
    [cpuCyclesRow addArrangedSubview:self.cpuCyclesLabel];
    self.cpuCyclesSlider = [[NSSlider alloc] initWithFrame:NSMakeRect(0, 0, 260, 22)];
    self.cpuCyclesSlider.minValue = 0;
    self.cpuCyclesSlider.maxValue = BXProtectedCPUCyclesMaximum;
    self.cpuCyclesSlider.target = self;
    self.cpuCyclesSlider.action = @selector(cpuCyclesChanged:);
    self.cpuCyclesSlider.continuous = NO;
    self.cpuCyclesValue = [NSTextField labelWithString:@""];
    [cpuCyclesRow addArrangedSubview:self.cpuCyclesSlider];
    [cpuCyclesRow addArrangedSubview:self.cpuCyclesValue];
    [stack addArrangedSubview:cpuCyclesRow];
    [self refreshProtectedCPUCyclesControl];

    [stack addArrangedSubview:[self heading:@"Advanced"]];
    if (self.installerPreflight) {
        NSTextField *explanation = [NSTextField labelWithString:NSLocalizedString(@"Choose the hardware this installer expects. These settings are applied before DOSBox starts, so the installer can detect the selected devices.", @"Installer hardware preflight explanation.")];
        explanation.maximumNumberOfLines = 0;
        explanation.lineBreakMode = NSLineBreakByWordWrapping;
        [stack addArrangedSubview:explanation];
    }
    if (self.core.supportsVoodoo) {
        self.voodoo = [self checkbox:@"Enable 3dfx Voodoo" action:@selector(voodooChanged:)];
        self.voodoo.state = self.core.voodooEnabledForCurrentGamebox;
        [stack addArrangedSubview:self.voodoo];
        NSStackView *row = [self row:@"Voodoo memory:"];
        self.voodooMemory = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(0,0,220,26)];
        [self.voodooMemory addItemsWithTitles:@[@"2 MB", @"4 MB"]];
        [self.voodooMemory selectItemAtIndex:self.core.voodooMemorySizeForCurrentGamebox == 2 ? 0 : 1];
        self.voodooMemory.target = self; self.voodooMemory.action = @selector(voodooMemoryChanged:);
        [row addArrangedSubview:self.voodooMemory]; [stack addArrangedSubview:row];
    }
    if (self.core.supportsReelMagic) {
        self.reelMagic = [self checkbox:@"Enable ReelMagic" action:@selector(reelMagicChanged:)];
        self.reelMagic.state = self.core.reelMagicEnabledForCurrentGamebox;
        [stack addArrangedSubview:self.reelMagic];
    }
    if (self.core.supportsESSAudio) {
        self.ess = [self checkbox:@"Use ESS Enhanced FM audio" action:@selector(essChanged:)];
        self.ess.state = self.core.essEnabledForCurrentGamebox;
        [stack addArrangedSubview:self.ess];
    }
    if (self.core.supportsAdLibGold) {
        self.adlibGold = [self checkbox:@"Enable AdLib Gold 1000" action:@selector(adlibGoldChanged:)];
        self.adlibGold.state = self.core.adLibGoldEnabledForCurrentGamebox;
        self.adlibGold.toolTip = @"Uses DOSBox Staging opl3gold mode with Sound Blaster 16 compatibility.";
        [stack addArrangedSubview:self.adlibGold];
    }
    if (self.core.supportsIBMMusicFeatureCard) {
        self.ibmMFC = [self checkbox:@"Enable IBM Music Feature Card" action:@selector(ibmMFCChanged:)];
        self.ibmMFC.state = self.core.ibmMFCEnabledForCurrentGamebox;
        [stack addArrangedSubview:self.ibmMFC];
    }

    if (!self.installerPreflight) {
    [stack addArrangedSubview:[self heading:@"Shader System"]];
    self.shaderSystem = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(0,0,500,26)];
    [self.shaderSystem addItemWithTitle:@"DOSBox Staging (Recommended)"]; self.shaderSystem.itemArray.lastObject.tag = BXDOSBoxShaders;
    [self.shaderSystem addItemWithTitle:@"Boxer / OpenEmu (Legacy)"]; self.shaderSystem.itemArray.lastObject.tag = BXOpenEmuShaders;
    NSMenuItem *stagingItem = self.shaderSystem.itemArray.firstObject;
    stagingItem.enabled = NO;
    stagingItem.toolTip = @"DOSBox Staging shaders are temporarily unavailable.";
    [self.shaderSystem selectItemWithTag:BXOpenEmuShaders];
    self.shaderSystem.target = self; self.shaderSystem.action = @selector(shaderSystemChanged:);
    // DOSBox Staging shader execution is intentionally unavailable until its
    // native renderer is connected to Boxer's Metal presentation path.
    // Keep the visible selection and all preset handling on Boxer/OpenEmu.
    self.shaderSystem.enabled = YES;
    [stack addArrangedSubview:self.shaderSystem];

    NSStackView *presetRow = [self row:@"Shader preset:"];
    self.shaderPreset = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(0,0,320,26)];
    self.shaderPreset.target = self; self.shaderPreset.action = @selector(shaderPresetChanged:);
    [presetRow addArrangedSubview:self.shaderPreset]; [stack addArrangedSubview:presetRow];

    self.integerScaling = [self checkbox:@"Integer scaling" action:@selector(integerScalingChanged:)];
    self.integerScaling.enabled = self.core.supportsIntegerScaling;
    self.integerScaling.state = self.core.integerScalingEnabledForCurrentGamebox
        ? NSControlStateValueOn
        : NSControlStateValueOff;
    self.integerScaling.toolTip = @"Use integer scaling for the gamebox video output.";
    [stack addArrangedSubview:self.integerScaling];
    self.deinterlacing = [self checkbox:@"Deinterlacing" action:@selector(deinterlacingChanged:)];
    self.deinterlacing.enabled = NO;
    self.deinterlacing.toolTip = @"Available when DOSBox Staging shader support is enabled.";
    [stack addArrangedSubview:self.deinterlacing];
    [self refreshShaders];
    }

    if (!self.installerPreflight && self.core.maximumMouseCount > 1) {
        [stack addArrangedSubview:[self heading:@"Input"]];
        NSStackView *row = [self row:@"Independent mice:"];
        NSPopUpButton *mouse = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(0,0,220,26)];
        for (NSUInteger i=1; i<=self.core.maximumMouseCount; i++) {
            [mouse addItemWithTitle:[NSString stringWithFormat:@"%lu",(unsigned long)i]];
            mouse.itemArray.lastObject.tag = i;
        }
        [mouse selectItemWithTag:self.core.currentMouseCount];
        mouse.target = self; mouse.action = @selector(mouseChanged:);
        [row addArrangedSubview:mouse]; [stack addArrangedSubview:row];
    }

    if (!self.installerPreflight) {
    [stack addArrangedSubview:[self heading:@"Sharing"]];
    NSStackView *versionRow = [self row:@"Target Boxer version:"];
    self.versionPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(0,0,180,26)];
    [self.versionPopup addItemWithTitle:@"0.80"]; self.versionPopup.itemArray.lastObject.tag = BXVersion080;
    [self.versionPopup addItemWithTitle:@"0.81"]; self.versionPopup.itemArray.lastObject.tag = BXVersion081;
    [self.versionPopup addItemWithTitle:@"0.82.2"]; self.versionPopup.itemArray.lastObject.tag = BXVersion0822;
    [self.versionPopup selectItemWithTag:BXVersion081];
    [versionRow addArrangedSubview:self.versionPopup]; [stack addArrangedSubview:versionRow];

    NSStackView *buttons = [[NSStackView alloc] initWithFrame:NSZeroRect];
    buttons.orientation = NSUserInterfaceLayoutOrientationHorizontal; buttons.spacing = 8;
    [buttons addArrangedSubview:[NSButton buttonWithTitle:@"Remove Newer Settings" target:self action:@selector(removeNewer:)]];
    [buttons addArrangedSubview:[NSButton buttonWithTitle:@"Clear All Overrides" target:self action:@selector(clearAll:)]];
    [stack addArrangedSubview:buttons];

    NSButton *saveButton = [NSButton buttonWithTitle:@"Save Settings"
                                               target:self
                                               action:@selector(saveSettings:)];
    saveButton.keyEquivalent = @"\\r";
    [stack addArrangedSubview:saveButton];
    }
    self.status = [NSTextField labelWithString:@""];
    self.status.maximumNumberOfLines = 3; [stack addArrangedSubview:self.status];

    if (self.installerPreflight) {
        NSStackView *installerButtons = [[NSStackView alloc] initWithFrame:NSZeroRect];
        installerButtons.orientation = NSUserInterfaceLayoutOrientationHorizontal;
        installerButtons.spacing = 8;
        NSButton *cancel = [NSButton buttonWithTitle:NSLocalizedString(@"Cancel Import", @"Cancel installer preflight.")
                                               target:self
                                               action:@selector(cancelInstallerPreflight:)];
        NSButton *continueButton = [NSButton buttonWithTitle:NSLocalizedString(@"Continue to Installer", @"Continue installer preflight.")
                                                       target:self
                                                       action:@selector(continueInstallerPreflight:)];
        continueButton.keyEquivalent = @"\r";
        [installerButtons addArrangedSubview:cancel];
        [installerButtons addArrangedSubview:continueButton];
        [stack addArrangedSubview:installerButtons];
        window.styleMask &= ~NSWindowStyleMaskClosable;
    }

    self.window = window;
    [window center];
}

- (void)beginInstallerPreflightSheetForWindow:(NSWindow *)parentWindow
                            completionHandler:(void (^)(BOOL))completionHandler
{
    self.installerPreflight = YES;
    self.installerCompletion = completionHandler;
    // This controller builds its window programmatically. Explicitly load it here;
    // NSWindowController does not guarantee that a nil-window initializer has
    // loaded an overridden loadWindow method before a sheet is begun.
    if (!self.window)
        [self loadWindow];
    NSWindow *window = self.window;
    if (!window) {
        if (completionHandler)
            completionHandler(NO);
        return;
    }
    if (parentWindow)
        [parentWindow beginSheet:window completionHandler:nil];
    else
        [self showWindow:nil];
}

- (void)_finishInstallerPreflightWithResult:(BOOL)continueInstalling
{
    void (^completion)(BOOL) = [self.installerCompletion copy];
    self.installerCompletion = nil;
    if (self.window.sheetParent)
        [self.window.sheetParent endSheet:self.window returnCode:continueInstalling ? NSModalResponseOK : NSModalResponseCancel];
    else
        [self close];
    if (completion)
        completion(continueInstalling);
}

- (void)continueInstallerPreflight:(id)sender
{
    (void)sender;
    [self _finishInstallerPreflightWithResult:YES];
}

- (void)cancelInstallerPreflight:(id)sender
{
    (void)sender;
    [self _finishInstallerPreflightWithResult:NO];
}

- (NSTextField *)heading:(NSString *)title { NSTextField *f=[NSTextField labelWithString:title]; f.font=[NSFont boldSystemFontOfSize:[NSFont systemFontSize]]; return f; }
- (NSButton *)checkbox:(NSString *)title action:(SEL)action { NSButton *b=[NSButton checkboxWithTitle:title target:self action:action]; b.controlSize=NSControlSizeSmall; return b; }
- (NSStackView *)row:(NSString *)title {
    NSStackView *r=[[NSStackView alloc] initWithFrame:NSZeroRect]; r.orientation=NSUserInterfaceLayoutOrientationHorizontal; r.spacing=8;
    NSTextField *f=[NSTextField labelWithString:title]; f.frame=NSMakeRect(0,0,180,22); [r addArrangedSubview:f]; return r;
}
- (NSString *)displayNameForShaderPreset:(NSString *)preset {
    NSDictionary *names = @{
        @"crt-auto": @"CRT — Automatic",
        @"crt-auto-machine": @"CRT — Automatic (Machine)",
        @"crt-auto-arcade": @"CRT — Automatic (Arcade)",
        @"sharp": @"Sharp",
        @"custom": @"Custom GLSL"
    };
    return names[preset] ?: preset;
}
- (void)refreshShaders {
    [self.shaderPreset removeAllItems];
    NSArray *paths = [self openEmuShaderPaths];
    if (!paths.count) {
        [self.shaderPreset addItemWithTitle:@"OpenEmu Default"];
    } else {
        for (NSString *path in paths) {
            NSString *title = path.lastPathComponent.stringByDeletingPathExtension;
            [self.shaderPreset addItemWithTitle:title];
            self.shaderPreset.itemArray.lastObject.representedObject = path;
        }
        NSString *selected = [[NSUserDefaults standardUserDefaults] stringForKey:@"shaderPresetPath"];
        if (selected.length == 0)
            selected = [[NSUserDefaults standardUserDefaults] stringForKey:@"videoShader"];
        for (NSMenuItem *item in self.shaderPreset.itemArray) {
            if ([item.representedObject isEqual:selected] || [item.title isEqual:selected]) {
                [self.shaderPreset selectItem:item];
                break;
            }
        }
    }
    self.shaderPreset.enabled = YES;
    self.integerScaling.hidden = NO;
    self.deinterlacing.hidden = NO;
}
- (NSArray *)openEmuShaderPaths {
    NSURL *url=[[[NSBundle mainBundle] resourceURL] URLByAppendingPathComponent:@"Shaders" isDirectory:YES];
    NSDirectoryEnumerator *enumerator = [[NSFileManager defaultManager]
        enumeratorAtURL:url
        includingPropertiesForKeys:@[NSURLIsRegularFileKey]
        options:NSDirectoryEnumerationSkipsHiddenFiles
        errorHandler:NULL];
    NSMutableArray *result=[NSMutableArray array];
    for (NSURL *child in enumerator) {
        NSNumber *regular = nil;
        [child getResourceValue:&regular forKey:NSURLIsRegularFileKey error:NULL];
        if (!regular.boolValue || ![child.pathExtension.lowercaseString isEqualToString:@"slangp"])
            continue;
        NSString *relative = [child.path substringFromIndex:url.path.length];
        [result addObject:[relative stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"/"]]];
    }
    return [result sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
}
- (void)cpuChanged:(NSPopUpButton *)sender { [self.core setCPUType:(BXCPUType)(sender.selectedTag-BXCPUBase)]; }

- (void)refreshMIDIDeviceControls
{
    BXMIDIDevice device = self.core.currentMIDIDevice;
    [self.midiPopup selectItemAtIndex:device == BXMIDIDeviceMT32 ? 1 : (device == BXMIDIDeviceFluidSynth ? 2 : 0)];
    [self.soundFontPopup removeAllItems];
    NSArray *soundFonts = self.core.availableSoundFonts;
    [self.soundFontPopup addItemsWithTitles:soundFonts];
    NSString *selected = self.core.soundFontForCurrentGamebox;
    if (selected.length && [soundFonts containsObject:selected])
        [self.soundFontPopup selectItemWithTitle:selected];
    self.soundFontPopup.enabled = device == BXMIDIDeviceFluidSynth;
    NSString *soundFontOverride = self.core.soundFontOverrideForCurrentGamebox;
    BOOL missingOverride = soundFontOverride.length > 0 && ![soundFonts containsObject:soundFontOverride];
    self.soundFontWarning.stringValue = device == BXMIDIDeviceFluidSynth && soundFonts.count == 0
        ? @"No SoundFonts are installed. Add one in the main Audio preferences."
        : (missingOverride ? @"The selected SoundFont is missing; FluidSynth will use the default." : @"");
}

- (void)midiDeviceChanged:(NSPopUpButton *)sender
{
    [self.core setMIDIDevice:(BXMIDIDevice)(NSUInteger)sender.indexOfSelectedItem];
    [self refreshMIDIDeviceControls];
}

- (void)soundFontChanged:(NSPopUpButton *)sender
{
    [self.core setSoundFont:sender.titleOfSelectedItem];
}

- (void)manageSoundFonts:(id)sender
{
    (void)sender;
    [[BXPreferencesController controller] showWindow:self];
}

- (void)refreshProtectedCPUCyclesControl
{
    NSUInteger cycles = self.core.hasProtectedCPUCyclesOverrideForCurrentGamebox
        ? self.core.protectedCPUCyclesForCurrentGamebox
        : 0;
    cycles = MIN(cycles, BXProtectedCPUCyclesMaximum);
    self.cpuCyclesSlider.integerValue = cycles;
    self.cpuCyclesLabel.stringValue = @"Protected-mode cycles:";
    self.cpuCyclesValue.stringValue = cycles > 0
        ? [NSString stringWithFormat:@"%lu", (unsigned long)cycles]
        : @"N/A — follows default";
}

- (void)cpuCyclesChanged:(NSSlider *)sender
{
    NSUInteger cycles = (NSUInteger)llround(sender.doubleValue);
    [self.core setProtectedCPUCycles:cycles];
    [self refreshProtectedCPUCyclesControl];
}

- (void)voodooChanged:(NSButton *)sender
{
    [self.core setVoodooEnabled:sender.state == NSControlStateValueOn];
}

- (void)saveSettings:(id)sender
{
    (void)sender;
    NSError *error = nil;
    if ([self.configurationEditor saveCurrentConfigurationWithError:&error])
        self.status.stringValue = @"Settings saved to the gamebox.";
    else
        [self showError:error];
}
- (void)voodooMemoryChanged:(NSPopUpButton *)sender { [self.core setVoodooMemorySize:sender.indexOfSelectedItem==0?2:4]; }
- (void)reelMagicChanged:(NSButton *)sender { [self.core setReelMagicEnabled:sender.state==NSControlStateValueOn]; }
- (void)essChanged:(NSButton *)sender { [self.core setESSEnabled:sender.state==NSControlStateValueOn]; }
- (void)adlibGoldChanged:(NSButton *)sender { [self.core setAdLibGoldEnabled:sender.state==NSControlStateValueOn]; }
- (void)ibmMFCChanged:(NSButton *)sender { [self.core setIBMMFCEnabled:sender.state==NSControlStateValueOn]; }
- (void)shaderSystemChanged:(NSPopUpButton *)sender {
    (void)sender;
    [self.shaderSystem selectItemWithTag:BXOpenEmuShaders];
    [self.core setShaderSystem:BXShaderSystemOpenEmu];
    [self refreshShaders];
}
- (void)shaderPresetChanged:(NSPopUpButton *)sender {
    if (self.core.currentShaderSystem==BXShaderSystemDOSBoxStaging)
        return;
    NSString *path = sender.selectedItem.representedObject;
    if (path.length > 0) {
        [[NSUserDefaults standardUserDefaults] setObject:path forKey:@"shaderPresetPath"];
        [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"videoShader"];
    }
}
- (void)integerScalingChanged:(NSButton *)sender
{
    [self.core setIntegerScalingEnabled:sender.state == NSControlStateValueOn];
}
- (void)deinterlacingChanged:(NSButton *)sender { (void)sender; }
- (void)mouseChanged:(NSPopUpButton *)sender { [self.core setMouseCount:sender.selectedTag]; }
- (BXStagingVersion)selectedVersion { return self.versionPopup.selectedTag==BXVersion080?BXStagingVersion080:(self.versionPopup.selectedTag==BXVersion0822?BXStagingVersion0822:BXStagingVersion081); }
- (void)clearAll:(id)sender {
    NSMutableArray *names=[NSMutableArray array];
    for (BXConfigKey *key in self.configurationEditor.currentVersionSpecificOverrides)
        [names addObject:[self.core displayNameForConfigKey:key]];
    NSString *summary = names.count ? [NSString stringWithFormat:@"Known affected settings:\n• %@\n\nOther older-compatible overrides and startup commands, if present, will also be removed.", [names componentsJoinedByString:@"\n• "]] : @"All per-gamebox configuration settings and startup commands will be removed.";
    NSAlert *a=[NSAlert new]; a.messageText=@"Clear all gamebox overrides?"; a.informativeText=[NSString stringWithFormat:@"%@\n\nThe original configuration will be backed up first.", summary]; [a addButtonWithTitle:@"Clear Overrides"]; [a addButtonWithTitle:@"Cancel"];
    [a beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse code){ if(code!=NSAlertFirstButtonReturn)return; NSURL *backup=nil; NSError *error=nil; if([self.configurationEditor clearAllOverridesWithBackupURL:&backup error:&error]) [self showResult:@"All overrides cleared." backup:backup]; else [self showError:error]; }];
}
- (void)removeNewer:(id)sender {
    NSArray *keys=[self.configurationEditor currentOverridesNewerThanVersion:[self selectedVersion]];
    if (!keys.count) { self.status.stringValue=@"No newer overrides are present in this gamebox."; return; }
    NSMutableArray *names=[NSMutableArray arrayWithCapacity:keys.count];
    for (BXConfigKey *key in keys) [names addObject:[self.core displayNameForConfigKey:key]];
    NSString *summary=[names componentsJoinedByString:@"\n• "];
    NSAlert *a=[NSAlert new]; a.messageText=@"Remove newer settings?"; a.informativeText=[NSString stringWithFormat:@"The following overrides will be removed:\n• %@\n\nOnly these settings will change. The original configuration will be backed up first.",summary]; [a addButtonWithTitle:@"Remove Settings"]; [a addButtonWithTitle:@"Cancel"];
    [a beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse code){ if(code!=NSAlertFirstButtonReturn)return; NSURL *backup=nil; NSError *error=nil; if([self.configurationEditor removeNewerOverridesThanVersion:[self selectedVersion] backupURL:&backup error:&error]) [self showResult:@"Newer settings removed." backup:backup]; else [self showError:error]; }];
}
- (void)showResult:(NSString *)message backup:(NSURL *)backup { self.status.stringValue=backup?[NSString stringWithFormat:@"%@ Backup: %@",message,backup.path]:message; }
- (void)showError:(NSError *)error { self.status.stringValue=error.localizedDescription ?: @"The configuration could not be changed."; }
@end
