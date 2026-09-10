/* 
 Copyright (c) 2013 Alun Bestor and contributors. All rights reserved.
 This source file is released under the GNU General Public License 2.0. A full copy of this license
 can be found in this XCode project at Resources/English.lproj/BoxerHelp/pages/legalese.html, or read
 online at [http://www.gnu.org/licenses/gpl-2.0.txt].
 */


#import "BXDriveBundleImport.h"
#import "BXSimpleDriveImport.h"
#import "ADBBinCueImage.h"
#import "BXDrive.h"
#import "RegexKitLite.h"
#import "NSURL+ADBFilesystemHelpers.h"
#import "NSFileManager+ADBUniqueFilenames.h"

NSString * const BXDriveBundleErrorDomain = @"BXDriveBundleErrorDomain";

@interface BXDriveBundleImport ()
@property (atomic) BOOL hasWrittenFiles;
@end

@implementation BXDriveBundleImport

@synthesize drive = _drive;
@synthesize destinationFolderURL = _destinationFolderURL;
@synthesize destinationURL = _destinationURL;


#pragma mark -
#pragma mark Helper class methods

+ (BOOL) driveUnavailableDuringImport
{
    return NO;
}

+ (NSString *) nameForDrive: (BXDrive *)drive
{
	NSString *baseName = [BXDriveImport baseNameForDrive: drive];
	NSString *importedName = [baseName stringByAppendingPathExtension: @"cdmedia"];
	
	return importedName;
}

+ (BOOL) isSuitableForDrive: (BXDrive *)drive
{
    if ([drive.sourceURL conformsToFileType: @"com.goldenhawk.cdrwin-cuesheet"])
        return YES;
    
    //If the file can be parsed as a CUE, treat it as a match too (catches renamed GOG images.)
    if ([ADBBinCueImage isCueAtURL: drive.sourceURL error: NULL])
        return YES;

	return NO;
}

#pragma mark -
#pragma mark Initialization and deallocation

- (id <BXDriveImport>) initForDrive: (BXDrive *)drive
               destinationFolderURL: (NSURL *)destinationFolderURL
						  copyFiles: (BOOL)copy;
{
	if ((self = [super init]))
	{
        self.drive = drive;
        self.destinationFolderURL = destinationFolderURL;
        self.copyFiles = copy;
	}
	return self;
}

- (NSURL *) preferredDestinationURL
{
    if (!self.drive || !self.destinationFolderURL) return nil;
    
	NSString *driveName			= [self.class nameForDrive: self.drive];
    NSURL *destinationURL       = [self.destinationFolderURL URLByAppendingPathComponent: driveName];
    
    //Check that there isn't already a file with the same name at the location.
    //If there is, auto-increment the name until we land on one that's unique.
    NSURL *uniqueDestinationURL = [[NSFileManager defaultManager] uniqueURLForURL: destinationURL
                                                                   filenameFormat: BXUniqueDriveNameFormat];
    
    return uniqueDestinationURL;
}

#pragma mark -
#pragma mark The actual operation, finally

