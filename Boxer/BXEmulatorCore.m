/*
 Copyright (c) 2026 Alun Bestor and contributors. All rights reserved.
 This source file is released under the GNU General Public License 2.0. A full copy of this license
 can be found in this XCode project at Resources/English.lproj/BoxerHelp/pages/legalese.html, or read
 online at [http://www.gnu.org/licenses/gpl-2.0.txt].
 */

#import "BXEmulatorCore.h"
#import "BXConfigKey.h"
#import "BXGamebox.h"
#import "BXEmulatorConfiguration.h"
#define BXDOSBOX_BRIDGE_IMPLEMENTATION 1
#import "BXDOSBoxBridgeRegistration.h"
#undef BXDOSBOX_BRIDGE_IMPLEMENTATION

static NSString * const BXCPUSection = @"cpu";
static NSString * const BXCPUTypeKey = @"cputype";
static NSString * const BXVoodooSection = @"voodoo";
static NSString * const BXVoodooKey = @"voodoo";
static NSString * const BXVoodooMemoryKey = @"voodoo_memsize";
static NSString * const BXReelMagicSection = @"reelmagic";
static NSString * const BXReelMagicKey = @"reelmagic";
static NSString * const BXSBlasterSection = @"sblaster";
static NSString * const BXSBlasterTypeKey = @"sbtype";
static NSString * const BXRenderSection = @"render";
static NSString * const BXShaderKey = @"glshader";
static NSString * const BXIntegerScalingKey = @"integer_scaling";
static NSString * const BXIMFCSection = @"imfc";
static NSString * const BXDefaultDOSBoxShaderPreset = @"crt-auto";
static NSString * const BXIMFCKey = @"imfc";

static NSString *BXCPUTypeString(BXCPUType type)
{
    switch (type)
    {
        case BXCPUType386:
            return @"386";
        case BXCPUType486:
            return @"486";
        case BXCPUTypePentium:
            return @"pentium";
        case BXCPUTypePentiumMMX:
            return @"pentium_mmx";
        case BXCPUTypeAuto:
        default:
            return @"auto";
    }
}

static BXCPUType BXCPUTypeFromString(NSString *value)
{
    if ([value isEqualToString:@"386"])
        return BXCPUType386;
    if ([value isEqualToString:@"486"])
        return BXCPUType486;
    if ([value isEqualToString:@"pentium"])
        return BXCPUTypePentium;
    if ([value isEqualToString:@"pentium_mmx"])
        return BXCPUTypePentiumMMX;
    return BXCPUTypeAuto;
}

static BOOL BXConfigurationBoolean(NSString *value)
{
    return [value boolValue];
}

@interface BXEmulatorCore ()

@property (nonatomic, strong) BXGamebox *gamebox;
@property (nonatomic, weak) BXSession *session;

@end

@implementation BXEmulatorCore

+ (NSSize)currentVideoResolution
{
    const BXDOSBoxRenderingBridgeCallbacks *bridge = boxer_registeredDOSBoxRenderingBridge();
    if (!bridge || !bridge->currentVideoWidth || !bridge->currentVideoHeight)
        return NSZeroSize;
    return NSMakeSize((CGFloat)bridge->currentVideoWidth(), (CGFloat)bridge->currentVideoHeight());
}

+ (BOOL)currentVideoModeIsText
{
    const BXDOSBoxRenderingBridgeCallbacks *bridge = boxer_registeredDOSBoxRenderingBridge();
    return bridge && bridge->currentVideoModeIsText && bridge->currentVideoModeIsText();
}

+ (BOOL)currentMachineIsHercules
{
    const BXDOSBoxRenderingBridgeCallbacks *bridge = boxer_registeredDOSBoxRenderingBridge();
    return bridge && bridge->currentMachineIsHercules && bridge->currentMachineIsHercules();
}

