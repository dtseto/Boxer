/*
 *  Copyright (c) 2026 Alun Bestor and contributors. All rights reserved.
 *  This source file is released under the GNU General Public License 2.0.
 *  A full copy of this license can be found in this project's README.
 */

#import "BXZipCentralDirectory.h"

NSErrorDomain const BXZipErrorDomain = @"BXZipErrorDomain";

// Signatures, little-endian, from the PKWARE APPNOTE.
static const uint32_t BXZipEndOfCentralDirectorySignature        = 0x06054b50;
static const uint32_t BXZipCentralFileHeaderSignature            = 0x02014b50;
static const uint32_t BXZip64EndOfCentralDirectorySignature      = 0x06064b50;
static const uint32_t BXZip64EndOfCentralDirectoryLocatorSignature = 0x07064b50;

// Fixed sizes of the records we read.
static const NSUInteger BXZipEndOfCentralDirectoryLength   = 22;
static const NSUInteger BXZipCentralFileHeaderLength       = 46;
static const NSUInteger BXZip64LocatorLength               = 20;

// The end-of-central-directory record is followed by a comment of up to 64KB,
// so it can sit that far from the end of the file. There is nowhere else it
// can be, which bounds the backwards search.
static const NSUInteger BXZipMaximumCommentLength = 65535;

// A 32-bit field set to all-ones means "look in the zip64 extra field".
static const uint32_t BXZip64Marker = 0xFFFFFFFF;


#pragma mark - Reading little-endian scalars

// The archive is memory-mapped, so these read straight out of it. Each one
// bounds-checks first: a truncated or hostile archive must fail, not crash.
static BOOL BXZipReadUInt16(NSData *data, NSUInteger offset, uint16_t *outValue)
{
    if (offset + sizeof(uint16_t) > data.length) return NO;
    uint16_t value;
    [data getBytes: &value range: NSMakeRange(offset, sizeof(value))];
    *outValue = CFSwapInt16LittleToHost(value);
    return YES;
}

static BOOL BXZipReadUInt32(NSData *data, NSUInteger offset, uint32_t *outValue)
{
    if (offset + sizeof(uint32_t) > data.length) return NO;
    uint32_t value;
    [data getBytes: &value range: NSMakeRange(offset, sizeof(value))];
    *outValue = CFSwapInt32LittleToHost(value);
    return YES;
}

static BOOL BXZipReadUInt64(NSData *data, NSUInteger offset, uint64_t *outValue)
{
    if (offset + sizeof(uint64_t) > data.length) return NO;
    uint64_t value;
    [data getBytes: &value range: NSMakeRange(offset, sizeof(value))];
    *outValue = CFSwapInt64LittleToHost(value);
    return YES;
}


#pragma mark - BXZipEntry

@interface BXZipEntry ()
@property (readwrite, copy, nonatomic) NSString *path;
@property (readwrite, nonatomic) unsigned long long uncompressedSize;
@property (readwrite, nonatomic) unsigned long long compressedSize;
@property (readwrite, nonatomic) uint16_t compressionMethod;
@property (readwrite, nonatomic) unsigned long long localHeaderOffset;
@property (readwrite, nonatomic) uint32_t CRC32;
@end

@implementation BXZipEntry

- (BOOL) isDirectory
{
    return [self.path hasSuffix: @"/"];
}

- (NSString *) description
{
    return [NSString stringWithFormat: @"<%@: %@ (%llu bytes)>",
            self.class, self.path, self.uncompressedSize];
}

@end


#pragma mark - BXZipCentralDirectory

@interface BXZipCentralDirectory ()
@property (readwrite, copy, nonatomic) NSArray<BXZipEntry *> *entries;
@property (strong, nonatomic) NSDictionary<NSString *, BXZipEntry *> *entriesByLowercasePath;
@end

@implementation BXZipCentralDirectory
{
    NSSet<NSString *> *_paths;
    NSSet<NSString *> *_rootLevelNames;
    unsigned long long _totalUncompressedSize;
}

+ (instancetype) directoryWithContentsOfURL: (NSURL *)URL error: (NSError **)outError
{
    NSFileHandle *handle = [NSFileHandle fileHandleForReadingFromURL: URL error: outError];
    if (!handle) return nil;

    BXZipCentralDirectory *directory = [[self alloc] init];
    BOOL parsed = [directory _parseHandle: handle error: outError];
    [handle closeFile];
    return parsed ? directory : nil;
}

