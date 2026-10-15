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

- (BOOL)saveCurrentConfigurationWithError:(NSError **)error
{
    BXEmulatorConfiguration *configuration = [self configurationWithError:error];
    return configuration && [configuration writeToURL:self.gamebox.configurationFileURL error:error];
}

- (NSArray<BXConfigKey *> *)currentVersionSpecificOverrides
{
    BXEmulatorConfiguration *configuration = [self configurationWithError:NULL];
    NSMutableArray *result = [NSMutableArray array];
    for (BXConfigKey *key in self.core.versionSpecificConfigKeys)
    {
        NSString *value = [configuration valueForKey:key.key inSection:key.section];
        if (![self isOwnedNewerOverrideKey:key value:value])
            continue;
        [result addObject:key];
    }
    return result.copy;
}

- (NSArray<BXConfigKey *> *)currentOverridesNewerThanVersion:(BXStagingVersion)version
{
    BXEmulatorConfiguration *configuration = [self configurationWithError:NULL];
    NSMutableArray *result = [NSMutableArray array];
    for (BXConfigKey *key in [self.core configKeysNewerThanVersion:version])
    {
        NSString *value = [configuration valueForKey:key.key inSection:key.section];
        if (![self isOwnedNewerOverrideKey:key value:value])
            continue;
        [result addObject:key];
    }
    return result.copy;
}

- (BOOL)isOwnedNewerOverrideKey:(BXConfigKey *)key value:(NSString *)value
{
    if (!value.length)
        return NO;

    // These settings are only adapter-owned when they contain the values
    // written by BXEmulatorCore.  Older compatible values must remain intact.
    if ([key.section isEqualToString:@"sblaster"] && [key.key isEqualToString:@"sbtype"])
        return [value.lowercaseString isEqualToString:@"ess"];
    if ([key.section isEqualToString:@"cpu"] && [key.key isEqualToString:@"cputype"])
        return [value.lowercaseString isEqualToString:@"pentium_mmx"];
    if ([key.section isEqualToString:@"imfc"] && [key.key isEqualToString:@"imfc"])
        return [value.lowercaseString isEqualToString:@"true"] || [value.lowercaseString isEqualToString:@"on"];
    return YES;
}

- (BOOL)writeConfigurationText:(NSString *)text error:(NSError **)error
{
    return [text writeToURL:self.gamebox.configurationFileURL
                  atomically:YES
                    encoding:NSUTF8StringEncoding
                       error:error];
}

- (BOOL)mutateConfigurationRemovingKeys:(NSArray<BXConfigKey *> *)keys
                               clearAll:(BOOL)clearAll
                                  error:(NSError **)error
{
    NSURL *URL = self.gamebox.configurationFileURL;
    NSString *text = [NSString stringWithContentsOfURL:URL encoding:NSUTF8StringEncoding error:error];
    if (!text)
        return NO;

    NSSet<NSString *> *targetedKeys = [NSSet setWithArray:[keys valueForKeyPath:@"@distinctUnionOfObjects.key"]];
    NSSet<NSString *> *targetedSections = [NSSet setWithArray:[keys valueForKeyPath:@"@distinctUnionOfObjects.section"]];
    NSMutableString *result = [NSMutableString string];
    __block NSString *section = @"";
    __block BOOL inAutoexec = NO;

    [text enumerateLinesUsingBlock:^(NSString *line, BOOL *stop) {
        NSString *trimmed = [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if ([trimmed hasPrefix:@"["] && [trimmed hasSuffix:@"]"])
        {
            section = [trimmed substringWithRange:NSMakeRange(1, trimmed.length - 2)].lowercaseString;
            inAutoexec = [section isEqualToString:@"autoexec"];
            [result appendFormat:@"%@\n", line];
            return;
        }

        BOOL comment = [trimmed hasPrefix:@"#"] || [trimmed hasPrefix:@";"] || trimmed.length == 0;
        BOOL remove = NO;
        if (!comment)
        {
            NSRange equals = [line rangeOfString:@"="];
            if (equals.location != NSNotFound)
            {
                NSString *key = [[line substringToIndex:equals.location] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet].lowercaseString;
                remove = clearAll || ([targetedSections containsObject:section] && [targetedKeys containsObject:key]);
            }
            else if (clearAll && inAutoexec)
            {
                remove = YES;
            }
        }
        if (!remove)
            [result appendFormat:@"%@\n", line];
    }];

    return [self writeConfigurationText:result error:error];
}

- (BOOL)clearAllOverridesWithBackupURL:(NSURL **)backupURL error:(NSError **)error
{
    if (![[NSFileManager defaultManager] fileExistsAtPath:self.gamebox.configurationFileURL.path])
        return YES;
    NSURL *backup = [self backupWithError:error];
    if (!backup) return NO;
    if (![self mutateConfigurationRemovingKeys:@[] clearAll:YES error:error]) return NO;
    if (backupURL) *backupURL = backup;
    return YES;
}

- (BOOL)removeNewerOverridesThanVersion:(BXStagingVersion)version backupURL:(NSURL **)backupURL error:(NSError **)error
{
    NSArray *keys = [self currentOverridesNewerThanVersion:version];
    if (!keys.count) return YES;
    NSURL *backup = [self backupWithError:error];
    if (!backup) return NO;
    if (![self mutateConfigurationRemovingKeys:keys clearAll:NO error:error]) return NO;
    if (backupURL) *backupURL = backup;
    return YES;
}

@end
