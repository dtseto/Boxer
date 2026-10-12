/*
 Copyright (c) 2026 Alun Bestor and contributors. All rights reserved.
 This source file is released under the GNU General Public License 2.0. A full copy of this license
 can be found in this XCode project at Resources/English.lproj/BoxerHelp/pages/legalese.html, or read
 online at [http://www.gnu.org/licenses/gpl-2.0.txt].
 */

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(uint8_t, BXAudioMixerState) {
    BXAudioMixerStateOn,
    BXAudioMixerStateMuted,
};

typedef NS_ENUM(uint8_t, BXAudioSampleFormat) {
    BXAudioSampleFormatM8,
    BXAudioSampleFormatS8,
    BXAudioSampleFormatM8Signed,
    BXAudioSampleFormatS8Signed,
    BXAudioSampleFormatM16,
    BXAudioSampleFormatS16,
    BXAudioSampleFormatM16Unsigned,
    BXAudioSampleFormatS16Unsigned,
    BXAudioSampleFormatMFloat,
    BXAudioSampleFormatSFloat,
};

@class BXGamebox;
@class BXSession;
@class BXConfigKey;

/// The CPU type exposed by the Boxer-facing emulator configuration API.
typedef NS_ENUM(NSInteger, BXCPUType) {
    BXCPUTypeAuto,
    BXCPUType386,
    BXCPUType486,
    BXCPUTypePentium,
    BXCPUTypePentiumMMX,
};

/// The shader system exposed by the Boxer-facing emulator configuration API.
typedef NS_ENUM(NSInteger, BXShaderSystem) {
    BXShaderSystemDOSBoxStaging,
    BXShaderSystemOpenEmu,
};

/// The DOSBox Staging version selected by the Boxer-facing emulator configuration API.
typedef NS_ENUM(NSInteger, BXStagingVersion) {
    BXStagingVersion080,
    BXStagingVersion081,
    BXStagingVersion0822,
};

/// The public boundary for Boxer emulator configuration and control.
@interface BXEmulatorCore : NSObject

+ (NSSize)currentVideoResolution;
+ (BOOL)currentVideoModeIsText;
+ (BOOL)currentMachineIsHercules;
+ (BOOL)currentMachineIsCGA;
+ (void)setVideoScale:(NSUInteger)scale;
+ (void)setHerculesTintMode:(uint8_t)mode;
+ (void)setCGACompositeHueOffset:(double)offset;
+ (void)setCGAComponentMode:(uint8_t)mode;
+ (void)switchDOSBoxKeyboardLayout:(const char *)layout codepage:(int32_t)codepage;
+ (void)sendMouseMovedWithDeltaX:(float)deltaX
                           deltaY:(float)deltaY
                       absoluteX:(int32_t)absoluteX
                       absoluteY:(int32_t)absoluteY;
+ (void)sendMouseButton:(NSUInteger)button pressed:(BOOL)pressed;
+ (void)sendKeyboardKey:(uint16_t)key pressed:(BOOL)pressed;
+ (void)clearKeyboardBuffer;
+ (void)setJoystickEnabled:(BOOL)enabled atIndex:(NSUInteger)index;
+ (void)setJoystickButton:(NSUInteger)button
                   pressed:(BOOL)pressed
                   atIndex:(NSUInteger)index;