+ (BOOL)currentMachineIsCGA
{
    const BXDOSBoxRenderingBridgeCallbacks *bridge = boxer_registeredDOSBoxRenderingBridge();
    return bridge && bridge->currentMachineIsCGA && bridge->currentMachineIsCGA();
}

+ (void)setVideoScale:(NSUInteger)scale
{
    const BXDOSBoxRenderingBridgeCallbacks *bridge = boxer_registeredDOSBoxRenderingBridge();
    if (bridge && bridge->setRenderScale)
        bridge->setRenderScale((uintptr_t)scale);
}

+ (void)setHerculesTintMode:(uint8_t)mode
{
    const BXDOSBoxRenderingBridgeCallbacks *bridge = boxer_registeredDOSBoxRenderingBridge();
    if (bridge && bridge->setHerculesTintMode)
        bridge->setHerculesTintMode(mode);
}

+ (void)setCGACompositeHueOffset:(double)offset
{
    const BXDOSBoxRenderingBridgeCallbacks *bridge = boxer_registeredDOSBoxRenderingBridge();
    if (bridge && bridge->setCGACompositeHueOffset)
        bridge->setCGACompositeHueOffset(offset);
}

+ (void)setCGAComponentMode:(uint8_t)mode
{
    const BXDOSBoxRenderingBridgeCallbacks *bridge = boxer_registeredDOSBoxRenderingBridge();
    if (bridge && bridge->setCGAComponentMode)
        bridge->setCGAComponentMode(mode);
}

+ (void)switchDOSBoxKeyboardLayout:(const char *)layout codepage:(int32_t)codepage
{
    const BXDOSBoxInputBridgeCallbacks *bridge = boxer_registeredDOSBoxInputBridge();
    if (bridge && bridge->switchKeyboardLayout)
        bridge->switchKeyboardLayout(layout, codepage);
}

+ (void)sendMouseMovedWithDeltaX:(float)deltaX
                           deltaY:(float)deltaY
                       absoluteX:(int32_t)absoluteX
                       absoluteY:(int32_t)absoluteY
{
    const BXDOSBoxInputBridgeCallbacks *bridge = boxer_registeredDOSBoxInputBridge();
    if (bridge && bridge->mouseMoved)
        bridge->mouseMoved(deltaX, deltaY, absoluteX, absoluteY);
}

+ (void)sendMouseButton:(NSUInteger)button pressed:(BOOL)pressed
{
    const BXDOSBoxInputBridgeCallbacks *bridge = boxer_registeredDOSBoxInputBridge();
    if (bridge && bridge->mouseButton)
        bridge->mouseButton((uint8_t)button, pressed);
}

+ (void)setJoystickEnabled:(BOOL)enabled atIndex:(NSUInteger)index
{
    const BXDOSBoxJoystickBridgeCallbacks *bridge = boxer_registeredDOSBoxJoystickBridge();
    if (bridge && bridge->enable)
        bridge->enable((uint8_t)index, enabled);
}

+ (void)setJoystickButton:(NSUInteger)button
                   pressed:(BOOL)pressed
                   atIndex:(NSUInteger)index
{
    const BXDOSBoxJoystickBridgeCallbacks *bridge = boxer_registeredDOSBoxJoystickBridge();
    if (bridge && bridge->setButton)
        bridge->setButton((uint8_t)index, (uint8_t)button, pressed);
}

+ (void)setJoystickAxisX:(int16_t)value atIndex:(NSUInteger)index
{
    const BXDOSBoxJoystickBridgeCallbacks *bridge = boxer_registeredDOSBoxJoystickBridge();
    if (bridge && bridge->moveX)
        bridge->moveX((uint8_t)index, value);
}

+ (void)setJoystickAxisY:(int16_t)value atIndex:(NSUInteger)index
{
    const BXDOSBoxJoystickBridgeCallbacks *bridge = boxer_registeredDOSBoxJoystickBridge();
    if (bridge && bridge->moveY)
        bridge->moveY((uint8_t)index, value);
}

