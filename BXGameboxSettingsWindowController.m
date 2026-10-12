#import "BXGameboxSettingsWindowController.h"
#import "BXEmulatorCore.h"
#import "BXConfigKey.h"
#import "BXGameboxConfigurationEditor.h"
#import "BXGamebox.h"
#import "BXSession.h"

static NSInteger const BXCPUBase = 100;
static NSInteger const BXDOSBoxShaders = 200;
static NSInteger const BXOpenEmuShaders = 201;
static NSInteger const BXVersion080 = 400;
static NSInteger const BXVersion081 = 401;
static NSInteger const BXVersion0822 = 402;

@interface BXGameboxSettingsWindowController ()
@property(nonatomic,strong) BXGamebox *gamebox;
@property(nonatomic,weak) BXSession *session;
@property(nonatomic,strong) BXEmulatorCore *core;
@property(nonatomic,strong) BXGameboxConfigurationEditor *configurationEditor;
@property(nonatomic,strong) NSPopUpButton *cpuPopup;
@property(nonatomic,strong) NSButton *voodoo;
@property(nonatomic,strong) NSPopUpButton *voodooMemory;
@property(nonatomic,strong) NSButton *reelMagic;
@property(nonatomic,strong) NSButton *ess;
@property(nonatomic,strong) NSButton *ibmMFC;
@property(nonatomic,strong) NSPopUpButton *shaderSystem;
@property(nonatomic,strong) NSPopUpButton *shaderPreset;
@property(nonatomic,strong) NSButton *integerScaling;
@property(nonatomic,strong) NSPopUpButton *versionPopup;
@property(nonatomic,strong) NSTextField *status;
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
    window.title = NSLocalizedString(@"Gamebox Settings", @"Gamebox settings title.");
    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:window.contentView.bounds];
    scroll.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    scroll.hasVerticalScroller = YES;
    NSView *document = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 560, 900)];
    NSStackView *stack = [[NSStackView alloc] initWithFrame:NSMakeRect(20, 20, 520, 850)];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeLeading;
    stack.spacing = 8;
    [document addSubview:stack];
    scroll.documentView = document;
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

    [stack addArrangedSubview:[self heading:@"Advanced"]];
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
    if (self.core.supportsIBMMusicFeatureCard) {
        self.ibmMFC = [self checkbox:@"Enable IBM Music Feature Card" action:@selector(ibmMFCChanged:)];
        self.ibmMFC.state = self.core.ibmMFCEnabledForCurrentGamebox;
        [stack addArrangedSubview:self.ibmMFC];
    }

    [stack addArrangedSubview:[self heading:@"Shader System"]];
    self.shaderSystem = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(0,0,500,26)];
    [self.shaderSystem addItemWithTitle:@"DOSBox Staging (Recommended)"]; self.shaderSystem.itemArray.lastObject.tag = BXDOSBoxShaders;
    [self.shaderSystem addItemWithTitle:@"Boxer / OpenEmu (Legacy)"]; self.shaderSystem.itemArray.lastObject.tag = BXOpenEmuShaders;
    [self.shaderSystem selectItemWithTag:self.core.currentShaderSystem == BXShaderSystemOpenEmu ? BXOpenEmuShaders : BXDOSBoxShaders];
    self.shaderSystem.target = self; self.shaderSystem.action = @selector(shaderSystemChanged:);
    [stack addArrangedSubview:self.shaderSystem];

    NSStackView *presetRow = [self row:@"Shader preset:"];
    self.shaderPreset = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(0,0,320,26)];
    self.shaderPreset.target = self; self.shaderPreset.action = @selector(shaderPresetChanged:);
    [presetRow addArrangedSubview:self.shaderPreset]; [stack addArrangedSubview:presetRow];

    self.integerScaling = [self checkbox:@"Integer scaling" action:@selector(integerScalingChanged:)];
    [stack addArrangedSubview:self.integerScaling];
    [self refreshShaders];

    if (self.core.maximumMouseCount > 1) {
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
    self.status = [NSTextField labelWithString:@""];
    self.status.maximumNumberOfLines = 3; [stack addArrangedSubview:self.status];

    self.window = window;
    [window center];
}