/// Reads only the two regions that matter: the tail, where the
/// end-of-central-directory record lives, and the central directory itself.
///
/// The entry data in between -- which is all but a fraction of the file -- is
/// never touched. That distinction is the difference between classifying a
/// 44GB archive in under a second and spending six minutes reading it: mapping
/// the whole file is not an option either, because NSData declines to map
/// files on external and network volumes and silently reads them instead,
/// which is exactly where an eXoDOS pack tends to live.
- (BOOL) _parseHandle: (NSFileHandle *)handle error: (NSError **)outError
{
    unsigned long long fileSize = 0;
    if (![handle seekToEndReturningOffset: &fileSize error: outError]) return NO;

    if (fileSize < BXZipEndOfCentralDirectoryLength)
        return [self _failWithNotAZipFile: outError];

    // The end record sits within a comment's length of the end, and nowhere
    // else, which bounds how much of the tail we need.
    NSUInteger tailLength = (NSUInteger)MIN(fileSize,
        (unsigned long long)(BXZipEndOfCentralDirectoryLength + BXZipMaximumCommentLength));
    unsigned long long tailStart = fileSize - tailLength;

    NSData *tail = [self _readHandle: handle at: tailStart length: tailLength error: outError];
    if (!tail) return NO;

    NSUInteger endRecordOffset;
    if (![self _findEndRecordInData: tail offset: &endRecordOffset])
        return [self _failWithNotAZipFile: outError];

    uint16_t entryCount16 = 0;
    uint32_t directorySize32 = 0, directoryOffset32 = 0;
    if (!BXZipReadUInt16(tail, endRecordOffset + 10, &entryCount16) ||
        !BXZipReadUInt32(tail, endRecordOffset + 12, &directorySize32) ||
        !BXZipReadUInt32(tail, endRecordOffset + 16, &directoryOffset32))
    {
        return [self _failWithMalformedDirectory: outError];
    }

    unsigned long long entryCount = entryCount16;
    unsigned long long directorySize = directorySize32;
    unsigned long long directoryOffset = directoryOffset32;

    // An archive past 4GB, or past 65,535 entries, records the real values in
    // a zip64 record that sits just before the one we found. The pack has
    // archives of both kinds.
    if (entryCount16 == 0xFFFF || directorySize32 == BXZip64Marker ||
        directoryOffset32 == BXZip64Marker)
    {
        if (![self _readZip64EndForHandle: handle
                                     tail: tail
                                tailStart: tailStart
                            endRecordOffset: endRecordOffset
                               entryCount: &entryCount
                            directorySize: &directorySize
                          directoryOffset: &directoryOffset
                                    error: outError])
        {
            return NO;
        }
    }

    if (directoryOffset + directorySize > fileSize)
        return [self _failWithMalformedDirectory: outError];

    NSData *data = [self _readHandle: handle
                                  at: directoryOffset
                              length: (NSUInteger)directorySize
                               error: outError];
    if (!data) return NO;

    NSMutableArray *entries = [NSMutableArray arrayWithCapacity: (NSUInteger)entryCount];
    NSMutableDictionary *byPath = [NSMutableDictionary dictionaryWithCapacity: (NSUInteger)entryCount];
    NSMutableSet *paths = [NSMutableSet setWithCapacity: (NSUInteger)entryCount];
    NSMutableSet *roots = [NSMutableSet set];
    unsigned long long total = 0;

    // Offsets are now relative to the chunk we read, which starts at the
    // central directory itself.
    NSUInteger offset = 0;
    for (unsigned long long i = 0; i < entryCount; i++)
    {
        uint32_t signature = 0;
        if (!BXZipReadUInt32(data, offset, &signature) ||
            signature != BXZipCentralFileHeaderSignature)
        {
            return [self _failWithMalformedDirectory: outError];
        }

        uint32_t uncompressedSize32 = 0, compressedSize32 = 0, localOffset32 = 0, crc = 0;
        uint16_t nameLength = 0, extraLength = 0, commentLength = 0, method = 0;
        if (!BXZipReadUInt16(data, offset + 10, &method) ||
            !BXZipReadUInt32(data, offset + 16, &crc) ||
            !BXZipReadUInt32(data, offset + 20, &compressedSize32) ||
            !BXZipReadUInt32(data, offset + 24, &uncompressedSize32) ||
            !BXZipReadUInt16(data, offset + 28, &nameLength) ||
            !BXZipReadUInt16(data, offset + 30, &extraLength) ||
            !BXZipReadUInt16(data, offset + 32, &commentLength) ||
            !BXZipReadUInt32(data, offset + 42, &localOffset32))
        {
            return [self _failWithMalformedDirectory: outError];
        }

        NSUInteger nameOffset = offset + BXZipCentralFileHeaderLength;
        if (nameOffset + nameLength > data.length)
            return [self _failWithMalformedDirectory: outError];

        NSString *path = [[NSString alloc] initWithData: [data subdataWithRange: NSMakeRange(nameOffset, nameLength)]
                                               encoding: NSUTF8StringEncoding];
        // Entry names are UTF-8 only when the archive says so; otherwise the
        // format specifies IBM Code Page 437. Falling back keeps a game with
        // an accented title readable rather than dropping the entry.
        if (!path)
            path = [[NSString alloc] initWithData: [data subdataWithRange: NSMakeRange(nameOffset, nameLength)]
                                         encoding: NSWindowsCP1252StringEncoding];
        if (!path) return [self _failWithMalformedDirectory: outError];

        unsigned long long uncompressedSize = uncompressedSize32;
        unsigned long long compressedSize = compressedSize32;
        unsigned long long localOffset = localOffset32;
        if (uncompressedSize32 == BXZip64Marker || compressedSize32 == BXZip64Marker ||
            localOffset32 == BXZip64Marker)
        {
            [self _readZip64Fields: data
                            offset: nameOffset + nameLength
                            length: extraLength
                  uncompressedSize: (uncompressedSize32 == BXZip64Marker) ? &uncompressedSize : NULL
                    compressedSize: (compressedSize32 == BXZip64Marker) ? &compressedSize : NULL
                 localHeaderOffset: (localOffset32 == BXZip64Marker) ? &localOffset : NULL];
        }

        BXZipEntry *entry = [[BXZipEntry alloc] init];
        entry.path = path;
        entry.uncompressedSize = uncompressedSize;
        entry.compressedSize = compressedSize;
        entry.compressionMethod = method;
        entry.localHeaderOffset = localOffset;
        entry.CRC32 = crc;

        [entries addObject: entry];
        [paths addObject: path];
        byPath[path.lowercaseString] = entry;
        if (!entry.isDirectory) total += uncompressedSize;

        NSString *root = [path componentsSeparatedByString: @"/"].firstObject;
        if (root.length) [roots addObject: root];

        offset = nameOffset + nameLength + extraLength + commentLength;
    }

    self.entries = entries;
    self.entriesByLowercasePath = byPath;
    _paths = paths;
    _rootLevelNames = roots;
    _totalUncompressedSize = total;
    return YES;
}