+ (BOOL)isJoystickAccessibleAtIndex:(NSUInteger)index
{
    const BXDOSBoxJoystickBridgeCallbacks *bridge = boxer_registeredDOSBoxJoystickBridge();
    return bridge && bridge->isAccessible && bridge->isAccessible((uint8_t)index);
}

+ (BOOL)joystickButton:(NSUInteger)button isDownAtIndex:(NSUInteger)index
{
    const BXDOSBoxJoystickBridgeCallbacks *bridge = boxer_registeredDOSBoxJoystickBridge();
    return bridge && bridge->getButton && bridge->getButton((uint8_t)index, (uint8_t)button);
}

+ (double)joystickAxisXAtIndex:(NSUInteger)index
{
    const BXDOSBoxJoystickBridgeCallbacks *bridge = boxer_registeredDOSBoxJoystickBridge();
    return bridge && bridge->getMoveX ? bridge->getMoveX((uint8_t)index) : 0.0;
}

+ (double)joystickAxisYAtIndex:(NSUInteger)index
{
    const BXDOSBoxJoystickBridgeCallbacks *bridge = boxer_registeredDOSBoxJoystickBridge();
    return bridge && bridge->getMoveY ? bridge->getMoveY((uint8_t)index) : 0.0;
}

+ (NSUInteger)gameportTimingMode
{
    const BXDOSBoxJoystickBridgeCallbacks *bridge = boxer_registeredDOSBoxJoystickBridge();
    return bridge && bridge->gameportTimingMode ? bridge->gameportTimingMode() : 0;
}

+ (void)setGameportTimingMode:(NSUInteger)mode
{
    const BXDOSBoxJoystickBridgeCallbacks *bridge = boxer_registeredDOSBoxJoystickBridge();
    if (bridge && bridge->setGameportTimingMode)
        bridge->setGameportTimingMode((uint8_t)mode);
}

+ (NSUInteger)joystickSupportLevel
{
    const BXDOSBoxJoystickBridgeCallbacks *bridge = boxer_registeredDOSBoxJoystickBridge();
    return bridge && bridge->joystickSupportLevel ? bridge->joystickSupportLevel() : 0;
}

+ (uintptr_t)createDOSBoxConfiguration
{
    const BXDOSBoxConfigurationBridgeCallbacks *bridge = boxer_registeredDOSBoxConfigurationBridge();
    return bridge && bridge->create ? bridge->create() : 0;
}

+ (void)initializeDOSBoxConfigurationDirectory
{
    const BXDOSBoxConfigurationBridgeCallbacks *bridge = boxer_registeredDOSBoxConfigurationBridge();
    if (bridge && bridge->initializeConfigDirectory)
        bridge->initializeConfigDirectory();
}

+ (void)initializeDOSBox
{
    const BXDOSBoxConfigurationBridgeCallbacks *bridge = boxer_registeredDOSBoxConfigurationBridge();
    if (bridge && bridge->initializeDOSBox)
        bridge->initializeDOSBox();
}

+ (void)parseDOSBoxConfiguration:(uintptr_t)configuration path:(const char *)path
{
    const BXDOSBoxConfigurationBridgeCallbacks *bridge = boxer_registeredDOSBoxConfigurationBridge();
    if (bridge && bridge->parseConfigFile)
        bridge->parseConfigFile(configuration, path);
}

+ (void)initializeDOSBoxConfiguration:(uintptr_t)configuration
{
    const BXDOSBoxConfigurationBridgeCallbacks *bridge = boxer_registeredDOSBoxConfigurationBridge();
    if (bridge && bridge->initialize)
        bridge->initialize(configuration);
}

+ (void)startDOSBoxConfiguration:(uintptr_t)configuration
{
    const BXDOSBoxConfigurationBridgeCallbacks *bridge = boxer_registeredDOSBoxConfigurationBridge();
    if (bridge && bridge->startUp)
        bridge->startUp(configuration);
}