+ (void)setJoystickAxisX:(int16_t)value atIndex:(NSUInteger)index;
+ (void)setJoystickAxisY:(int16_t)value atIndex:(NSUInteger)index;
+ (BOOL)isJoystickAccessibleAtIndex:(NSUInteger)index;
+ (BOOL)joystickButton:(NSUInteger)button isDownAtIndex:(NSUInteger)index;
+ (double)joystickAxisXAtIndex:(NSUInteger)index;
+ (double)joystickAxisYAtIndex:(NSUInteger)index;
+ (NSUInteger)gameportTimingMode;
+ (void)setGameportTimingMode:(NSUInteger)mode;
+ (NSUInteger)joystickSupportLevel;
+ (uintptr_t)createDOSBoxConfiguration;
+ (void)initializeDOSBoxConfigurationDirectory;
+ (void)initializeDOSBox;
+ (void)parseDOSBoxConfiguration:(uintptr_t)configuration path:(const char *)path;
+ (void)initializeDOSBoxConfiguration:(uintptr_t)configuration;
+ (void)startDOSBoxConfiguration:(uintptr_t)configuration;
+ (void)destroyDOSBoxConfiguration:(uintptr_t)configuration;
+ (BOOL)dosBoxShutdownRequested;
+ (void)requestDOSBoxShutdown;
+ (NSInteger)DOSBoxCycleMaximum;
+ (void)setDOSBoxCycleMaximum:(NSInteger)value;
+ (BOOL)DOSBoxCycleAutoAdjust;
+ (void)setDOSBoxCycleAutoAdjust:(BOOL)enabled;
+ (void)setDOSBoxCyclePercentageUsed:(NSInteger)value;
+ (void)resetDOSBoxCycleCounters;
+ (uint8_t)DOSBoxCoreMode;
+ (BOOL)setDOSBoxCoreMode:(uint8_t)mode;
+ (BOOL)DOSBoxTicksLocked;
+ (void)setDOSBoxTicksLocked:(BOOL)locked;
+ (uintptr_t)currentDOSBoxShell;
+ (void)writeDOSBoxShellOutput:(uintptr_t)shell text:(const char *)text;
+ (BOOL)dosBoxShellEchoEnabled:(uintptr_t)shell;
+ (BOOL)dosBoxShellHasNoBatchFiles:(uintptr_t)shell;
+ (void)showDOSBoxShellPrompt:(uintptr_t)shell;
+ (void)parseDOSBoxShellLine:(uintptr_t)shell line:(char *)line;
+ (void)executeDOSBoxShellCommand:(uintptr_t)shell command:(char *)command;
+ (BOOL)changeDOSBoxDirectory:(const char *)path;
+ (BOOL)setDOSBoxDrive:(NSUInteger)driveIndex;
+ (NSUInteger)maximumDOSBoxShellCommandLineLength;
+ (void)clearDOSBoxShellScreen;
+ (NSUInteger)DOSBoxDriveCount;
+ (NSUInteger)DOSBoxDefaultDriveIndex;
+ (NSUInteger)maximumDOSBoxPathLength;
+ (BOOL)makeDOSBoxPath:(const char *)path
                 into:(char *)outPath
             capacity:(NSUInteger)capacity
          driveIndex:(uint8_t *)outDriveIndex;
+ (uintptr_t)DOSBoxDriveAtIndex:(NSUInteger)index;
+ (NSUInteger)DOSBoxDriveType:(uintptr_t)drive;
+ (const char *)DOSBoxDriveSystemPath:(uintptr_t)drive;
+ (const char *)DOSBoxDriveCurrentDirectory:(uintptr_t)drive;
+ (BOOL)DOSBoxDrive:(uintptr_t)drive fileExists:(const char *)path;
+ (BOOL)DOSBoxDrive:(uintptr_t)drive testDirectory:(const char *)path;
+ (NSUInteger)maximumDOSBoxShortNameLength;
+ (BOOL)DOSBoxDrive:(uintptr_t)drive getShortNameForDirectory:(const char *)directory
                                                        name:(const char *)name
                                                    intoBuffer:(char *)buffer
                                                      capacity:(NSUInteger)capacity;
+ (NSUInteger)maximumDOSBoxHostPathLength;
+ (BOOL)DOSBoxDrive:(uintptr_t)drive mapDOSPath:(const char *)path
                                                     intoBuffer:(char *)buffer
                                                       capacity:(NSUInteger)capacity;
+ (void)emptyDOSBoxDriveCache:(uintptr_t)drive;
+ (BOOL)addDOSBoxDrive:(uintptr_t)drive atIndex:(NSUInteger)index mediaByte:(uint8_t)mediaByte;
+ (int32_t)unmountDOSBoxDriveAtIndex:(NSUInteger)index;
+ (void)closeDOSBoxFilesForDriveAtIndex:(NSUInteger)index;
+ (BOOL)DOSBoxDriveInUseAtIndex:(NSUInteger)index;
+ (void)setDOSBoxMixerState:(BXAudioMixerState)state;
+ (uintptr_t)addDOSBoxMIDIChannelWithSampleRate:(NSUInteger)sampleRate;
+ (void)setDOSBoxMIDIChannel:(uintptr_t)channel sampleRate:(NSUInteger)sampleRate;
+ (void)enableDOSBoxMIDIChannel:(uintptr_t)channel enabled:(BOOL)enabled;
+ (void)addDOSBoxMIDIChannelSilence:(uintptr_t)channel;
+ (void)addDOSBoxMIDIChannelSamples:(uintptr_t)channel format:(BXAudioSampleFormat)format
                              frames:(NSUInteger)frames samples:(const void *)samples;