- (NSTextField *)heading:(NSString *)title { NSTextField *f=[NSTextField labelWithString:title]; f.font=[NSFont boldSystemFontOfSize:[NSFont systemFontSize]]; return f; }
- (NSButton *)checkbox:(NSString *)title action:(SEL)action { NSButton *b=[NSButton checkboxWithTitle:title target:self action:action]; b.controlSize=NSControlSizeSmall; return b; }
- (NSStackView *)row:(NSString *)title {
    NSStackView *r=[[NSStackView alloc] initWithFrame:NSZeroRect]; r.orientation=NSUserInterfaceLayoutOrientationHorizontal; r.spacing=8;
    NSTextField *f=[NSTextField labelWithString:title]; f.frame=NSMakeRect(0,0,180,22); [r addArrangedSubview:f]; return r;
}
- (void)refreshShaders {
    [self.shaderPreset removeAllItems];
    if (self.core.currentShaderSystem == BXShaderSystemDOSBoxStaging) {
        for (NSString *preset in self.core.availableDOSBoxShaderPresets) {
            [self.shaderPreset addItemWithTitle:[preset isEqualToString:@"custom"] ? @"Custom GLSL" : preset];
            self.shaderPreset.itemArray.lastObject.representedObject = preset;
        }
        for (NSMenuItem *item in self.shaderPreset.itemArray) {
            if ([item.representedObject isEqual:self.core.currentDOSBoxShaderPreset]) {
                [self.shaderPreset selectItem:item];
                break;
            }
        }
        self.integerScaling.hidden = NO;
        self.integerScaling.state = self.core.integerScalingEnabledForCurrentGamebox;
    } else {
        NSArray *names = [self openEmuShaderNames]; if (!names.count) names=@[@"OpenEmu Default"];
        [self.shaderPreset addItemsWithTitles:names];
        NSString *selected=[[NSUserDefaults standardUserDefaults] stringForKey:@"videoShader"];
        if (selected) [self.shaderPreset selectItemWithTitle:selected];
        self.integerScaling.hidden = YES;
    }
}
- (NSArray *)openEmuShaderNames {
    NSURL *url=[[[NSBundle mainBundle] resourceURL] URLByAppendingPathComponent:@"Shaders" isDirectory:YES];
    NSArray *children=[[NSFileManager defaultManager] contentsOfDirectoryAtURL:url includingPropertiesForKeys:@[NSURLIsDirectoryKey] options:0 error:NULL];
    NSMutableArray *result=[NSMutableArray array];
    for (NSURL *child in children) { NSNumber *directory=nil; [child getResourceValue:&directory forKey:NSURLIsDirectoryKey error:NULL]; if (directory.boolValue) [result addObject:child.lastPathComponent]; }
    return [result sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
}
- (void)cpuChanged:(NSPopUpButton *)sender { [self.core setCPUType:(BXCPUType)(sender.selectedTag-BXCPUBase)]; }
- (void)voodooChanged:(NSButton *)sender { [self.core setVoodooEnabled:sender.state==NSControlStateValueOn]; }
- (void)voodooMemoryChanged:(NSPopUpButton *)sender { [self.core setVoodooMemorySize:sender.indexOfSelectedItem==0?2:4]; }
- (void)reelMagicChanged:(NSButton *)sender { [self.core setReelMagicEnabled:sender.state==NSControlStateValueOn]; }
- (void)essChanged:(NSButton *)sender { [self.core setESSEnabled:sender.state==NSControlStateValueOn]; }
- (void)ibmMFCChanged:(NSButton *)sender { [self.core setIBMMFCEnabled:sender.state==NSControlStateValueOn]; }
- (void)shaderSystemChanged:(NSPopUpButton *)sender { [self.core setShaderSystem:sender.selectedTag==BXOpenEmuShaders?BXShaderSystemOpenEmu:BXShaderSystemDOSBoxStaging]; [self refreshShaders]; }
- (void)shaderPresetChanged:(NSPopUpButton *)sender {
    if (self.core.currentShaderSystem==BXShaderSystemDOSBoxStaging) [self.core setDOSBoxShaderPreset:sender.selectedItem.representedObject];
    else [[NSUserDefaults standardUserDefaults] setObject:sender.titleOfSelectedItem forKey:@"videoShader"];
}
- (void)integerScalingChanged:(NSButton *)sender { [self.core setIntegerScalingEnabled:sender.state==NSControlStateValueOn]; }
- (void)mouseChanged:(NSPopUpButton *)sender { [self.core setMouseCount:sender.selectedTag]; }
- (BXStagingVersion)selectedVersion { return self.versionPopup.selectedTag==BXVersion080?BXStagingVersion080:(self.versionPopup.selectedTag==BXVersion0822?BXStagingVersion0822:BXStagingVersion081); }
- (void)clearAll:(id)sender {
    NSAlert *a=[NSAlert new]; a.messageText=@"Clear all gamebox overrides?"; a.informativeText=@"The original configuration will be backed up first."; [a addButtonWithTitle:@"Clear Overrides"]; [a addButtonWithTitle:@"Cancel"];
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