+ (void)destroyDOSBoxConfiguration:(uintptr_t)configuration
{
    const BXDOSBoxConfigurationBridgeCallbacks *bridge = boxer_registeredDOSBoxConfigurationBridge();
    if (bridge && bridge->destroy)
        bridge->destroy(configuration);
}

+ (BOOL)dosBoxShutdownRequested
{
    const BXDOSBoxConfigurationBridgeCallbacks *bridge = boxer_registeredDOSBoxConfigurationBridge();
    return bridge && bridge->shutdownRequested && bridge->shutdownRequested();
}

+ (uintptr_t)currentDOSBoxShell
{
    const BXDOSBoxShellControlBridgeCallbacks *bridge = boxer_registeredDOSBoxShellControlBridge();
    return bridge && bridge->currentShell ? bridge->currentShell() : 0;
}

+ (void)writeDOSBoxShellOutput:(uintptr_t)shell text:(const char *)text
{
    const BXDOSBoxShellControlBridgeCallbacks *bridge = boxer_registeredDOSBoxShellControlBridge();
    if (bridge && bridge->writeOutput)
        bridge->writeOutput(shell, text);
}

+ (BOOL)dosBoxShellEchoEnabled:(uintptr_t)shell
{
    const BXDOSBoxShellControlBridgeCallbacks *bridge = boxer_registeredDOSBoxShellControlBridge();
    return bridge && bridge->echoEnabled && bridge->echoEnabled(shell);
}

+ (BOOL)dosBoxShellHasNoBatchFiles:(uintptr_t)shell
{
    const BXDOSBoxShellControlBridgeCallbacks *bridge = boxer_registeredDOSBoxShellControlBridge();
    return bridge && bridge->hasNoBatchFiles && bridge->hasNoBatchFiles(shell);
}

+ (void)showDOSBoxShellPrompt:(uintptr_t)shell
{
    const BXDOSBoxShellControlBridgeCallbacks *bridge = boxer_registeredDOSBoxShellControlBridge();
    if (bridge && bridge->showPrompt)
        bridge->showPrompt(shell);
}

+ (void)parseDOSBoxShellLine:(uintptr_t)shell line:(char *)line
{
    const BXDOSBoxShellControlBridgeCallbacks *bridge = boxer_registeredDOSBoxShellControlBridge();
    if (bridge && bridge->parseLine)
        bridge->parseLine(shell, line);
}

+ (void)executeDOSBoxShellCommand:(uintptr_t)shell command:(char *)command
{
    const BXDOSBoxShellControlBridgeCallbacks *bridge = boxer_registeredDOSBoxShellControlBridge();
    if (bridge && bridge->doCommand)
        bridge->doCommand(shell, command);
}

+ (BOOL)changeDOSBoxDirectory:(const char *)path
{
    const BXDOSBoxShellControlBridgeCallbacks *bridge = boxer_registeredDOSBoxShellControlBridge();
    return bridge && bridge->changeDirectory && bridge->changeDirectory(path);
}

+ (BOOL)setDOSBoxDrive:(NSUInteger)driveIndex
{
    const BXDOSBoxShellControlBridgeCallbacks *bridge = boxer_registeredDOSBoxShellControlBridge();
    return bridge && bridge->setDrive && bridge->setDrive((uint8_t)driveIndex);
}

+ (NSUInteger)maximumDOSBoxShellCommandLineLength
{
    const BXDOSBoxShellControlBridgeCallbacks *bridge = boxer_registeredDOSBoxShellControlBridge();
    return bridge && bridge->maximumCommandLineLength ? bridge->maximumCommandLineLength() : 0;
}

