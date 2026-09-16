/*
 *  Copyright (c) 2026 Alun Bestor and contributors. All rights reserved.
 *  This source file is released under the GNU General Public License 2.0.
 *  A full copy of this license can be found in this project's README.
 */

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// The UTI for zip archives. Spelled out rather than taken from CoreServices,
/// matching how the import code names its other types.
extern NSString * const BXZipArchiveType;

/// What Boxer believes a dropped zip archive to be.
typedef NS_ENUM(NSInteger, BXArchiveKind) {
    /// Neither of the below: offer to unzip it as-is into a gamebox.
    BXArchiveKindGenericZip,
    /// A zipped-up gamebox. Not an import at all -- unarchive it and open it.
    BXArchiveKindGamebox,
    /// An eXoDOS game archive, identified by its .exo marker.
    BXArchiveKindExoDOSGame,
};


/// Boxer's reading of a zip archive, decided from its central directory alone.
///
/// Nothing is extracted to produce this, so it is cheap even on a
/// multi-gigabyte archive, and the wizard can show the real game name and
/// unpacked size before the user has chosen a destination.
@interface BXArchiveClassification : NSObject

@property (readonly, nonatomic) BXArchiveKind kind;

/// The archive that was examined.
@property (readonly, copy, nonatomic) NSURL *sourceURL;

/// The game's full title, including the year, taken from the .exo marker's
/// filename. Nil for anything but an eXoDOS game.
///
/// eXo's LaunchBox metadata also carries a title, but the .exo name is already
/// correct and needs no lookup, so it is what names the gamebox.
@property (readonly, copy, nonatomic, nullable) NSString *gameTitle;

/// eXo's short name for the game: the archive's single root directory, and the
/// key under which its configuration is filed in the metadata archive.
@property (readonly, copy, nonatomic, nullable) NSString *shortName;

/// How much room the archive's contents will need once unpacked.
@property (readonly, nonatomic) unsigned long long unpackedSize;

/// Why the archive was classified as a generic zip, for display when the user
/// expected otherwise. Nil for the other kinds.
@property (readonly, copy, nonatomic, nullable) NSString *rejectionReason;

/// A one-line description of what Boxer thinks this is, fit to show the user.
@property (readonly, nonatomic) NSString *localizedSummary;

@end


/// Classifies dropped zip archives, and locates the eXoDOS pack that an
/// eXoDOS game needs in order to be converted.
@interface BXImportClassifier : NSObject

/// Examines the zip archive at the specified URL and reports what Boxer makes
/// of it. Returns nil only if the file could not be read as a zip at all.
+ (nullable BXArchiveClassification *) classifyArchiveAtURL: (NSURL *)URL
                                                      error: (NSError **)outError;

/// Returns YES if the URL looks like a zip archive by type, without opening it.
+ (BOOL) isZipArchiveAtURL: (NSURL *)URL;

/// Locates the eXoDOS metadata archive belonging to a game archive.
///
/// An eXoDOS game holds no configuration of its own: its `dosbox.conf` lives
/// in the pack's `!DOSmetadata.zip`, which is where the drive layout, the
/// launch command and the machine settings all come from. Without it there is
/// nothing to convert, so this is a hard requirement rather than a nicety.
///
/// Games sit at `<pack>/eXo/eXoDOS/<game>.zip` and the metadata at
/// `<pack>/Content/!DOSmetadata.zip`, so a game dragged straight out of the
/// pack finds it two levels up and across. A game copied elsewhere first will
/// not, and the caller is expected to ask the user where the pack is.
+ (nullable NSURL *) metadataArchiveURLForGameArchiveAtURL: (NSURL *)URL;

/// Returns the metadata archive inside an eXoDOS pack rooted at the given URL,
/// or nil if that folder does not hold one.
+ (nullable NSURL *) metadataArchiveURLInPackAtURL: (NSURL *)packURL;

@end

NS_ASSUME_NONNULL_END
