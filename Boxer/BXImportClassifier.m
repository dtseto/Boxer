/*
 *  Copyright (c) 2026 Alun Bestor and contributors. All rights reserved.
 *  This source file is released under the GNU General Public License 2.0.
 *  A full copy of this license can be found in this project's README.
 */

#import "BXImportClassifier.h"
#import "BXZipCentralDirectory.h"
#import "BXGamebox.h"
#import "NSURL+ADBFilesystemHelpers.h"

NSString * const BXZipArchiveType = @"public.zip-archive";

// Where the metadata archive sits, relative to an eXoDOS pack's root.
static NSString * const BXeXoDOSMetadataSubpath = @"Content/!DOSmetadata.zip";

// The zero-byte marker file that identifies an eXoDOS game. Its basename is
// the game's full title including the year.
static NSString * const BXeXoDOSMarkerExtension = @"exo";


#pragma mark - BXArchiveClassification

@interface BXArchiveClassification ()
@property (readwrite, nonatomic) BXArchiveKind kind;
@property (readwrite, copy, nonatomic) NSURL *sourceURL;
@property (readwrite, copy, nonatomic, nullable) NSString *gameTitle;
@property (readwrite, copy, nonatomic, nullable) NSString *shortName;
@property (readwrite, nonatomic) unsigned long long unpackedSize;
@property (readwrite, copy, nonatomic, nullable) NSString *rejectionReason;
@end

@implementation BXArchiveClassification

- (NSString *) localizedSummary
{
    switch (self.kind)
    {
        case BXArchiveKindeXoDOSGame:
            return [NSString stringWithFormat: NSLocalizedString(@"“%@”, an eXoDOS game.",
                @"Summary shown when Boxer recognises a dropped archive as an eXoDOS game. %@ is the game's title."),
                    self.gameTitle];

        case BXArchiveKindGamebox:
            return [NSString stringWithFormat: NSLocalizedString(@"“%@”, a zipped gamebox.",
                @"Summary shown when a dropped archive contains an existing gamebox. %@ is the gamebox's name."),
                    self.gameTitle];

        case BXArchiveKindGenericZip:
        default:
            return NSLocalizedString(@"A zip archive of DOS game files.",
                @"Summary shown when a dropped archive is not recognised as anything more specific.");
    }
}

- (NSString *) description
{
    return [NSString stringWithFormat: @"<%@: %@>", self.class, self.localizedSummary];
}

@end


#pragma mark - BXImportClassifier

@implementation BXImportClassifier

+ (BOOL) isZipArchiveAtURL: (NSURL *)URL
{
    // Ask the file system what it is rather than trusting the extension: a
    // zip arriving from elsewhere may be named anything.
    return [URL conformsToFileType: BXZipArchiveType];
}

+ (BXArchiveClassification *) classifyArchiveAtURL: (NSURL *)URL error: (NSError **)outError
{
    BXZipCentralDirectory *directory = [BXZipCentralDirectory directoryWithContentsOfURL: URL
                                                                                   error: outError];
    if (!directory) return nil;

    BXArchiveClassification *classification = [[BXArchiveClassification alloc] init];
    classification.sourceURL = URL;
    classification.unpackedSize = directory.totalUncompressedSize;

    // Every shape we recognise has exactly one root-level directory. Anything
    // else is a loose bag of files, which is the generic case by definition.
    NSSet *roots = directory.rootLevelNames;
    if (roots.count != 1)
    {
        classification.kind = BXArchiveKindGenericZip;
        classification.rejectionReason = [NSString stringWithFormat:
            NSLocalizedString(@"The archive has %lu top-level items, rather than a single game folder.",
                @"Explanation shown when an archive has the wrong shape to be a game. %lu is the number of items."),
            (unsigned long)roots.count];
        return classification;
    }

    NSString *root = roots.anyObject;

    // Gate one: a zipped-up gamebox. Validated by the file Boxer actually
    // looks for inside one, not by the folder's name alone.
    if ([root.pathExtension caseInsensitiveCompare: @"boxer"] == NSOrderedSame)
    {
        NSString *infoName = [BXGameInfoFileName stringByAppendingPathExtension: BXGameInfoFileExtension];
        NSString *infoPath = [root stringByAppendingPathComponent: infoName];

        if ([directory entryAtPath: infoPath])
        {
            classification.kind = BXArchiveKindGamebox;
            classification.gameTitle = root.stringByDeletingPathExtension;
            classification.shortName = root;
            return classification;
        }

        classification.kind = BXArchiveKindGenericZip;
        classification.rejectionReason = [NSString stringWithFormat:
            NSLocalizedString(@"“%@” is named like a gamebox but contains no %@.",
                @"Explanation shown when a .boxer folder in an archive is not a real gamebox. %@s are the folder name and the expected file name."),
            root, infoName];
        return classification;
    }

    // Gate two: an eXoDOS game, marked by exactly one zero-byte .exo file
    // whose basename is the game's full title.
    NSArray *markers = [self _markerPathsInDirectory: directory];
    if (markers.count == 1)
    {
        NSString *marker = markers.firstObject;
        classification.kind = BXArchiveKindeXoDOSGame;
        classification.shortName = root;
        classification.gameTitle = marker.lastPathComponent.stringByDeletingPathExtension;
        return classification;
    }

    classification.kind = BXArchiveKindGenericZip;
    classification.rejectionReason = markers.count
        ? [NSString stringWithFormat:
            NSLocalizedString(@"The archive contains %lu eXoDOS markers, rather than one.",
                @"Explanation shown when an archive has more than one .exo file. %lu is the number found."),
            (unsigned long)markers.count]
        : NSLocalizedString(@"The archive contains no eXoDOS marker file.",
            @"Explanation shown when an archive has no .exo file.");
    return classification;
}

+ (NSArray<NSString *> *) _markerPathsInDirectory: (BXZipCentralDirectory *)directory
{
    NSMutableArray *markers = [NSMutableArray array];
    for (BXZipEntry *entry in directory.entries)
    {
        if (!entry.isDirectory &&
            [entry.path.pathExtension caseInsensitiveCompare: BXeXoDOSMarkerExtension] == NSOrderedSame)
        {
            [markers addObject: entry.path];
        }
    }
    return markers;
}


#pragma mark - Locating the pack

+ (NSURL *) metadataArchiveURLForGameArchiveAtURL: (NSURL *)URL
{
    // <pack>/eXo/eXoDOS/<game>.zip -- so the pack root is two levels up.
    NSURL *packURL = URL.URLByDeletingLastPathComponent   // eXo/eXoDOS
                        .URLByDeletingLastPathComponent   // eXo
                        .URLByDeletingLastPathComponent;  // the pack root

    NSURL *metadataURL = [self metadataArchiveURLInPackAtURL: packURL];
    if (metadataURL) return metadataURL;

    // Also accept a game sitting directly beside the pack's Content folder,
    // which is how a single game handed to someone else tends to be arranged.
    return [self metadataArchiveURLInPackAtURL: URL.URLByDeletingLastPathComponent];
}

+ (NSURL *) metadataArchiveURLInPackAtURL: (NSURL *)packURL
{
    if (!packURL) return nil;

    NSURL *metadataURL = [packURL URLByAppendingPathComponent: BXeXoDOSMetadataSubpath];
    if ([metadataURL checkResourceIsReachableAndReturnError: NULL]) return metadataURL;

    return nil;
}

@end
