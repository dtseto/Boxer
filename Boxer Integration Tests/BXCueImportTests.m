#import <XCTest/XCTest.h>
#import "ADBBinCueImage.h"
#import "BXDrive.h"
#import "BXDriveBundleImport.h"
#import "BXImportSession.h"

@interface BXCueImportTests : XCTestCase
@property (nonatomic, strong) NSURL *temporaryURL;
@end

@implementation BXCueImportTests

- (void)setUp
{
    [super setUp];
    self.temporaryURL = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString]
                                  isDirectory:YES];
    [[NSFileManager defaultManager] createDirectoryAtURL:self.temporaryURL
                             withIntermediateDirectories:YES attributes:nil error:NULL];
}

- (void)tearDown
{
    [[NSFileManager defaultManager] removeItemAtURL:self.temporaryURL error:NULL];
    [super tearDown];
}

- (NSURL *)writeCue:(NSString *)contents named:(NSString *)name
{
    NSURL *URL = [self.temporaryURL URLByAppendingPathComponent:name];
    XCTAssertTrue([contents writeToURL:URL atomically:YES encoding:NSUTF8StringEncoding error:NULL]);
    return URL;
}

- (NSURL *)writeTrack:(NSString *)relativePath bytes:(NSUInteger)bytes
{
    NSURL *URL = [self.temporaryURL URLByAppendingPathComponent:relativePath];
    [[NSFileManager defaultManager] createDirectoryAtURL:URL.URLByDeletingLastPathComponent
                             withIntermediateDirectories:YES attributes:nil error:NULL];
    NSMutableData *data = [NSMutableData dataWithLength:bytes ?: 4];
    XCTAssertTrue([data writeToURL:URL options:0 error:NULL]);
    return URL;
}

- (void)testSingleBINAndIMGAndQuotedSpaceCues
{
    [self writeTrack:@"Game Disc.bin" bytes:0];
    NSURL *cue = [self writeCue:@"FILE \"Game Disc.bin\" BINARY\n  TRACK 01 MODE1/2352\n    INDEX 01 00:00:00\n" named:@"game.cue"];
    XCTAssertEqual([ADBBinCueImage validatedResourceURLsInCueAtURL:cue error:NULL].count, 1U);

    [self writeTrack:@"disk.img" bytes:0];
    cue = [self writeCue:@"file disk.img binary\ntrack 01 mode1/2352\nindex 01 00:00:00\n" named:@"image.cue"];
    XCTAssertEqualObjects([ADBBinCueImage validatedResourceURLsInCueAtURL:cue error:NULL].firstObject.lastPathComponent, @"disk.img");
    XCTAssertTrue([BXImportSession canImportFromSourceURL:cue]);

    NSURL *iso = [self writeTrack:@"unchanged.iso" bytes:0];
    XCTAssertTrue([BXImportSession canImportFromSourceURL:iso], @"Existing ISO import acceptance must remain unchanged");
}

- (void)testMultipleMixedModeTracksAndEscapedQuotes
{
    [self writeTrack:@"data.bin" bytes:0];
    [self writeTrack:@"Audio 02.wav" bytes:0];
    [self writeTrack:@"Audio \"03\".mp3" bytes:0];
    NSString *contents = @"FILE data.bin BINARY\n TRACK 01 MODE1/2352\nFILE \"Audio 02.wav\" WAVE\n TRACK 02 AUDIO\nFILE \"Audio \\\"03\\\".mp3\" MP3\n TRACK 03 AUDIO\n";
    NSURL *cue = [self writeCue:contents named:@"mixed.cue"];
    NSArray *URLs = [ADBBinCueImage validatedResourceURLsInCueAtURL:cue error:NULL];
    XCTAssertEqual(URLs.count, 3U);
    XCTAssertEqualObjects([ADBBinCueImage rawPathsInCueContents:contents].lastObject, @"Audio \"03\".mp3");
}

- (void)testWindowsSeparatorsNestedPathsAndCaseCorrection
{
    [self writeTrack:@"Tracks/DATA.BIN" bytes:0];
    NSURL *cue = [self writeCue:@"FILE \"tracks\\data.bin\" BINARY\nTRACK 01 MODE1/2352\n" named:@"windows.cue"];
    NSArray *URLs = [ADBBinCueImage validatedResourceURLsInCueAtURL:cue error:NULL];
    XCTAssertEqualObjects(((NSURL *)URLs.firstObject).lastPathComponent, @"DATA.BIN");

    [self writeTrack:@"absolute.bin" bytes:0];
    cue = [self writeCue:@"FILE \"C:\\old\\absolute.bin\" BINARY\nTRACK 01 MODE1/2352\n" named:@"windows-absolute.cue"];
    URLs = [ADBBinCueImage validatedResourceURLsInCueAtURL:cue error:NULL];
    XCTAssertEqualObjects(((NSURL *)URLs.firstObject).lastPathComponent, @"absolute.bin");
}

