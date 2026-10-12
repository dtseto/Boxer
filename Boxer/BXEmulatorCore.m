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

+ (void)sendKeyboardKey:(uint16_t)key pressed:(BOOL)pressed
{
    const BXDOSBoxInputBridgeCallbacks *bridge = boxer_registeredDOSBoxInputBridge();
    if (bridge && bridge->keyboardKey) bridge->keyboardKey(key, pressed);
}

+ (void)clearKeyboardBuffer
{
    const BXDOSBoxInputBridgeCallbacks *bridge = boxer_registeredDOSBoxInputBridge();
    if (bridge && bridge->keyboardClearBuffer) bridge->keyboardClearBuffer();
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

+ (void)requestDOSBoxShutdown
{
    const BXDOSBoxConfigurationBridgeCallbacks *bridge = boxer_registeredDOSBoxConfigurationBridge();
    if (bridge && bridge->requestShutdown)
        bridge->requestShutdown();
}

+ (NSInteger)DOSBoxCycleMaximum
{
    const BXDOSBoxCPUControlBridgeCallbacks *bridge = boxer_registeredDOSBoxCPUControlBridge();
    return bridge && bridge->cycleMaximum ? bridge->cycleMaximum() : 0;
}

+ (void)setDOSBoxCycleMaximum:(NSInteger)value
{
    const BXDOSBoxCPUControlBridgeCallbacks *bridge = boxer_registeredDOSBoxCPUControlBridge();
    if (bridge && bridge->setCycleMaximum)
        bridge->setCycleMaximum((int)value);
}

+ (BOOL)DOSBoxCycleAutoAdjust
{
    const BXDOSBoxCPUControlBridgeCallbacks *bridge = boxer_registeredDOSBoxCPUControlBridge();
    return bridge && bridge->cycleAutoAdjust && bridge->cycleAutoAdjust();
}

+ (void)setDOSBoxCycleAutoAdjust:(BOOL)enabled
{
    const BXDOSBoxCPUControlBridgeCallbacks *bridge = boxer_registeredDOSBoxCPUControlBridge();
    if (bridge && bridge->setCycleAutoAdjust)
        bridge->setCycleAutoAdjust(enabled);
}

+ (void)setDOSBoxCyclePercentageUsed:(NSInteger)value
{
    const BXDOSBoxCPUControlBridgeCallbacks *bridge = boxer_registeredDOSBoxCPUControlBridge();
    if (bridge && bridge->setCyclePercentageUsed)
        bridge->setCyclePercentageUsed((int)value);
}

+ (void)resetDOSBoxCycleCounters
{
    const BXDOSBoxCPUControlBridgeCallbacks *bridge = boxer_registeredDOSBoxCPUControlBridge();
    if (bridge && bridge->resetCycleCounters)
        bridge->resetCycleCounters();
}

+ (uint8_t)DOSBoxCoreMode
{
    const BXDOSBoxCPUControlBridgeCallbacks *bridge = boxer_registeredDOSBoxCPUControlBridge();
    return bridge && bridge->coreMode ? bridge->coreMode() : UINT8_MAX;
}

+ (BOOL)setDOSBoxCoreMode:(uint8_t)mode
{
    const BXDOSBoxCPUControlBridgeCallbacks *bridge = boxer_registeredDOSBoxCPUControlBridge();
    return bridge && bridge->setCoreMode && bridge->setCoreMode(mode);
}

+ (BOOL)DOSBoxTicksLocked
{
    const BXDOSBoxCPUControlBridgeCallbacks *bridge = boxer_registeredDOSBoxCPUControlBridge();
    return bridge && bridge->ticksLocked && bridge->ticksLocked();
}

+ (void)setDOSBoxTicksLocked:(BOOL)locked
{
    const BXDOSBoxCPUControlBridgeCallbacks *bridge = boxer_registeredDOSBoxCPUControlBridge();
    if (bridge && bridge->setTicksLocked)
        bridge->setTicksLocked(locked);
}

+ (uintptr_t)currentDOSBoxShell
{
    const BXDOSBoxShellControlBridgeCallbacks *bridge = boxer_registeredDOSBoxShellControlBridge();
    return bridge && bridge->currentShell ? bridge->currentShell() : 0;
}

+ (const char *)currentDOSBoxRunningProgram
{
    const BXDOSBoxShellControlBridgeCallbacks *bridge = boxer_registeredDOSBoxShellControlBridge();
    return bridge && bridge->currentRunningProgram ? bridge->currentRunningProgram() : NULL;
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

+ (void)clearDOSBoxShellScreen
{
    const BXDOSBoxShellControlBridgeCallbacks *bridge = boxer_registeredDOSBoxShellControlBridge();
    if (bridge && bridge->clearScreen)
        bridge->clearScreen();
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

+ (NSUInteger)DOSBoxDriveType:(uintptr_t)drive
{
    const BXDOSBoxFilesystemControlBridgeCallbacks *bridge = boxer_registeredDOSBoxFilesystemControlBridge();
    return bridge && bridge->driveType ? bridge->driveType(drive) : 0;
}

+ (const char *)DOSBoxDriveSystemPath:(uintptr_t)drive
{
    const BXDOSBoxFilesystemControlBridgeCallbacks *bridge = boxer_registeredDOSBoxFilesystemControlBridge();
    return bridge && bridge->driveSystemPath ? bridge->driveSystemPath(drive) : NULL;
}

+ (const char *)DOSBoxDriveCurrentDirectory:(uintptr_t)drive
{
    const BXDOSBoxFilesystemControlBridgeCallbacks *bridge = boxer_registeredDOSBoxFilesystemControlBridge();
    return bridge && bridge->driveCurrentDirectory ? bridge->driveCurrentDirectory(drive) : NULL;
}

+ (BOOL)DOSBoxDrive:(uintptr_t)drive fileExists:(const char *)path
{
    const BXDOSBoxFilesystemControlBridgeCallbacks *bridge = boxer_registeredDOSBoxFilesystemControlBridge();
    return bridge && bridge->driveFileExists && bridge->driveFileExists(drive, path);
}

+ (BOOL)DOSBoxDrive:(uintptr_t)drive testDirectory:(const char *)path
{
    const BXDOSBoxFilesystemControlBridgeCallbacks *bridge = boxer_registeredDOSBoxFilesystemControlBridge();
    return bridge && bridge->driveTestDirectory && bridge->driveTestDirectory(drive, path);
}

+ (NSUInteger)maximumDOSBoxShortNameLength
{
    const BXDOSBoxFilesystemControlBridgeCallbacks *bridge = boxer_registeredDOSBoxFilesystemControlBridge();
    return bridge && bridge->maximumShortNameLength ? bridge->maximumShortNameLength() : 0;
}

+ (BOOL)DOSBoxDrive:(uintptr_t)drive getShortNameForDirectory:(const char *)directory
                                                        name:(const char *)name
                                                    intoBuffer:(char *)buffer
                                                      capacity:(NSUInteger)capacity
{
    const BXDOSBoxFilesystemControlBridgeCallbacks *bridge = boxer_registeredDOSBoxFilesystemControlBridge();
    return bridge && bridge->driveGetShortName && bridge->driveGetShortName(drive, directory, name, buffer, capacity);
}

+ (NSUInteger)maximumDOSBoxHostPathLength
{
    const BXDOSBoxFilesystemControlBridgeCallbacks *bridge = boxer_registeredDOSBoxFilesystemControlBridge();
    return bridge && bridge->maximumHostPathLength ? bridge->maximumHostPathLength() : 0;
}

+ (BOOL)DOSBoxDrive:(uintptr_t)drive mapDOSPath:(const char *)path
                                          intoBuffer:(char *)buffer
                                            capacity:(NSUInteger)capacity
{
    const BXDOSBoxFilesystemControlBridgeCallbacks *bridge = boxer_registeredDOSBoxFilesystemControlBridge();
    return bridge && bridge->driveMapDOSPath && bridge->driveMapDOSPath(drive, path, buffer, capacity);
}

+ (void)emptyDOSBoxDriveCache:(uintptr_t)drive
{
    const BXDOSBoxFilesystemControlBridgeCallbacks *bridge = boxer_registeredDOSBoxFilesystemControlBridge();
    if (bridge && bridge->emptyDriveCache)
        bridge->emptyDriveCache(drive);
}

+ (BOOL)addDOSBoxDrive:(uintptr_t)drive atIndex:(NSUInteger)index mediaByte:(uint8_t)mediaByte
{
    const BXDOSBoxFilesystemControlBridgeCallbacks *bridge = boxer_registeredDOSBoxFilesystemControlBridge();
    return bridge && bridge->addDrive && bridge->addDrive(drive, (uint8_t)index, mediaByte);
}

+ (int32_t)unmountDOSBoxDriveAtIndex:(NSUInteger)index
{
    const BXDOSBoxFilesystemControlBridgeCallbacks *bridge = boxer_registeredDOSBoxFilesystemControlBridge();
    return bridge && bridge->unmountDrive ? bridge->unmountDrive((uint8_t)index) : -1;
}

+ (void)closeDOSBoxFilesForDriveAtIndex:(NSUInteger)index
{
    const BXDOSBoxFilesystemControlBridgeCallbacks *bridge = boxer_registeredDOSBoxFilesystemControlBridge();
    if (bridge && bridge->closeFilesForDrive)
        bridge->closeFilesForDrive((uint8_t)index);
}

+ (BOOL)DOSBoxDriveInUseAtIndex:(NSUInteger)index
{
    const BXDOSBoxFilesystemControlBridgeCallbacks *bridge = boxer_registeredDOSBoxFilesystemControlBridge();
    return bridge && bridge->driveInUse && bridge->driveInUse((uint8_t)index);
}

+ (void)destroyDOSBoxDrive:(uintptr_t)drive
{
    const BXDOSBoxFilesystemControlBridgeCallbacks *bridge = boxer_registeredDOSBoxFilesystemControlBridge();
    if (bridge && bridge->destroyDrive)
        bridge->destroyDrive(drive);
}

+ (void)setDOSBoxDrive:(uintptr_t)drive label:(const char *)label isCDROM:(BOOL)isCDROM
{
    const BXDOSBoxFilesystemControlBridgeCallbacks *bridge = boxer_registeredDOSBoxFilesystemControlBridge();
    if (bridge && bridge->setDriveLabel)
        bridge->setDriveLabel(drive, label, isCDROM);
}

+ (const char *)DOSBoxDriveLabel:(uintptr_t)drive
{
    const BXDOSBoxFilesystemControlBridgeCallbacks *bridge = boxer_registeredDOSBoxFilesystemControlBridge();
    return bridge && bridge->driveLabel ? bridge->driveLabel(drive) : NULL;
}

+ (uintptr_t)createDOSBoxCDROMImage:(const char *)path driveIndex:(NSUInteger)driveIndex
                           mediaByte:(uint8_t)mediaByte errorCode:(int32_t *)outErrorCode
{
    const BXDOSBoxFilesystemControlBridgeCallbacks *bridge = boxer_registeredDOSBoxFilesystemControlBridge();
    return bridge && bridge->createCDROMImage ? bridge->createCDROMImage(path, (uint8_t)driveIndex, mediaByte, outErrorCode) : 0;
}

+ (uintptr_t)createDOSBoxFloppyImage:(const char *)path errorCode:(int32_t *)outErrorCode
{
    const BXDOSBoxFilesystemControlBridgeCallbacks *bridge = boxer_registeredDOSBoxFilesystemControlBridge();
    return bridge && bridge->createFloppyImage ? bridge->createFloppyImage(path, outErrorCode) : 0;
}

+ (uintptr_t)createDOSBoxCDROMDirectory:(const char *)path driveIndex:(NSUInteger)driveIndex
                               useAudio:(BOOL)useAudio geometry:(const uint16_t *)geometry
                              mediaByte:(uint8_t)mediaByte errorCode:(int32_t *)outErrorCode
{
    const BXDOSBoxFilesystemControlBridgeCallbacks *bridge = boxer_registeredDOSBoxFilesystemControlBridge();
    return bridge && bridge->createCDROMDirectory ? bridge->createCDROMDirectory(path, (uint8_t)driveIndex, useAudio, geometry, mediaByte, outErrorCode) : 0;
}

+ (uintptr_t)createDOSBoxLocalDirectory:(const char *)path shadowPath:(const char *)shadowPath
                              freeSpace:(int64_t)freeSpace geometry:(const uint16_t *)geometry
                              mediaByte:(uint8_t)mediaByte errorCode:(int32_t *)outErrorCode
{
    const BXDOSBoxFilesystemControlBridgeCallbacks *bridge = boxer_registeredDOSBoxFilesystemControlBridge();
    return bridge && bridge->createLocalDirectory ? bridge->createLocalDirectory(path, shadowPath, freeSpace, geometry, mediaByte, outErrorCode) : 0;
}

+ (uintptr_t)createDOSBoxFloppyDirectory:(const char *)path freeSpace:(int64_t)freeSpace
                                geometry:(const uint16_t *)geometry mediaByte:(uint8_t)mediaByte
                               errorCode:(int32_t *)outErrorCode
{
    const BXDOSBoxFilesystemControlBridgeCallbacks *bridge = boxer_registeredDOSBoxFilesystemControlBridge();
    return bridge && bridge->createFloppyDirectory ? bridge->createFloppyDirectory(path, freeSpace, geometry, mediaByte, outErrorCode) : 0;
}

+ (void)setDOSBoxMixerState:(BXAudioMixerState)state
{
    const BXDOSBoxAudioBridgeCallbacks *bridge = boxer_registeredDOSBoxAudioBridge();
    if (bridge && bridge->setMixerState)
        bridge->setMixerState((BXDOSBoxAudioMixerState)state);
}

+ (uintptr_t)addDOSBoxMIDIChannelWithSampleRate:(NSUInteger)sampleRate
{
    const BXDOSBoxAudioBridgeCallbacks *bridge = boxer_registeredDOSBoxAudioBridge();
    return bridge && bridge->addMIDIChannel ? bridge->addMIDIChannel((uint32_t)sampleRate) : 0;
}

+ (void)setDOSBoxMIDIChannel:(uintptr_t)channel sampleRate:(NSUInteger)sampleRate
{
    const BXDOSBoxAudioBridgeCallbacks *bridge = boxer_registeredDOSBoxAudioBridge();
    if (bridge && bridge->setMIDIChannelSampleRate)
        bridge->setMIDIChannelSampleRate(channel, (uint32_t)sampleRate);
}

+ (void)enableDOSBoxMIDIChannel:(uintptr_t)channel enabled:(BOOL)enabled
{
    const BXDOSBoxAudioBridgeCallbacks *bridge = boxer_registeredDOSBoxAudioBridge();
    if (bridge && bridge->enableMIDIChannel)
        bridge->enableMIDIChannel(channel, enabled);
}

+ (void)addDOSBoxMIDIChannelSilence:(uintptr_t)channel
{
    const BXDOSBoxAudioBridgeCallbacks *bridge = boxer_registeredDOSBoxAudioBridge();
    if (bridge && bridge->addMIDIChannelSilence)
        bridge->addMIDIChannelSilence(channel);
}

+ (void)addDOSBoxMIDIChannelSamples:(uintptr_t)channel format:(BXAudioSampleFormat)format
                              frames:(NSUInteger)frames samples:(const void *)samples
{
    const BXDOSBoxAudioBridgeCallbacks *bridge = boxer_registeredDOSBoxAudioBridge();
    if (bridge && bridge->addMIDIChannelSamples)
        bridge->addMIDIChannelSamples(channel, (BXDOSBoxAudioSampleFormat)format,
                                      (uint32_t)frames, samples);
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
