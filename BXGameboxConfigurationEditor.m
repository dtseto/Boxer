#import "BXGameboxConfigurationEditor.h"
#import "BXGamebox.h"
#import "BXConfigKey.h"
#import "BXEmulatorConfiguration.h"

@interface BXGameboxConfigurationEditor ()
@property(nonatomic,strong) BXGamebox *gamebox;
@property(nonatomic,strong) BXEmulatorCore *core;
@end

@implementation BXGameboxConfigurationEditor

- (instancetype)initWithGamebox:(BXGamebox *)gamebox core:(BXEmulatorCore *)core
{
    self = [super init];
    if (self) { _gamebox = gamebox; _core = core; }
    return self;
}

- (BXEmulatorConfiguration *)configurationWithError:(NSError **)error
{
    NSURL *URL = self.gamebox.configurationFileURL;
    if (![[NSFileManager defaultManager] fileExistsAtPath:URL.path])
        return [BXEmulatorConfiguration configuration];
    return [BXEmulatorConfiguration configurationWithContentsOfURL:URL error:error];
}

- (NSURL *)backupWithError:(NSError **)error
{
    NSURL *source = self.gamebox.configurationFileURL;
    NSFileManager *files = [NSFileManager defaultManager];
    if (![files fileExistsAtPath:source.path]) return nil;
    NSURL *backup = [source URLByAppendingPathExtension:@"bak"];
    NSUInteger index = 1;
    while ([files fileExistsAtPath:backup.path]) {
        NSString *name = [NSString stringWithFormat:@"%@.bak-%lu", source.lastPathComponent, (unsigned long)index++];
        backup = [source.URLByDeletingLastPathComponent URLByAppendingPathComponent:name];
    }
    return [files copyItemAtURL:source toURL:backup error:error] ? backup : nil;
}

- (NSArray<BXConfigKey *> *)currentVersionSpecificOverrides
{
    BXEmulatorConfiguration *configuration = [self configurationWithError:NULL];
    NSMutableArray *result = [NSMutableArray array];
    for (BXConfigKey *key in self.core.versionSpecificConfigKeys)
        if ([configuration valueForKey:key.key inSection:key.section]) [result addObject:key];
    return result.copy;
}

- (BOOL)clearAllOverridesWithBackupURL:(NSURL **)backupURL error:(NSError **)error
{
    BXEmulatorConfiguration *configuration = [self configurationWithError:error];
    if (!configuration) return NO;
    if (!configuration.empty) {
        NSURL *backup = [self backupWithError:error];
        if ([[NSFileManager defaultManager] fileExistsAtPath:self.gamebox.configurationFileURL.path] && !backup) return NO;
        for (NSString *section in configuration.settings)
            for (NSString *key in [configuration settingsForSection:section].allKeys)
                [configuration removeValueForKey:key inSection:section];
        [configuration removeStartupCommands];
        if (![configuration writeToURL:self.gamebox.configurationFileURL error:error]) return NO;
        if (backupURL) *backupURL = backup;
    }
    return YES;
}

- (BOOL)removeNewerOverridesThanVersion:(BXStagingVersion)version backupURL:(NSURL **)backupURL error:(NSError **)error
{
    BXEmulatorConfiguration *configuration = [self configurationWithError:error];
    if (!configuration) return NO;
    NSMutableArray *keys = [NSMutableArray array];
    for (BXConfigKey *key in [self.core configKeysNewerThanVersion:version])
        if ([configuration valueForKey:key.key inSection:key.section]) [keys addObject:key];
    if (!keys.count) return YES;
    NSURL *backup = [self backupWithError:error];
    if (!backup) return NO;
    for (BXConfigKey *key in keys)
        [configuration removeValueForKey:key.key inSection:key.section];
    if (![configuration writeToURL:self.gamebox.configurationFileURL error:error]) return NO;
    if (backupURL) *backupURL = backup;
    return YES;
}

@end