+ (NSUInteger)DOSBoxDriveCount
{
    const BXDOSBoxFilesystemControlBridgeCallbacks *bridge = boxer_registeredDOSBoxFilesystemControlBridge();
    return bridge && bridge->driveCount ? bridge->driveCount() : 0;
}

+ (NSUInteger)DOSBoxDefaultDriveIndex
{
    const BXDOSBoxFilesystemControlBridgeCallbacks *bridge = boxer_registeredDOSBoxFilesystemControlBridge();
    return bridge && bridge->defaultDriveIndex ? bridge->defaultDriveIndex() : 0;
}

+ (NSUInteger)maximumDOSBoxPathLength
{
    const BXDOSBoxFilesystemControlBridgeCallbacks *bridge = boxer_registeredDOSBoxFilesystemControlBridge();
    return bridge && bridge->maximumPathLength ? bridge->maximumPathLength() : 0;
}

+ (BOOL)makeDOSBoxPath:(const char *)path
                 into:(char *)outPath
             capacity:(NSUInteger)capacity
          driveIndex:(uint8_t *)outDriveIndex
{
    const BXDOSBoxFilesystemControlBridgeCallbacks *bridge = boxer_registeredDOSBoxFilesystemControlBridge();
    return bridge && bridge->makeName && bridge->makeName(path, outPath, capacity, outDriveIndex);
}

+ (uintptr_t)DOSBoxDriveAtIndex:(NSUInteger)index
{
    const BXDOSBoxFilesystemControlBridgeCallbacks *bridge = boxer_registeredDOSBoxFilesystemControlBridge();
    return bridge && bridge->driveAtIndex ? bridge->driveAtIndex((uint8_t)index) : 0;
}

+ (void)emptyDOSBoxDriveCache:(uintptr_t)drive
{
    const BXDOSBoxFilesystemControlBridgeCallbacks *bridge = boxer_registeredDOSBoxFilesystemControlBridge();
    if (bridge && bridge->emptyDriveCache)
        bridge->emptyDriveCache(drive);
}

- (instancetype)initWithGamebox:(BXGamebox *)gamebox
                         session:(BXSession *)session
{
    self = [super init];
    if (self)
    {
        _gamebox = gamebox;
        _session = session;
    }
    return self;
}

#pragma mark - Configuration helpers

- (BXEmulatorConfiguration *)configurationForCurrentGamebox
{
    if (!self.gamebox)
        return nil;

    NSError *error = nil;
    BXEmulatorConfiguration *configuration =
        [[BXEmulatorConfiguration alloc] initWithContentsOfURL:self.gamebox.configurationFileURL
                                                         error:&error];

    if (!configuration && ![[NSFileManager defaultManager] fileExistsAtPath:self.gamebox.configurationFileURL.path])
        configuration = [[BXEmulatorConfiguration alloc] init];

    return configuration;
}

- (BOOL)writeConfiguration:(BXEmulatorConfiguration *)configuration
{
    if (!self.gamebox || !configuration)
        return NO;

    return [configuration writeToURL:self.gamebox.configurationFileURL error:NULL];
}

- (NSString *)valueForKey:(NSString *)key
                 section:(NSString *)section
                defaultValue:(NSString *)defaultValue
{
    BXEmulatorConfiguration *configuration = [self configurationForCurrentGamebox];
    return [configuration valueForKey:key inSection:section] ?: defaultValue;
}

- (void)setValue:(nullable NSString *)value
              key:(NSString *)key
          section:(NSString *)section
       defaultValue:(NSString *)defaultValue
{
    BXEmulatorConfiguration *configuration = [self configurationForCurrentGamebox];
    if (!configuration)
        return;

    NSString *currentValue = [configuration valueForKey:key inSection:section];
    BOOL shouldRemove = value == nil || [value isEqualToString:defaultValue];

    if (shouldRemove)
    {
        if (!currentValue)
            return;

        [configuration removeValueForKey:key inSection:section];
    }
    else
    {
        if ([currentValue isEqualToString:value])
            return;

        [configuration setValue:value forKey:key inSection:section];
    }

    [self writeConfiguration:configuration];
}