- (BOOL) _failWithNotAZipFile: (NSError **)outError
{
    if (outError)
        *outError = [NSError errorWithDomain: BXZipErrorDomain
                                        code: BXZipErrorNotAZipFile
                                    userInfo: nil];
    return NO;
}

- (BOOL) _failWithMalformedDirectory: (NSError **)outError
{
    if (outError)
        *outError = [NSError errorWithDomain: BXZipErrorDomain
                                        code: BXZipErrorMalformedDirectory
                                    userInfo: nil];
    return NO;
}

/// Scans backwards from the end of the file for the end-of-central-directory
/// signature, which is the only fixed landmark a zip has.
- (BOOL) _findEndRecordInData: (NSData *)data offset: (NSUInteger *)outOffset
{
    if (data.length < BXZipEndOfCentralDirectoryLength) return NO;

    NSUInteger maximumDistance = MIN(data.length,
                                     BXZipEndOfCentralDirectoryLength + BXZipMaximumCommentLength);
    NSUInteger lastPossible = data.length - BXZipEndOfCentralDirectoryLength;
    NSUInteger earliestPossible = data.length - maximumDistance;

    for (NSUInteger offset = lastPossible + 1; offset > earliestPossible; offset--)
    {
        uint32_t signature = 0;
        if (BXZipReadUInt32(data, offset - 1, &signature) &&
            signature == BXZipEndOfCentralDirectorySignature)
        {
            *outOffset = offset - 1;
            return YES;
        }
    }
    return NO;
}

