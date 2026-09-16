/*
 *  Copyright (c) 2026 Alun Bestor and contributors. All rights reserved.
 *  This source file is released under the GNU General Public License 2.0.
 *  A full copy of this license can be found in this project's README.
 */

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// One entry from a zip archive's central directory.
@interface BXZipEntry : NSObject

/// The entry's path within the archive, with '/' separators.
@property (readonly, copy, nonatomic) NSString *path;

/// The entry's size once inflated. Zip64 sizes are resolved, so this is
/// meaningful for entries larger than 4GB.
@property (readonly, nonatomic) unsigned long long uncompressedSize;

/// Whether the entry is a directory rather than a file.
@property (readonly, nonatomic, getter=isDirectory) BOOL directory;

@end


/// Reads a zip archive's central directory without inflating anything.
///
/// This is all that classifying a dropped archive needs: the entry names and
/// their inflated sizes. Because the central directory sits at the end of the
/// file and refers to everything by offset, reading it stays fast even on a
/// multi-gigabyte archive -- which matters, because eXoDOS games routinely run
/// to hundreds of megabytes and the import wizard wants to name the game and
/// total its unpacked size before the user has picked a destination.
///
/// Only the directory is parsed; extracting an entry's data is a separate job
/// and needs an inflater. Zip64 archives are handled, since the pack contains
/// archives well past the 4GB that the original format can express.
@interface BXZipCentralDirectory : NSObject

/// Reads the central directory of the archive at the specified URL.
/// Returns nil and populates outError if the file is not a readable zip.
+ (nullable instancetype) directoryWithContentsOfURL: (NSURL *)URL
                                               error: (NSError **)outError;

/// The archive's entries, in the order the central directory lists them.
@property (readonly, copy, nonatomic) NSArray<BXZipEntry *> *entries;

/// The paths of every entry, for cheap membership tests.
@property (readonly, nonatomic) NSSet<NSString *> *paths;

/// The total inflated size of every file entry: what the archive will occupy
/// on disk once unpacked.
@property (readonly, nonatomic) unsigned long long totalUncompressedSize;

/// The names of the archive's root-level items, without trailing slashes.
/// A well-formed eXoDOS game archive has exactly one.
@property (readonly, nonatomic) NSSet<NSString *> *rootLevelNames;

/// Returns the entry at the specified path, matched case-insensitively,
/// or nil if the archive has no such entry.
- (nullable BXZipEntry *) entryAtPath: (NSString *)path;

@end

/// Error domain and codes for zip parsing failures.
extern NSErrorDomain const BXZipErrorDomain;

typedef NS_ERROR_ENUM(BXZipErrorDomain, BXZipErrorCode) {
    BXZipErrorNotAZipFile,          //!< No end-of-central-directory record was found.
    BXZipErrorMalformedDirectory,   //!< The central directory is truncated or inconsistent.
};

NS_ASSUME_NONNULL_END