- (NSArray<BXConfigKey *> *)allVersionSpecificKeys
{
    return @[
        [[BXConfigKey alloc] initWithSection:BXVoodooSection key:BXVoodooKey],
        [[BXConfigKey alloc] initWithSection:BXVoodooSection key:BXVoodooMemoryKey],
        [[BXConfigKey alloc] initWithSection:BXReelMagicSection key:BXReelMagicKey],
        [[BXConfigKey alloc] initWithSection:BXSBlasterSection key:BXSBlasterTypeKey],
        [[BXConfigKey alloc] initWithSection:BXRenderSection key:BXShaderKey],
        [[BXConfigKey alloc] initWithSection:BXRenderSection key:BXIntegerScalingKey],
        [[BXConfigKey alloc] initWithSection:BXIMFCSection key:BXIMFCKey],
        [[BXConfigKey alloc] initWithSection:BXCPUSection key:BXCPUTypeKey],
    ];
}

#pragma mark - CPU

- (BOOL)supportsPentiumMMX
{
    return YES;
}

- (BXCPUType)currentCPUType
{
    return BXCPUTypeFromString([self valueForKey:BXCPUTypeKey
                                         section:BXCPUSection
                                    defaultValue:@"pentium_mmx"]);
}

- (void)setCPUType:(BXCPUType)type
{
    [self setValue:BXCPUTypeString(type)
               key:BXCPUTypeKey
           section:BXCPUSection
        defaultValue:@"pentium_mmx"];
}

#pragma mark - Advanced hardware

- (BOOL)supportsVoodoo
{
    return YES;
}

- (BOOL)voodooEnabledForCurrentGamebox
{
    return BXConfigurationBoolean([self valueForKey:BXVoodooKey
                                            section:BXVoodooSection
                                       defaultValue:@"false"]);
}

- (void)setVoodooEnabled:(BOOL)enabled
{
    [self setValue:enabled ? @"true" : nil
               key:BXVoodooKey
           section:BXVoodooSection
        defaultValue:@"false"];
}

- (NSUInteger)voodooMemorySizeForCurrentGamebox
{
    NSString *value = [self valueForKey:BXVoodooMemoryKey
                                 section:BXVoodooSection
                            defaultValue:@"4"];
    NSUInteger megabytes = value.integerValue;
    return (megabytes == 2) ? 2 : 4;
}

- (void)setVoodooMemorySize:(NSUInteger)megabytes
{
    if (megabytes != 2 && megabytes != 4)
        return;

    [self setValue:[NSString stringWithFormat:@"%lu", (unsigned long)megabytes]
               key:BXVoodooMemoryKey
           section:BXVoodooSection
        defaultValue:@"4"];
}

- (BOOL)supportsReelMagic
{
    return YES;
}

- (BOOL)reelMagicEnabledForCurrentGamebox
{
    NSString *value = [self valueForKey:BXReelMagicKey
                                    section:BXReelMagicSection
                               defaultValue:@"off"];
    return [value isEqualToString:@"on"] || [value isEqualToString:@"cardonly"];
}

- (void)setReelMagicEnabled:(BOOL)enabled
{
    [self setValue:enabled ? @"on" : nil
               key:BXReelMagicKey
           section:BXReelMagicSection
        defaultValue:@"off"];
}

- (BOOL)supportsESSAudio
{
    return YES;
}

- (BOOL)essEnabledForCurrentGamebox
{
    return [[self valueForKey:BXSBlasterTypeKey
                       section:BXSBlasterSection
                  defaultValue:@"sb16"] isEqualToString:@"ess"];
}

- (void)setESSEnabled:(BOOL)enabled
{
    [self setValue:enabled ? @"ess" : nil
               key:BXSBlasterTypeKey
           section:BXSBlasterSection
        defaultValue:@"sb16"];
}