+ (void)destroyDOSBoxDrive:(uintptr_t)drive;
+ (void)setDOSBoxDrive:(uintptr_t)drive label:(const char *)label isCDROM:(BOOL)isCDROM;
+ (const char *)DOSBoxDriveLabel:(uintptr_t)drive;
+ (uintptr_t)createDOSBoxCDROMImage:(const char *)path
                          driveIndex:(NSUInteger)driveIndex
                           mediaByte:(uint8_t)mediaByte
                           errorCode:(int32_t *)outErrorCode;
+ (uintptr_t)createDOSBoxFloppyImage:(const char *)path errorCode:(int32_t *)outErrorCode;
+ (uintptr_t)createDOSBoxCDROMDirectory:(const char *)path
                              driveIndex:(NSUInteger)driveIndex
                               useAudio:(BOOL)useAudio
                               geometry:(const uint16_t *)geometry
                               mediaByte:(uint8_t)mediaByte
                              errorCode:(int32_t *)outErrorCode;
+ (uintptr_t)createDOSBoxLocalDirectory:(const char *)path
                              shadowPath:(const char *)shadowPath
                               freeSpace:(int64_t)freeSpace
                                geometry:(const uint16_t *)geometry
                                mediaByte:(uint8_t)mediaByte
                               errorCode:(int32_t *)outErrorCode;
+ (uintptr_t)createDOSBoxFloppyDirectory:(const char *)path
                               freeSpace:(int64_t)freeSpace
                                geometry:(const uint16_t *)geometry
                                mediaByte:(uint8_t)mediaByte
                               errorCode:(int32_t *)outErrorCode;

- (instancetype)initWithGamebox:(nullable BXGamebox *)gamebox
                         session:(nullable BXSession *)session NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;

#pragma mark - Capabilities and configuration

- (BOOL)supportsPentiumMMX;
- (BXCPUType)currentCPUType;
- (void)setCPUType:(BXCPUType)type;

- (BOOL)supportsVoodoo;
- (BOOL)voodooEnabledForCurrentGamebox;
- (void)setVoodooEnabled:(BOOL)enabled;
- (NSUInteger)voodooMemorySizeForCurrentGamebox;
- (void)setVoodooMemorySize:(NSUInteger)megabytes;

- (BOOL)supportsReelMagic;
- (BOOL)reelMagicEnabledForCurrentGamebox;
- (void)setReelMagicEnabled:(BOOL)enabled;

- (BOOL)supportsESSAudio;
- (BOOL)essEnabledForCurrentGamebox;
- (void)setESSEnabled:(BOOL)enabled;

- (BOOL)supportsDeinterlacing;
- (BOOL)deinterlacingEnabledForCurrentGamebox;
- (void)setDeinterlacingEnabled:(BOOL)enabled;

- (BOOL)supportsIBMMusicFeatureCard;
- (BOOL)ibmMFCEnabledForCurrentGamebox;
- (void)setIBMMFCEnabled:(BOOL)enabled;

- (BOOL)supportsDOSBoxShaders;
- (BOOL)supportsOpenEmuShaders;
- (BXShaderSystem)currentShaderSystem;
- (void)setShaderSystem:(BXShaderSystem)system;
- (NSArray<NSString *> *)availableDOSBoxShaderPresets;
- (NSString *)currentDOSBoxShaderPreset;
- (void)setDOSBoxShaderPreset:(NSString *)preset;

- (BOOL)supportsIntegerScaling;
- (BOOL)integerScalingEnabledForCurrentGamebox;
- (void)setIntegerScalingEnabled:(BOOL)enabled;

- (NSUInteger)maximumMouseCount;
- (NSUInteger)currentMouseCount;
- (void)setMouseCount:(NSUInteger)count;

#pragma mark - Version compatibility

- (NSArray<BXConfigKey *> *)versionSpecificConfigKeys;
- (NSArray<BXConfigKey *> *)configKeysNewerThanVersion:(BXStagingVersion)version;

@end

NS_ASSUME_NONNULL_END