- (void)testMissingTraversalAndAbsoluteExternalPaths
{
    NSURL *missing = [self writeCue:@"FILE missing.bin BINARY\nTRACK 01 MODE1/2352\n" named:@"missing.cue"];
    NSError *error = nil;
    XCTAssertNil([ADBBinCueImage validatedResourceURLsInCueAtURL:missing error:&error]);
    XCTAssertEqual(error.code, ADBCueErrorMissingTrack);

    NSURL *traversal = [self writeCue:@"FILE ../outside.bin BINARY\nTRACK 01 MODE1/2352\n" named:@"traversal.cue"];
    error = nil;
    XCTAssertNil([ADBBinCueImage validatedResourceURLsInCueAtURL:traversal error:&error]);
    XCTAssertEqual(error.code, ADBCueErrorUnsafePath);

    NSURL *externalFolder = [self.temporaryURL URLByAppendingPathComponent:@"external" isDirectory:YES];
    [[NSFileManager defaultManager] createDirectoryAtURL:externalFolder withIntermediateDirectories:YES attributes:nil error:NULL];
    NSURL *external = [externalFolder URLByAppendingPathComponent:@"track.wav"];
    [[NSData dataWithBytes:"x" length:1] writeToURL:external atomically:YES];
    NSURL *absolute = [self writeCue:[NSString stringWithFormat:@"FILE \"%@\" WAVE\nTRACK 01 AUDIO\n", external.path] named:@"absolute.cue"];
    XCTAssertEqual([ADBBinCueImage validatedResourceURLsInCueAtURL:absolute error:NULL].count, 1U);
}

- (void)testDriveBundlePreservesNestedLayoutRelocatesExternalFilesAndKeepsCueAsMountPoint
{
    [self writeTrack:@"tracks/data.bin" bytes:0];
    NSURL *outsideOne = [self writeTrack:@"outside-one/same.wav" bytes:0];
    NSURL *outsideTwo = [self writeTrack:@"outside-two/same.wav" bytes:0];
    NSString *cueText = [NSString stringWithFormat:
                         @"FILE tracks\\data.bin BINARY\nTRACK 01 MODE1/2352\nFILE \"%@\" WAVE\nTRACK 02 AUDIO\nFILE \"%@\" MP3\nTRACK 03 AUDIO\n",
                         outsideOne.path, outsideTwo.path];
    NSURL *cue = [self writeCue:cueText named:@"bundle.cue"];
    NSURL *destination = [self.temporaryURL URLByAppendingPathComponent:@"Destination" isDirectory:YES];
    [[NSFileManager defaultManager] createDirectoryAtURL:destination withIntermediateDirectories:YES attributes:nil error:NULL];

    BXDrive *drive = [BXDrive driveWithContentsOfURL:cue letter:@"D" type:BXDriveCDROM];
    BXDriveBundleImport *operation = [[BXDriveBundleImport alloc] initForDrive:drive destinationFolderURL:destination copyFiles:YES];
    [operation start];

    XCTAssertTrue(operation.succeeded, @"%@", operation.error);
    NSURL *copiedCue = [operation.destinationURL URLByAppendingPathComponent:@"tracks.cue"];
    NSString *rewritten = [NSString stringWithContentsOfURL:copiedCue encoding:NSUTF8StringEncoding error:NULL];
    XCTAssertNotNil(rewritten);
    XCTAssertTrue([[NSFileManager defaultManager] fileExistsAtPath:[operation.destinationURL URLByAppendingPathComponent:@"tracks/data.bin"].path]);
    XCTAssertTrue([rewritten containsString:@"External Tracks/same.wav"]);
    XCTAssertTrue([rewritten containsString:@"External Tracks/same (2).wav"]);
    BXDrive *copiedDrive = [BXDrive driveWithContentsOfURL:operation.destinationURL letter:@"D" type:BXDriveCDROM];
    XCTAssertEqualObjects(copiedDrive.mountPointURL, copiedCue);
    BXDrive *liveCueDrive = [BXDrive driveWithContentsOfURL:copiedCue letter:@"D" type:BXDriveCDROM];
    XCTAssertEqualObjects(liveCueDrive.sourceURL, copiedCue);
}

- (void)testCancelledDriveBundleLeavesNoPartialMedia
{
    [self writeTrack:@"large.bin" bytes:16 * 1024 * 1024];
    NSURL *cue = [self writeCue:@"FILE large.bin BINARY\nTRACK 01 MODE1/2352\n" named:@"cancel.cue"];
    NSURL *destination = [self.temporaryURL URLByAppendingPathComponent:@"Cancelled" isDirectory:YES];
    [[NSFileManager defaultManager] createDirectoryAtURL:destination withIntermediateDirectories:YES attributes:nil error:NULL];
    BXDrive *drive = [BXDrive driveWithContentsOfURL:cue letter:@"D" type:BXDriveCDROM];
    BXDriveBundleImport *operation = [[BXDriveBundleImport alloc] initForDrive:drive destinationFolderURL:destination copyFiles:YES];
    [operation cancel];
    [operation start];
    XCTAssertFalse([[NSFileManager defaultManager] fileExistsAtPath:operation.preferredDestinationURL.path]);
}

@end