- (BOOL)supportsDeinterlacing
{
    return NO;
}

- (BOOL)deinterlacingEnabledForCurrentGamebox
{
    return NO;
}

- (void)setDeinterlacingEnabled:(BOOL)enabled
{
    (void)enabled;
}

- (BOOL)supportsIBMMusicFeatureCard
{
    return YES;
}

- (BOOL)ibmMFCEnabledForCurrentGamebox
{
    return BXConfigurationBoolean([self valueForKey:BXIMFCKey
                                            section:BXIMFCSection
                                       defaultValue:@"false"]);
}

- (void)setIBMMFCEnabled:(BOOL)enabled
{
    [self setValue:enabled ? @"true" : nil
               key:BXIMFCKey
           section:BXIMFCSection
        defaultValue:@"false"];
}

#pragma mark - Rendering

- (BOOL)supportsDOSBoxShaders
{
    return YES;
}

- (BOOL)supportsOpenEmuShaders
{
    return YES;
}

- (BXShaderSystem)currentShaderSystem
{
    NSString *shader = [self valueForKey:BXShaderKey
                                 section:BXRenderSection
                            defaultValue:@""];

    return [shader isEqualToString:@"none"]
        ? BXShaderSystemOpenEmu
        : BXShaderSystemDOSBoxStaging;
}

- (void)setShaderSystem:(BXShaderSystem)system
{
    if (system == BXShaderSystemOpenEmu)
    {
        [self setValue:@"none"
                   key:BXShaderKey
               section:BXRenderSection
            defaultValue:@""];
    }
    else
    {
        [self setValue:nil
                   key:BXShaderKey
               section:BXRenderSection
            defaultValue:@""];
    }
}

- (NSArray<NSString *> *)availableDOSBoxShaderPresets
{
    return @[@"crt-auto", @"crt-auto-machine", @"crt-auto-arcade", @"sharp", @"custom"];
}

- (NSString *)currentDOSBoxShaderPreset
{
    return [self valueForKey:BXShaderKey
                      section:BXRenderSection
                 defaultValue:BXDefaultDOSBoxShaderPreset];
}

- (void)setDOSBoxShaderPreset:(NSString *)preset
{
    if (![self.availableDOSBoxShaderPresets containsObject:preset])
        return;

    [self setValue:[preset isEqualToString:BXDefaultDOSBoxShaderPreset] ? nil : preset
               key:BXShaderKey
           section:BXRenderSection
        defaultValue:BXDefaultDOSBoxShaderPreset];
}

- (BOOL)supportsIntegerScaling
{
    return YES;
}

- (BOOL)integerScalingEnabledForCurrentGamebox
{
    NSString *value = [self valueForKey:BXIntegerScalingKey
                                section:BXRenderSection
                           defaultValue:@"auto"];
    return ![value isEqualToString:@"off"];
}

- (void)setIntegerScalingEnabled:(BOOL)enabled
{
    [self setValue:enabled ? @"full" : nil
               key:BXIntegerScalingKey
           section:BXRenderSection
        defaultValue:@"auto"];
}

#pragma mark - Input

- (NSUInteger)maximumMouseCount
{
    return 1;
}

- (NSUInteger)currentMouseCount
{
    return 1;
}

- (void)setMouseCount:(NSUInteger)count
{
    (void)count;
}

#pragma mark - Version compatibility

- (NSArray<BXConfigKey *> *)versionSpecificConfigKeys
{
    return [self allVersionSpecificKeys];
}

- (NSArray<BXConfigKey *> *)configKeysNewerThanVersion:(BXStagingVersion)version
{
    switch (version)
    {
        case BXStagingVersion0822:
            return @[];
        case BXStagingVersion080:
        case BXStagingVersion081:
            return [self allVersionSpecificKeys];
    }

    return @[];
}

@end