- (void) main
{
    NSAssert(self.drive != nil, @"No drive provided for drive import operation.");
    NSAssert(self.destinationURL != nil || self.destinationFolderURL != nil, @"No destination folder provided for drive import operation.");
    
    if (!self.destinationURL)
        self.destinationURL = self.preferredDestinationURL;
    
	NSURL *sourceURL		= self.drive.mountPointURL;
	NSURL *destinationURL	= self.destinationURL;
	
	NSError *readError = nil;
	NSString *cueContents = [[NSString alloc] initWithContentsOfURL: sourceURL
                                                        usedEncoding: NULL
                                                               error: &readError];
    
	if (!cueContents)
	{
		self.error = readError;
		return;
	}
	
	NSArray *relatedPaths		= [ADBBinCueImage rawPathsInCueContents: cueContents];
	NSUInteger numRelatedPaths	= relatedPaths.count;
	
    
    //Bail out if we aren't able to parse the source files from this cue.
    if (!numRelatedPaths)
    {
        NSError *cueParseError = [BXDriveBundleCueParseError errorWithDrive: self.drive];
        [self setError: cueParseError];
        return;
    }
    
	if (self.isCancelled) return;
    
    NSArray *resourceURLs = [ADBBinCueImage validatedResourceURLsInCueAtURL: sourceURL error: &readError];
    if (!resourceURLs)
    {
        self.error = readError;
        return;
    }

    //Work out what to do with the related file paths we've parsed from the cue file.
    //Safe relative layouts remain intact; external/absolute paths are relocated under
    //a controlled subdirectory and all collisions are resolved deterministically.
    NSMutableArray *revisedPaths = [NSMutableArray arrayWithCapacity: numRelatedPaths];
    NSMutableDictionary *destinationsBySource = [NSMutableDictionary dictionaryWithCapacity: numRelatedPaths];
    NSMutableSet *claimedDestinationPaths = [NSMutableSet setWithCapacity: numRelatedPaths];
    
    for (NSUInteger index = 0; index < numRelatedPaths; index++)
    {
        NSString *fromPath = [relatedPaths objectAtIndex: index];
        NSURL *fromURL = [resourceURLs objectAtIndex: index];
        NSString *sanitisedFromPath = [fromPath stringByReplacingOccurrencesOfString: @"\\" withString: @"/"];
        BOOL isWindowsAbsolutePath = [sanitisedFromPath rangeOfString: @"^[A-Za-z]:/"
                                                               options: NSRegularExpressionSearch].location != NSNotFound;
        BOOL safeRelativePath = !sanitisedFromPath.isAbsolutePath && !isWindowsAbsolutePath &&
                                ![sanitisedFromPath.pathComponents containsObject: @".."];
        NSString *relativeDestinationPath = safeRelativePath ? sanitisedFromPath :
                                            [@"External Tracks" stringByAppendingPathComponent: fromURL.lastPathComponent];
        relativeDestinationPath = relativeDestinationPath.stringByStandardizingPath;

        NSString *sourceKey = fromURL.URLByStandardizingPath.path;
        NSString *existingDestination = [destinationsBySource objectForKey: sourceKey];
        if (existingDestination)
        {
            [revisedPaths addObject: existingDestination];
            continue;
        }

        NSString *candidate = relativeDestinationPath;
        NSString *candidateKey = candidate.lowercaseString;
        NSUInteger suffix = 2;
        while ([claimedDestinationPaths containsObject: candidateKey])
        {
            NSString *extension = relativeDestinationPath.pathExtension;
            NSString *stem = relativeDestinationPath.stringByDeletingPathExtension;
            candidate = [NSString stringWithFormat: @"%@ (%lu)%@%@", stem, (unsigned long)suffix,
                         extension.length ? @"." : @"", extension];
            candidateKey = candidate.lowercaseString;
            suffix++;
        }
        [claimedDestinationPaths addObject: candidateKey];
        [destinationsBySource setObject: candidate forKey: sourceKey];
        [revisedPaths addObject: candidate];
        NSURL *toURL = [destinationURL URLByAppendingPathComponent: candidate];
        [self addTransferFromPath: fromURL.path toPath: toURL.path];
    }
    
    if (self.isCancelled) return;
    
    //Perform the standard file import from here on in.
    self.hasWrittenFiles = NO;
    [super main];
    self.hasWrittenFiles = YES;
    
    if (!self.error)
    {
        //Once the transfer's finished, rewrite only the parsed FILE operands.
        NSString *revisedCue = [ADBBinCueImage cueContents: cueContents
                           byReplacingReferencedPathsWith: revisedPaths
                                                    error: &readError];
        if (!revisedCue)
        {
            self.error = readError;
            [self undoTransfer];
            return;
        }
        
        NSURL *finalCueURL = [destinationURL URLByAppendingPathComponent: @"tracks.cue"];
        
        NSError *cueError = nil;
        BOOL cueWritten = [revisedCue writeToURL: finalCueURL
                                      atomically: YES
                                        encoding: NSUTF8StringEncoding
                                           error: &cueError];
        
        if (!cueWritten)
        {
            self.error = cueError;
        }
        else if (!self.copyFiles)
        {
            //If we were moving rather than copying, then delete the original
            //cue file once we've written the new one
            [[NSFileManager defaultManager] removeItemAtURL: sourceURL error: NULL];
        }
    }
    
    //If the import failed for any reason (including cancellation),
    //then clean up the partial files.
    if (self.error || self.isCancelled)
        [self undoTransfer];
}


- (BOOL) undoTransfer
{
	BOOL undid = [super undoTransfer];
	if (self.copyFiles && self.destinationURL && (self.hasWrittenFiles || self.isCancelled))
	{
		undid = [[NSFileManager defaultManager] removeItemAtURL: self.destinationURL error: NULL];
	}
	return undid;
}
@end


@implementation BXDriveBundleCueParseError

+ (id) errorWithDrive: (BXDrive *)drive
{
	NSString *displayName = drive.title;
	NSString *descriptionFormat = NSLocalizedString(@"The image “%1$@” could not be imported because Boxer was unable to determine its source files.",
													@"Error shown when drive bundle importing fails because the CUE file could not be parsed. %1$@ is the display title of the drive.");
	
	NSString *description	= [NSString stringWithFormat: descriptionFormat, displayName];
	NSString *suggestion	= NSLocalizedString(@"This image may be in a format that Boxer does not support.", @"Explanatory message shown when drive bundle importing fails because the CUE file could not be parsed.");
	
	NSDictionary *userInfo	= [NSDictionary dictionaryWithObjectsAndKeys:
							   description,		NSLocalizedDescriptionKey,
							   suggestion,		NSLocalizedRecoverySuggestionErrorKey,
							   drive.sourceURL, NSURLErrorKey,
							   nil];
	
	return [NSError errorWithDomain: BXDriveBundleErrorDomain
                               code: BXDriveBundleCouldNotParseCue
                           userInfo: userInfo];
}
@end