/// Follows the zip64 locator that precedes the 32-bit end record, to the
/// zip64 end record that holds the real entry count, size and offset.
///
/// The locator sits immediately before the end record, so it is normally
/// already in the tail we read; the record it points at can be anywhere, so
/// that one is fetched on its own.
- (BOOL) _readZip64EndForHandle: (NSFileHandle *)handle
                           tail: (NSData *)tail
                      tailStart: (unsigned long long)tailStart
                endRecordOffset: (NSUInteger)endRecordOffset
                     entryCount: (unsigned long long *)outCount
                  directorySize: (unsigned long long *)outSize
                directoryOffset: (unsigned long long *)outOffset
                          error: (NSError **)outError
{
    if (endRecordOffset < BXZip64LocatorLength)
        return [self _failWithMalformedDirectory: outError];

    NSUInteger locatorOffset = endRecordOffset - BXZip64LocatorLength;
    uint32_t signature = 0;
    uint64_t recordOffset = 0;
    if (!BXZipReadUInt32(tail, locatorOffset, &signature) ||
        signature != BXZip64EndOfCentralDirectoryLocatorSignature ||
        !BXZipReadUInt64(tail, locatorOffset + 8, &recordOffset))
    {
        return [self _failWithMalformedDirectory: outError];
    }

    // The fixed part of the zip64 end record runs to 56 bytes; everything we
    // need is inside that.
    NSData *record = [self _readHandle: handle at: recordOffset length: 56 error: outError];
    if (!record) return NO;

    uint32_t recordSignature = 0;
    if (!BXZipReadUInt32(record, 0, &recordSignature) ||
        recordSignature != BXZip64EndOfCentralDirectorySignature ||
        !BXZipReadUInt64(record, 32, outCount) ||
        !BXZipReadUInt64(record, 40, outSize) ||
        !BXZipReadUInt64(record, 48, outOffset))
    {
        return [self _failWithMalformedDirectory: outError];
    }
    return YES;
}

/// Reads one range of the file, failing rather than returning a short read.
- (NSData *) _readHandle: (NSFileHandle *)handle
                      at: (unsigned long long)offset
                  length: (NSUInteger)length
                   error: (NSError **)outError
{
    if (![handle seekToOffset: offset error: outError]) return nil;

    NSData *data = [handle readDataUpToLength: length error: outError];
    if (!data) return nil;
    if (data.length < length)
    {
        [self _failWithMalformedDirectory: outError];
        return nil;
    }
    return data;
}

/// Walks an entry's extra-field blocks looking for the zip64 record (id 0x0001).
///
/// Its values are packed in a fixed order -- uncompressed size, compressed
/// size, local header offset, start disk -- but each one is present only when
/// the 32-bit field it replaces was set to all-ones. So the caller says which
/// of them it is expecting, and they are consumed in order; asking for a field
/// that is not there would otherwise read the next field's bytes as its own.
- (void) _readZip64Fields: (NSData *)data
                   offset: (NSUInteger)offset
                   length: (NSUInteger)length
         uncompressedSize: (nullable unsigned long long *)outUncompressed
           compressedSize: (nullable unsigned long long *)outCompressed
        localHeaderOffset: (nullable unsigned long long *)outLocalOffset
{
    NSUInteger end = offset + length;
    while (offset + 4 <= end)
    {
        uint16_t blockID = 0, blockLength = 0;
        if (!BXZipReadUInt16(data, offset, &blockID) ||
            !BXZipReadUInt16(data, offset + 2, &blockLength))
        {
            return;
        }
        if (blockID == 0x0001)
        {
            NSUInteger cursor = offset + 4;
            NSUInteger blockEnd = cursor + blockLength;
            unsigned long long *wanted[] = { outUncompressed, outCompressed, outLocalOffset };
            for (int i = 0; i < 3; i++)
            {
                if (!wanted[i]) continue;
                if (cursor + 8 > blockEnd) return;
                BXZipReadUInt64(data, cursor, wanted[i]);
                cursor += 8;
            }
            return;
        }
        offset += 4 + blockLength;
    }
}

#pragma mark - Accessors

- (NSSet<NSString *> *) paths                       { return _paths; }
- (NSSet<NSString *> *) rootLevelNames              { return _rootLevelNames; }
- (unsigned long long) totalUncompressedSize        { return _totalUncompressedSize; }

- (BXZipEntry *) entryAtPath: (NSString *)path
{
    return self.entriesByLowercasePath[path.lowercaseString];
}

@end
