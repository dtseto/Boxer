/*
 Copyright (c) 2026 Alun Bestor and contributors. All rights reserved.
 This source file is released under the GNU General Public License 2.0.
 */

#import <Foundation/Foundation.h>
#import "BXEmulatorCore.h"

@class BXGamebox;

NS_ASSUME_NONNULL_BEGIN

/// Owns edits to a gamebox's DOSBox Preferences.conf. It never edits Boxer's base config.
@interface BXGameboxConfigurationEditor : NSObject

- (instancetype)initWithGamebox:(BXGamebox *)gamebox
                            core:(BXEmulatorCore *)core NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;

/// Returns the version-specific overrides currently present in the gamebox.
- (NSArray<BXConfigKey *> *)currentVersionSpecificOverrides;

/// Returns only the newer overrides currently present in the gamebox.
- (NSArray<BXConfigKey *> *)currentOverridesNewerThanVersion:(BXStagingVersion)version;

/// Removes every setting and startup command from the gamebox configuration.
- (BOOL)clearAllOverridesWithBackupURL:(NSURL * _Nullable * _Nullable)backupURL
                                  error:(NSError * _Nullable * _Nullable)error;

/// Removes settings introduced after the selected DOSBox Staging version.
- (BOOL)removeNewerOverridesThanVersion:(BXStagingVersion)version
                           backupURL:(NSURL * _Nullable * _Nullable)backupURL
                               error:(NSError * _Nullable * _Nullable)error;

@end

NS_ASSUME_NONNULL_END
