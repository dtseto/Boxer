/* 
 Copyright (c) 2013 Alun Bestor and contributors. All rights reserved.
 This source file is released under the GNU General Public License 2.0. A full copy of this license
 can be found in this XCode project at Resources/English.lproj/BoxerHelp/pages/legalese.html, or read
 online at [http://www.gnu.org/licenses/gpl-2.0.txt].
 */

#import "BXEmulatorPrivate.h"
#import "BXEmulatorCore.h"

#import "BXDrive.h"
#import "NSString+ADBPaths.h"
#import "RegexKitLite.h"
#import "ADBFilesystem.h"
#import "NSURL+ADBFilesystemHelpers.h"

#import "dos_inc.h"
#import "dos_system.h"
#import "drives.h"
#import "cdrom.h"
#import "mem.h"

#include <array>
#include <vector>


#pragma mark - Private constants

NSString * const BXDOSBoxUnmountErrorDomain  = @"BXDOSBoxUnmountErrorDomain";
NSString * const BXDOSBoxMountErrorDomain    = @"BXDOSBoxMountErrorDomain";

NSString * const BXEmulatorDriveDidMountNotification    = @"BXEmulatorDriveDidMountNotification";
NSString * const BXEmulatorDriveDidUnmountNotification  = @"BXEmulatorDriveDidUnmountNotification";
NSString * const BXEmulatorDidCreateFileNotification    = @"BXEmulatorDidCreateFileNotification";
NSString * const BXEmulatorDidRemoveFileNotification    = @"BXEmulatorDidRemoveFileNotification";



//Drive geometry constants passed to BXEmulatorCore drive-construction methods.
BXDriveGeometry BXHardDiskGeometry		= {512, 127, 16383, 4031};	//~1GB, ~250MB free space
BXDriveGeometry BXFloppyDiskGeometry	= {512, 1, 2880, 2880};		//1.44MB, 1.44MB free space
BXDriveGeometry BXCDROMGeometry			= {2048, 1, 65535, 0};		//~650MB, no free space


#pragma mark - Externs

//Defined in dos_mscdex.cpp
void MSCDEX_SetCDInterface(int intNr, int forceCD);



#pragma mark - BXEmulator (BXDOSFileSystem)

@implementation BXEmulator (BXDOSFileSystem)

//Todo: this could be done much more efficiently
+ (NSArray *) driveLetters
{
	static NSArray *letters = nil;
	if (!letters) letters = [[NSArray alloc] initWithObjects:
		@"A", @"B", @"C", @"D", @"E", @"F", @"G", @"H", @"I",
		@"J", @"K", @"L", @"M", @"N", @"O", @"P", @"Q", @"R",
		@"S", @"T", @"U", @"V", @"W", @"X", @"Y", @"Z", nil];
	
	return letters;
}
+ (NSArray *) floppyDriveLetters
{
	static NSArray *letters = nil;
	if (!letters) letters = [[self driveLetters] subarrayWithRange: NSMakeRange(0, 24)];
	return letters;
}
+ (NSArray *) hardDriveLetters
{
	static NSArray *letters = nil;
	if (!letters) letters = [[self driveLetters] subarrayWithRange: NSMakeRange(2, 22)];
	return letters;
}
+ (NSArray *) CDROMDriveLetters
{
	static NSArray *letters = nil;
	if (!letters) letters = [[self driveLetters] subarrayWithRange: NSMakeRange(3, 22)];
	return letters;	
}

+ (BXDrive *) driveFromMountCommand: (NSString *)mountCommand
                      relativeToURL: (NSURL *)baseURL
                              error: (NSError **)outError
{
    NSString *basePattern = @"(?:mount\\s+|imgmount\\s+)(?# Optional command name )?([a-z])(?# Drive letter )\\s+(\"(?:\\\\?+.)*?\"(?# Double-quoted path, respecting escaped quotes )|\\S+(?# Unquoted path with no spaces ))(.*)(?# Additional mount parameters )";
    
    NSArray *matches = [mountCommand captureComponentsMatchedByRegex: basePattern
                                                             options: RKLCaseless
                                                               range: NSMakeRange(0, [mountCommand length])
                                                               error: outError];
    
    //This would indicate a parse error
    if (matches.count != 4) return nil;
    
    NSString *letter    = [matches objectAtIndex: 1];
    NSString *path      = [matches objectAtIndex: 2];
    NSString *params    = [matches objectAtIndex: 3];
    
    //First clean up the path and resolve it into a proper URL.
    
    //Trim surrounding quotes from the path, standardize slashes and escaped quotes.
    path = [path stringByTrimmingCharactersInSet: [NSCharacterSet characterSetWithCharactersInString: @"\""]];
    path = [path stringByReplacingOccurrencesOfString: @"\\\"" withString: @"\""];
    path = [path stringByReplacingOccurrencesOfString: @"\\" withString: @"/"];
    
    NSURL *driveURL;
    if (baseURL && !path.isAbsolutePath)
        driveURL = [baseURL URLByAppendingPathComponent: path];
    else
        driveURL = [NSURL fileURLWithPath: path];
    
    //--Now parse the parameters
    
    //Trim extra whitespace from additional parameters.
    params = [params stringByTrimmingCharactersInSet: [NSCharacterSet whitespaceCharacterSet]];
    
    BXDriveType type = BXDriveAutodetect;
    NSString *label = nil;
    if (params.length)
    {
        //Determine the desired drive type from the -t parameter, if present.
        NSString *typePattern = @"-t\\s(cdrom|iso|floppy|hdd|dir)";
        NSString *typeParam = [params componentsMatchedByRegex: typePattern
                                                       options: RKLCaseless
                                                         range: NSMakeRange(0, params.length)
                                                       capture: 1
                                                         error: outError].lastObject;
        
        if (typeParam)
        {
            typeParam = typeParam.lowercaseString;
            if ([typeParam isEqualToString: @"cdrom"] || [typeParam isEqualToString: @"iso"])
                type = BXDriveCDROM;
            else if ([typeParam isEqualToString: @"floppy"])
                type = BXDriveFloppyDisk;
            else if ([typeParam isEqualToString: @"hdd"] || [typeParam isEqualToString: @"dir"])
                type = BXDriveHardDisk;
        }
        
        //Determine any custom label for the game from the -label parameter, if present.
        
        //Matches -label VOLUMELABEL, -label "VOLUMELABEL", -label 'VOLUMELABEL',
        //though it's possible that DOSBox itself doesn't accept the latter two forms
        NSString *labelPattern = @"-label\\s(?:\"(.+)\"|'(.+)'|(\\S+))";
        label = [params componentsMatchedByRegex: labelPattern
                                         options: RKLCaseless
                                           range: NSMakeRange(0, params.length)
                                         capture: 1
                                           error: outError].lastObject;
    }
    
    BXDrive *drive = [BXDrive driveWithContentsOfURL: driveURL
                                              letter: letter
                                                type: type];
    
    if (label.length)
        drive.volumeLabel = label;
    
    return drive;
}


#pragma mark -
#pragma mark Drive mounting and unmounting

- (BXDrive *) mountDrive: (BXDrive *)drive error: (NSError **)outError
{
    //This is not permitted and indicates a programming error
    NSAssert(self.isExecuting, @"mountDrive:error: called while emulator is not running.");
    
	NSURL *mountURL = drive.mountPointURL;
	
	//File does not exist or cannot be read, don't continue mounting
	if (![mountURL checkResourceIsReachableAndReturnError: NULL])
    {
        if (outError) *outError = [BXEmulatorCouldNotReadDriveError errorWithDrive: drive];
        return nil;
    }
	
    NSNumber *isDirFlag;
    BOOL checkedDir = [mountURL getResourceValue: &isDirFlag forKey: NSURLIsDirectoryKey error: NULL];
	BOOL isDir = checkedDir && isDirFlag.boolValue;
	BOOL isImage = !isDir;

	NSString *driveLetter = drive.letter;
	NSString *driveLabel = drive.volumeLabel;
	
	//Choose an appropriate drive letter to mount the drive at,
	//if one hasn't been specified.
	if (!driveLetter)
        driveLetter = [self preferredLetterForDrive: drive];
	
	//If no drive letters were available, do not continue.
	if (driveLetter == nil)
    {
        if (outError) *outError = [BXEmulatorOutOfDriveLettersError errorWithDrive: drive];
        return nil;
    }
    //Don't continue if there's already a drive at this letter either.
    else if ([self driveAtLetter: driveLetter] != nil)
    {
        if (outError) *outError = [BXEmulatorDriveLetterOccupiedError errorWithDrive: drive];
        return nil;
    }
    
    //If we got this far, then we're ready to let DOSBox have a crack at the drive.
    
    //Record that we're currently mounting this drive, in case any of our drive lookups are called before
    //we finish putting the drive in place.
	_driveBeingMounted = drive;
	
	uintptr_t DOSBoxDrive = 0;
	NSUInteger index = [self _indexOfDriveLetter: driveLetter];
    
    
    NSString *mountPath = mountURL.path;
    //Ensure that folder paths have a trailing slash, otherwise DOSBox will get shirty
	if (isDir && ![mountPath hasSuffix: @"/"])
        mountPath = [mountPath stringByAppendingString: @"/"];
	
    NSError *mountError = nil;
    int32_t mountErrorCode = BXDOSBoxMountUnknownError;
    const uint16_t cdromGeometry[] = { (uint16_t)BXCDROMGeometry.bytesPerSector,
                                       (uint16_t)BXCDROMGeometry.sectorsPerCluster,
                                       (uint16_t)BXCDROMGeometry.numClusters,
                                       (uint16_t)BXCDROMGeometry.freeClusters };
    const uint16_t hardDiskGeometry[] = { (uint16_t)BXHardDiskGeometry.bytesPerSector,
                                          (uint16_t)BXHardDiskGeometry.sectorsPerCluster,
                                          (uint16_t)BXHardDiskGeometry.numClusters,
                                          (uint16_t)BXHardDiskGeometry.freeClusters };
    const uint16_t floppyGeometry[] = { (uint16_t)BXFloppyDiskGeometry.bytesPerSector,
                                         (uint16_t)BXFloppyDiskGeometry.sectorsPerCluster,
                                         (uint16_t)BXFloppyDiskGeometry.numClusters,
                                         (uint16_t)BXFloppyDiskGeometry.freeClusters };
    const char *cMountPath = [mountPath fileSystemRepresentation];
    if (isImage)
    {
        switch (drive.type)
        {
            case BXDriveCDROM:
                DOSBoxDrive = [BXEmulatorCore createDOSBoxCDROMImage:cMountPath
                                                           driveIndex:index
                                                            mediaByte:BXCDROMMediaID
                                                            errorCode:&mountErrorCode];
                break;
            case BXDriveHardDisk:
                mountErrorCode = BXDOSBoxMountInvalidImageFormat;
                break;
            case BXDriveFloppyDisk:
                DOSBoxDrive = [BXEmulatorCore createDOSBoxFloppyImage:cMountPath
                                                              errorCode:&mountErrorCode];
                break;
                
            default:
                NSAssert1(NO, @"Drive type cannot be mounted: %li", (long)drive.type);
        }
    }
    else
    {
        switch (drive.type)
        {
            case BXDriveCDROM:
                DOSBoxDrive = [BXEmulatorCore createDOSBoxCDROMDirectory:cMountPath
                                                               driveIndex:index
                                                                useAudio:drive.usesCDAudio
                                                                geometry:cdromGeometry
                                                                mediaByte:BXCDROMMediaID
                                                                errorCode:&mountErrorCode];
                break;
                
            case BXDriveHardDisk:
            if (drive.shadowURL) {
                NSNumber *isDirFlag;
                NSURL *shadowURL = drive.shadowURL;
                BOOL checkedDir = [shadowURL getResourceValue: &isDirFlag forKey: NSURLIsDirectoryKey error: NULL];
                BOOL isDir = checkedDir && isDirFlag.boolValue;
                NSString *shadowPath = shadowURL.path;
                //Ensure that folder paths have a trailing slash, otherwise DOSBox will get shirty
                if (isDir && ![shadowPath hasSuffix: @"/"])
                    shadowPath = [shadowPath stringByAppendingString: @"/"];

                DOSBoxDrive = [BXEmulatorCore createDOSBoxLocalDirectory:cMountPath
                                                               shadowPath:[shadowPath fileSystemRepresentation]
                                                                freeSpace:drive.freeSpace
                                                                 geometry:hardDiskGeometry
                                                                 mediaByte:BXHardDiskMediaID
                                                                errorCode:&mountErrorCode];
            } else {
                DOSBoxDrive = [BXEmulatorCore createDOSBoxLocalDirectory:cMountPath
                                                               shadowPath:NULL
                                                                freeSpace:drive.freeSpace
                                                                 geometry:hardDiskGeometry
                                                                 mediaByte:BXHardDiskMediaID
                                                                errorCode:&mountErrorCode];
            }
                break;
                
            case BXDriveFloppyDisk:
                DOSBoxDrive = [BXEmulatorCore createDOSBoxFloppyDirectory:cMountPath
                                                                  freeSpace:drive.freeSpace
                                                                   geometry:floppyGeometry
                                                                   mediaByte:BXFloppyMediaID
                                                                  errorCode:&mountErrorCode];
                break;
                
            default:
                NSAssert1(NO, @"Drive type cannot be mounted: %li", (long)drive.type);
        }
    }

    if (!DOSBoxDrive && !mountError)
        mountError = [NSError errorWithDomain:BXDOSBoxMountErrorDomain
                                          code:mountErrorCode
                                      userInfo:@{NSFilePathErrorKey: mountPath}];
    
	//DOSBox successfully created the drive object
	if (DOSBoxDrive)
	{
		//Now add the drive to DOSBox's own drive list
			uint8_t mediaByte = (drive.type == BXDriveFloppyDisk) ? BXFloppyMediaID : BXHardDiskMediaID;
			if ([self _addDOSBoxDrive: DOSBoxDrive atIndex: index mediaByte: mediaByte])
			{
			//And set its label appropriately (unless its an image, which carry their own labels)
			if (!isImage && driveLabel)
			{
				const char *cLabel = [driveLabel cStringUsingEncoding: BXDirectStringEncoding];
                if (cLabel) {
					[BXEmulatorCore setDOSBoxDrive:(uintptr_t)DOSBoxDrive label:cLabel isCDROM:drive.isCDROM];
                }
			}
			
			//Populate the drive with the settings we ended up using, and add the drive to our own drives cache
            drive.letter = driveLetter;
            drive.DOSVolumeLabel = [NSString stringWithCString: [BXEmulatorCore DOSBoxDriveLabel:(uintptr_t)DOSBoxDrive]
                                                      encoding: BXDirectStringEncoding];
            
			[self _addDriveToCache: drive];
			
			//Post a notification to whoever's listening
			[self _postNotificationName: BXEmulatorDriveDidMountNotification
					   delegateSelector: @selector(emulatorDidMountDrive:)
							   userInfo: @{ @"drive": drive }];
			
            _driveBeingMounted = nil;
			return drive;
		}
		else
		{
            //The only reason this can fail currently is if another drive has been inserted at the same letter.
            //We check for this and fail earlier, but this could possibly still happen if there's a race condition.
            //TODO: let _addDOSBoxDrive:atIndex: populate an error.
            if (outError) *outError = [BXEmulatorDriveLetterOccupiedError errorWithDrive: drive];
            
					[BXEmulatorCore destroyDOSBoxDrive:(uintptr_t)DOSBoxDrive];
            
            _driveBeingMounted = nil;
            
			return nil;
		}
	}
	else
    {
        //Figure out what went wrong, and transform it into a more presentable error type.
        if (outError)
        {
            if ([mountError.domain isEqualToString: BXDOSBoxMountErrorDomain])
            {
                switch (mountError.code)
                {
                    case BXDOSBoxMountNonContiguousCDROMDrives:
                        *outError = [BXEmulatorNonContiguousDrivesError errorWithDrive: drive];
                        break;
                    case BXDOSBoxMountCouldNotReadSource:
                        *outError = [BXEmulatorCouldNotReadDriveError errorWithDrive: drive];
                        break;
                    case BXDOSBoxMountTooManyCDROMDrives:
                        *outError = [BXEmulatorOutOfCDROMDrivesError errorWithDrive: drive];
                        break;
                    case BXDOSBoxMountInvalidImageFormat:
                        *outError = [BXEmulatorInvalidImageError errorWithDrive: drive];
                        break;
                    default:
                        *outError = mountError;
                }
            }
            else *outError = mountError;
        }
        
        _driveBeingMounted = nil;
        return nil;
    }
}

- (BOOL) unmountDrive: (BXDrive *)drive
                force: (BOOL)force
                error: (NSError **)outError
{
    //This is not permitted and indicates a programming error
    NSAssert(self.isExecuting, @"unmountDrive:error: called while emulator is not running.");
    
    //If the drive isn't mounted to start with, bail out already.
    //TODO: make this an error?
    if (![self driveIsMounted: drive])
        return YES;
    
	if (drive.isVirtual || drive.isLocked)
    {
        if (outError) *outError = [BXEmulatorDriveLockedError errorWithDrive: drive];
        return NO;
    }
    
    //If the drive is a hard disk and is in use, prevent it being ejected
    if (!force && [self driveInUse: drive])
    {
        if (outError) *outError = [BXEmulatorDriveInUseError errorWithDrive: drive];
        return NO;
    }
	
	NSUInteger index	= [self _indexOfDriveLetter: drive.letter];
	BOOL isCurrentDrive = (index == [BXEmulatorCore DOSBoxDefaultDriveIndex]);

    NSError *unmountError = nil;
	BOOL unmounted = [self _unmountDOSBoxDriveAtIndex: index
                                                error: &unmountError];
	
	if (unmounted)
	{
		//If this was the drive we were on, recover by switching to Z drive
		if (isCurrentDrive && self.isAtPrompt)
            [self changeToDriveLetter: @"Z"];
		
		//Remove the drive from our drive cache
		[self _removeDriveFromCache: drive];
		
		//Post a notification to whoever's listening
		[self _postNotificationName: BXEmulatorDriveDidUnmountNotification
				   delegateSelector: @selector(emulatorDidUnmountDrive:)
						   userInfo: @{ @"drive": drive }];
	}
    else if (outError)
    {   
        //Transform DOSBox's error codes into our own
        if ([unmountError.domain isEqualToString: BXDOSBoxUnmountErrorDomain])
        {
            switch (unmountError.code)
            {
                case BXDOSBoxUnmountLockedDrive:
                    *outError = [BXEmulatorDriveLockedError errorWithDrive: drive];
                    break;
                case BXDOSBoxUnmountNonContiguousCDROMDrives:
                    *outError = [BXEmulatorNonContiguousDrivesError errorWithDrive: drive];
                    break;
                default:
                    *outError = unmountError;
            }
        }
        else *outError = unmountError;
    }
	return unmounted;
}

- (BOOL) releaseResourcesForDrive: (BXDrive *)drive error: (NSError **)outError
{
    if ([self driveIsMounted: drive])
    {
        NSUInteger driveIndex = [self _indexOfDriveLetter: drive.letter];
        [self _closeFilesForDOSBoxDriveAtIndex: driveIndex];
        
        //TODO: hook into ISO file handling to close file handles for image-backed drives.
    }
    return YES;
}

- (void) refreshMountedDrives
{
	if (self.isExecuting)
	{
		for (NSUInteger i=0; i < [BXEmulatorCore DOSBoxDriveCount]; i++)
		{
			uintptr_t drive = [BXEmulatorCore DOSBoxDriveAtIndex:i];
			if (drive) [BXEmulatorCore emptyDOSBoxDriveCache:drive];
		}
	}
}

- (NSString *) preferredLetterForDrive: (BXDrive *)drive
{
	NSSet *usedLetters = [NSSet setWithArray: _driveCache.allKeys];
	
	//TODO: try to ensure CD-ROM mounts are contiguous
	NSArray *letters;
	if (drive.isFloppy)         letters = [self.class floppyDriveLetters];
	else if (drive.isCDROM)     letters = [self.class CDROMDriveLetters];
	else						letters = [self.class hardDriveLetters];

	//Scan for the first available drive letter that isn't already mounted
	for (NSString *letter in letters)
    {
        if (![usedLetters containsObject: letter]) return letter;
    }
    
	//Looks like all possible drive letters are mounted! bummer
	return nil;
}


#pragma mark - Drive and filesystem introspection

- (NSArray *) mountedDrives
{
	return _driveCache.allValues;
}

- (BOOL) driveIsMounted: (BXDrive *)drive
{
    return ([drive isEqual: [self driveAtLetter: drive.letter]]);
}

- (BOOL) driveInUse: (BXDrive *)drive
{
    if ([self driveIsMounted: drive])
        return [self driveInUseAtLetter: drive.letter];
    else
        return NO;
}

- (BXDrive *) driveAtLetter: (NSString *)driveLetter
{
	return [_driveCache objectForKey: driveLetter];
}

- (BOOL) driveInUseAtLetter: (NSString *)driveLetter
{
    //First check if any of our active processes live on that drive.
    for (NSDictionary *processInfo in self.runningProcesses)
    {
        NSString *dosPath = [processInfo objectForKey: BXEmulatorDOSPathKey];
		NSString *processDriveLetter = [dosPath substringToIndex: 1];
		if ([driveLetter isEqualToString: processDriveLetter]) return YES;
    }
    
    //If that check passes, now check if any files are still open on that drive.
	return [self _DOSBoxDriveInUseAtIndex: [self _indexOfDriveLetter: driveLetter]];
}

- (BOOL) DOSPathExists: (NSString *)dosPath
{
	dosPath = [dosPath stringByReplacingOccurrencesOfString: @"/" withString: @"\\"];
	NSUInteger driveIndex = [BXEmulatorCore DOSBoxDefaultDriveIndex];
    
    //If the path starts with a drive letter, pop it off
	if (dosPath.length >= 2 && [dosPath characterAtIndex: 1] == (unichar)':')
	{
		NSString *driveLetter = [dosPath substringToIndex: 1];
		//Snip off the drive letter from the front of the path
		dosPath = [dosPath substringFromIndex: 2];
		
		driveIndex = [self _indexOfDriveLetter: driveLetter];
	}

	uintptr_t dosDrive = [BXEmulatorCore DOSBoxDriveAtIndex:driveIndex];
	if (!dosDrive) return NO;
    
    //If the path was empty (e.g. nothing more than a drive letter)
    //then it represents the current or root path, so yes it exists
    if (!dosPath.length) return YES;
	
    //Otherwise, ask the drive itself
    const char *cPath = [dosPath cStringUsingEncoding: BXDirectStringEncoding];
    
	return [BXEmulatorCore DOSBoxDrive:dosDrive fileExists:cPath] ||
	       [BXEmulatorCore DOSBoxDrive:dosDrive testDirectory:cPath];
}

- (BXDrive *) currentDrive
{
    return [_driveCache objectForKey: self.currentDriveLetter];
}

- (NSString *) currentDriveLetter
{
	if (self.isExecuting)
	{
		return [[self.class driveLetters] objectAtIndex: [BXEmulatorCore DOSBoxDefaultDriveIndex]];
	}
	else return nil;
}

- (NSString *) currentDirectory
{
	if (self.isExecuting)
	{
		uintptr_t currentDOSBoxDrive = [BXEmulatorCore DOSBoxDriveAtIndex:[BXEmulatorCore DOSBoxDefaultDriveIndex]];
        const char *currentDir = [BXEmulatorCore DOSBoxDriveCurrentDirectory:currentDOSBoxDrive];
		return [NSString stringWithCString: currentDir
                                  encoding: BXDirectStringEncoding];
	}
	else return nil;
}

- (BXDrive *) driveForDOSPath: (NSString *)path
{
    if (self.isExecuting)
	{
		const char *dosPath = [path cStringUsingEncoding: BXDirectStringEncoding];
		//If the path couldn't be encoded successfully, don't do further lookups
		if (!dosPath) return nil;
		
		NSUInteger pathLength = [BXEmulatorCore maximumDOSBoxPathLength];
		if (!pathLength) return nil;
		std::vector<char> fullPath(pathLength);
		uint8_t driveIndex;
		BOOL resolved = [BXEmulatorCore makeDOSBoxPath:dosPath into:fullPath.data()
		                                      capacity:fullPath.size()
		                                   driveIndex:&driveIndex];
                
		if (resolved)
		{
			return [self _driveFromDOSBoxDriveAtIndex:driveIndex];
		}
		else return nil;
	}
	else return nil;
}

- (NSString *) resolvedDOSPath: (NSString *)path
{
    if (self.isExecuting)
	{
		const char *dosPath = [path cStringUsingEncoding: BXDirectStringEncoding];
		//If the path couldn't be encoded successfully, don't do further lookups
		if (!dosPath) return nil;
		
		NSUInteger pathLength = [BXEmulatorCore maximumDOSBoxPathLength];
		if (!pathLength) return nil;
		std::vector<char> fullPath(pathLength);
		uint8_t driveIndex;
		BOOL resolved = [BXEmulatorCore makeDOSBoxPath:dosPath into:fullPath.data()
		                                      capacity:fullPath.size()
		                                   driveIndex:&driveIndex];
        
		if (resolved)
		{
            NSString *driveLetter = [self _driveLetterForIndex: driveIndex];
			NSString *resolvedPath = [NSString stringWithCString: fullPath.data() encoding: BXDirectStringEncoding];
            
            return [NSString stringWithFormat: @"%@:\\%@", driveLetter, resolvedPath];
		}
		else return nil;
	}
	else return nil;
}

#pragma mark Resolving paths to OS X resources

+ (NSSet *) keyPathsForValuesAffectingCurrentDirectoryURL { return [NSSet setWithObject: @"currentDirectory"]; }

- (NSURL *) currentDirectoryURL
{
	if (self.isExecuting)
	{
		uintptr_t currentDOSBoxDrive = [BXEmulatorCore DOSBoxDriveAtIndex:[BXEmulatorCore DOSBoxDefaultDriveIndex]];
		const char *currentDir = [BXEmulatorCore DOSBoxDriveCurrentDirectory:currentDOSBoxDrive];
		
		NSURL *localURL	= [self _filesystemURLForDOSPath: currentDir
											   onDOSBoxDrive: currentDOSBoxDrive];
		
        if (localURL)
        {
            return localURL;
        }
		//If no accurate local path could be determined (e.g. for disk image-based drives)
        //fall back on the root of the drive
		else
        {
            return self.currentDrive.sourceURL;
        }
	}
	else return nil;
}

- (NSURL *) fileURLForDOSPath: (NSString *)dosPath
{
	if (self.isExecuting)
	{
		const char *dosCPath = [dosPath cStringUsingEncoding: BXDirectStringEncoding];
		//If the path couldn't be encoded successfully, don't do further lookups
		if (!dosCPath)
            return nil;
		
		NSUInteger pathLength = [BXEmulatorCore maximumDOSBoxPathLength];
		if (!pathLength) return nil;
		std::vector<char> fullPath(pathLength);
		uint8_t driveIndex;
		BOOL resolved = [BXEmulatorCore makeDOSBoxPath:dosCPath into:fullPath.data()
		                                      capacity:fullPath.size()
		                                   driveIndex:&driveIndex];
        
		if (resolved)
		{
			uintptr_t dosboxDrive = [BXEmulatorCore DOSBoxDriveAtIndex:driveIndex];
			NSURL *localURL	= [self _filesystemURLForDOSPath: fullPath.data() onDOSBoxDrive: dosboxDrive];
			
			if (localURL)
            {
                return localURL;
            }
			else
			{
				BXDrive *drive = [self _driveFromDOSBoxDriveAtIndex:driveIndex];
				return drive.sourceURL;
			}
		}
		else return nil;
	}
	else return nil;
}

- (NSURL *) logicalURLForDOSPath: (NSString *)dosPath
{
	if (self.isExecuting)
	{
        const char *dosCPath = [dosPath cStringUsingEncoding: BXDirectStringEncoding];
		//If the path couldn't be encoded successfully, don't do further lookups
		if (!dosCPath)
            return nil;
		
        //First resolve what could be a relative path to an absolute one and determine which drive it's located on.
		NSUInteger pathLength = [BXEmulatorCore maximumDOSBoxPathLength];
		if (!pathLength) return nil;
		std::vector<char> fullCPath(pathLength);
		uint8_t driveIndex;
		BOOL resolved = [BXEmulatorCore makeDOSBoxPath:dosCPath into:fullCPath.data()
		                                      capacity:fullCPath.size()
		                                   driveIndex:&driveIndex];
        
        //Then, ask the Boxer drive itself to hand over a logical URL that will correspond to that resource.
		if (resolved)
		{
            BXDrive *drive = [self _driveFromDOSBoxDriveAtIndex: driveIndex];
			NSString *fullPath = [NSString stringWithCString: fullCPath.data() encoding: BXDirectStringEncoding];
            return [drive logicalURLForDOSPath: fullPath];
		}
		else return nil;
    }
    else return nil;
}

- (BOOL) logicalURLIsMountedInDOS: (NSURL *)URL
{
	for (BXDrive *drive in _driveCache.objectEnumerator)
	{
		if ([drive representsLogicalURL: URL])
            return YES;
	}
	return NO;
}

- (BXDrive *) driveContainingLogicalURL: (NSURL *)URL
{
	//Sort the drives by path depth, so that deeper mounts are picked over 'shallower' ones.
	//e.g. when MyGame.boxer and MyGame.boxer/MyCD.cdrom are both mounted, it should pick the latter.
	//Todo: filter this down to matching drives first, then do the sort, which would be quicker.
	NSArray *sortedDrives = [_driveCache.allValues sortedArrayUsingSelector: @selector(sourceDepthCompare:)];
	
	for (BXDrive *drive in sortedDrives.reverseObjectEnumerator)
	{
		if ([drive exposesLogicalURL: URL])
            return drive;
	}
	return nil;
}

- (BOOL) logicalURLIsAccessibleInDOS: (NSURL *)URL
{
	for (BXDrive *drive in _driveCache.objectEnumerator)
	{
		if ([drive exposesLogicalURL: URL])
            return YES;
	}
	return NO;
}

- (NSString *) DOSPathForLogicalURL: (NSURL *)URL
{
	BXDrive *drive = [self driveContainingLogicalURL: URL];
    
	if (drive)
        return [self DOSPathForLogicalURL: URL onDrive: drive];
	else
        return nil;
}

- (NSString *) DOSPathForLogicalURL: (NSURL *)URL onDrive: (BXDrive *)drive
{
	if (!self.isExecuting) return nil;
	
	NSUInteger driveIndex	= [self _indexOfDriveLetter: drive.letter];
	uintptr_t DOSBoxDrive = [BXEmulatorCore DOSBoxDriveAtIndex:driveIndex];
    //The drive is not mounted in DOS: give up
	if (!DOSBoxDrive) return nil;
    
	NSString *subPath = [drive relativeLocationOfLogicalURL: URL];
	//The path is not accessible on this drive; give up before we go any further.
	if (!subPath) return nil;
	
	//To be sure we get this right, flush the drive cache before we look anything up.
	[BXEmulatorCore emptyDOSBoxDriveCache:DOSBoxDrive];
    
	NSMutableString *dosPath = [NSMutableString stringWithFormat: @"%@:\\", drive.letter];
	NSMutableString *frankenDirPath = [NSMutableString stringWithString: drive.mountPointURL.path];
    //Sanity check: normalize the drive's base path to strip any trailing slashes.
    if ([frankenDirPath hasSuffix: @"/"])
        [frankenDirPath deleteCharactersInRange: NSMakeRange(frankenDirPath.length - 1, 1)];
	
    //Now go through every component of the relative path, converting it from its OS X filename
    //into its DOS 8.3 equivalent.
    NSUInteger subpathsAdded = 0;
	for (NSString *fileName in subPath.pathComponents)
	@autoreleasepool {
        //We use DOSBox's own cache API to convert a real file path into its
        //corresponding DOS 8.3 name: starting at the base path of the drive,
        //and converting each component of the desired path into its DOS 8.3
        //equivalent as we go.
        
        //One peculiarity of this API is that to look up successive paths we need
        //to weld DOS 8.3 relative paths onto the drive's real filesystem path
        //to create a kind of "frankenPath", and provide this as the reference point
        //when we look up the DOS name of the next component in the path.
        
		NSString *dosName = nil;
		
		NSUInteger shortNameLength = [BXEmulatorCore maximumDOSBoxShortNameLength];
		if (!shortNameLength) return nil;
		std::vector<char> buffer(shortNameLength, 0);
		const char *cDirPath    = [frankenDirPath cStringUsingEncoding: BXDirectStringEncoding];
		const char *cFileName   = [fileName cStringUsingEncoding: BXDirectStringEncoding];
		
		BOOL hasShortName = NO;
		if (cDirPath && cFileName)
		{
            //FIXME: getShortName will always fail for ISO9660 images, which do not (cannot) track long
            //filenames but instead use the ISO filesystem's names. To correctly resolve the paths that
            //OS X sees, we would need to be able to compare ISO vs Joliet names in the image's filesystem.
			hasShortName = [BXEmulatorCore DOSBoxDrive:DOSBoxDrive
						getShortNameForDirectory:cDirPath
						name:cFileName
						intoBuffer:buffer.data()
						capacity:buffer.size()];
		}
        
		if (hasShortName)
		{
			dosName = [NSString stringWithCString: buffer.data() encoding: BXDirectStringEncoding];
		}
		else
		{
			//TODO: if filename is longer than 8.3, crop and append ~1 as a last-ditch guess.
			dosName = fileName.uppercaseString;
		}
		
        if (subpathsAdded == 0)
        {
            //If this is the first component, we don't need to prepend a separator
            //as the dos path already starts with one (i.e. "[driveletter]:\")
            [dosPath appendString: dosName];
        }
        else
        {
            //Build up the path using DOS-style path separators.
            [dosPath appendFormat: @"\\%@", dosName];
        }
        
        //IMPLEMENTATION NOTE: DOSBox's FindDirInfo (used by getShortName) requires us to format directory
        //paths using OSX-style slashes but DOS filenames: all welded onto the front of the drive's OS X-relative
        //base path.
		[frankenDirPath appendFormat: @"/%@", dosName];
		
        subpathsAdded++;
	}
	return dosPath;
}


@end


#pragma mark - Legacy API

@implementation BXEmulator (BXDOSFilesystemLegacyPathAPI)

- (BOOL) pathExistsInDOS: (NSString *)path
{
    NSString *dosPath = [self DOSPathForPath: path];
    if (!dosPath) return NO;
    
    return [self DOSPathExists: dosPath];
}

- (NSString *) DOSPathForPath: (NSString *)path
{
    return [self DOSPathForLogicalURL: [NSURL fileURLWithPath: path]];
}

- (NSString *) DOSPathForPath: (NSString *)path onDrive: (BXDrive *)drive
{
    return [self DOSPathForLogicalURL: [NSURL fileURLWithPath: path] onDrive: drive];
}

@end


#pragma mark - Private methods

@implementation BXEmulator (BXDOSFileSystemInternals)

#pragma mark -
#pragma mark Translating between Boxer and DOSBox drives

//Used internally to match DOS drive letters to the DOSBox drive array
- (NSUInteger)_indexOfDriveLetter: (NSString *)driveLetter
{
	NSUInteger index = [[self.class driveLetters] indexOfObject: driveLetter.uppercaseString];
	NSAssert1(index != NSNotFound,	@"driveLetter %@ passed to _indexOfDriveLetter: was not a valid DOS drive letter.", driveLetter);
	NSAssert2(index < [BXEmulatorCore DOSBoxDriveCount],	@"driveIndex %lu derived from %@ in _indexOfDriveLetter: was beyond the range of DOSBox's drive array.", (unsigned long)index, driveLetter);
	return index;
}

- (NSString *)_driveLetterForIndex: (NSUInteger)index
{
	NSAssert1(index < [self.class driveLetters].count,
			  @"index %lu passed to _driveLetterForIndex: was beyond the range of available drive letters.", (unsigned long)index);
	return [[self.class driveLetters] objectAtIndex: index];
}

#pragma mark -
#pragma mark Adding and removing new DOSBox drives

- (NSUInteger) _indexOfDOSBoxDriveHandle: (uintptr_t)drive
{
    for (NSUInteger i = 0; i < [BXEmulatorCore DOSBoxDriveCount]; i++)
    {
        if ([BXEmulatorCore DOSBoxDriveAtIndex:i] == drive)
            return i;
    }
    return NSNotFound;
}

//Registers a new drive with DOSBox and adds it to the drive list.
- (BOOL) _addDOSBoxDrive: (uintptr_t)drive
                 atIndex: (NSUInteger)index
               mediaByte: (uint8_t)mediaByte
{
	NSAssert1(index < [BXEmulatorCore DOSBoxDriveCount], @"index %lu passed to _addDOSBoxDrive was beyond the range of DOSBox's drive array.", (unsigned long)index);
	
	//There was already a drive at that index, bail out
	//TODO: populate an NSError object as well?
	return [BXEmulatorCore addDOSBoxDrive:(uintptr_t)drive
	                              atIndex:index
	                           mediaByte:mediaByte];
}
    
//Unmounts the DOSBox drive at the specified index and clears any references to the drive.
- (BOOL) _unmountDOSBoxDriveAtIndex: (NSUInteger)index
                              error: (NSError **)outError
{
	//The specified drive is not mounted, don't continue
    //(We don't treat this as an error situation either.)
	if (![BXEmulatorCore DOSBoxDriveAtIndex:index]) return NO;

    NSInteger result = [BXEmulatorCore unmountDOSBoxDriveAtIndex:index];
	if (result == BXDOSBoxUnmountSuccess)
	{
        [self _closeFilesForDOSBoxDriveAtIndex: index];
		return YES;
	}
	else
    {
        if (outError) *outError = [NSError errorWithDomain: BXDOSBoxUnmountErrorDomain
                                                      code: result
                                                  userInfo: nil];
        return NO;
    }
}

- (void) _closeFilesForDOSBoxDriveAtIndex: (NSUInteger)index
{
    //Force-close any files that DOSBox had open on this drive and replace
    //them with dummy file handles. This cleans up any real filesystem
    //resources (i.e. POSIX file handles) that were opened by the file, while
    //ensuring that any program that still expects its file to be open will
    //get a file that won't give them back any data.
	[BXEmulatorCore closeDOSBoxFilesForDriveAtIndex:index];
}


//Generates a BXDrive object from a DOSBox drive entry.
- (BXDrive *)_driveFromDOSBoxDriveAtIndex: (NSUInteger)index
{
	NSAssert1(index < [BXEmulatorCore DOSBoxDriveCount], @"index %lu passed to _driveFromDOSBoxDriveAtIndex was beyond the range of DOSBox's drive array.", (unsigned long)index);
    uintptr_t dosboxDrive = [BXEmulatorCore DOSBoxDriveAtIndex:index];
	if (dosboxDrive != NULL)
	{
		NSString *driveLetter	= [[self.class driveLetters] objectAtIndex: index];
        NSUInteger driveType = [BXEmulatorCore DOSBoxDriveType:dosboxDrive];
        BXDriveType type = driveType == 1 ? BXDriveVirtual :
                           (driveType == 2 ? BXDriveCDROM :
                           (driveType == 3 ? BXDriveFloppyDisk : BXDriveHardDisk));
        
        BXDrive *drive;
		if (type == BXDriveVirtual)
		{
			drive = [BXDrive virtualDriveWithLetter: driveLetter];
		}
		else
		{
            NSString *drivePath = [NSString stringWithCString: [BXEmulatorCore DOSBoxDriveSystemPath:dosboxDrive]
                                                     encoding: BXDirectStringEncoding];
            
            NSURL *driveURL, *baseURL = self.baseURL;
            if (!drivePath.isAbsolutePath && baseURL)
            {
                driveURL = [baseURL URLByAppendingPathComponent: drivePath];
            }
            else
            {
                driveURL = [NSURL fileURLWithPath: drivePath];
            }
            
			drive = [BXDrive driveWithContentsOfURL: driveURL
                                             letter: driveLetter
                                               type: type];
		}
        
		drive.DOSVolumeLabel = [NSString stringWithCString: [BXEmulatorCore DOSBoxDriveLabel:dosboxDrive]
                                                  encoding: BXDirectStringEncoding];
		
		return drive;
	}
	else return nil;
}

//Synchronizes Boxer's mounted drive cache with DOSBox's drive array,
//adding new drives and removing old drives as necessary.
- (void) _syncDriveCache
{
	for (NSUInteger i=0; i<[BXEmulatorCore DOSBoxDriveCount]; i++)
	{
		NSString *letter	= [self _driveLetterForIndex: i];
		BXDrive *drive		= [_driveCache objectForKey: letter];
		
		//A drive exists in DOSBox that we don't have a record of yet, add it to our cache
		if ([BXEmulatorCore DOSBoxDriveAtIndex:i] && !drive)
		{
			drive = [self _driveFromDOSBoxDriveAtIndex: i];
			[self _addDriveToCache: drive];
			
			//Post a notification to whoever's listening
			[self _postNotificationName: BXEmulatorDriveDidMountNotification
					   delegateSelector: @selector(emulatorDidMountDrive:)
							   userInfo: @{ @"drive": drive }];
		}
		//A drive no longer exists in DOSBox which we have a leftover record for, remove it
		else if (![BXEmulatorCore DOSBoxDriveAtIndex:i] && drive)
		{
			[self _removeDriveFromCache: drive];
			
			//Post a notification to whoever's listening
			[self _postNotificationName: BXEmulatorDriveDidUnmountNotification
					   delegateSelector: @selector(emulatorDidUnmountDrive:)
							   userInfo: @{ @"drive": drive }];
		}
	}
}

- (void) _addDriveToCache: (BXDrive *)drive
{
	[self willChangeValueForKey: @"mountedDrives"];
	[_driveCache setObject: drive forKey: drive.letter];
	[self didChangeValueForKey: @"mountedDrives"];
}

- (void) _removeDriveFromCache: (BXDrive *)drive
{
	[self willChangeValueForKey: @"mountedDrives"];
	[_driveCache removeObjectForKey: drive.letter];
	[self didChangeValueForKey: @"mountedDrives"];
}

- (void) _didCreateFileAtLocalPath: (const char *)localPath onDOSBoxDrive: (uintptr_t)dosboxDrive
{
    //TODO: make this receive DOS paths and manually resolve them to logical and filesystem URLs ourselves.
    //This way it can be deployed across all drive types.
    NSURL *fileURL = [NSURL URLFromFileSystemRepresentation: localPath];
	BXDrive *drive = [self _driveFromDOSBoxDriveAtIndex:[self _indexOfDOSBoxDriveHandle:dosboxDrive]];
    
	//Post a notification to whoever's listening
	NSDictionary *userInfo = @{
                            BXEmulatorDriveKey: drive,
                            BXEmulatorFileURLKey: fileURL,
                            BXEmulatorLogicalURLKey: fileURL,
                            };
	
	[self _postNotificationName: BXEmulatorDidCreateFileNotification
			   delegateSelector: @selector(emulatorDidCreateFile:)
					   userInfo: userInfo];	
}

- (void) _didRemoveFileAtLocalPath: (const char *)localPath onDOSBoxDrive: (uintptr_t)dosboxDrive
{
    //TODO: make this receive DOS paths and manually resolve them to logical and filesystem URLs ourselves.
    //This way it can be deployed across all drive types.
    NSURL *fileURL = [NSURL URLFromFileSystemRepresentation: localPath];
	BXDrive *drive = [self _driveFromDOSBoxDriveAtIndex:[self _indexOfDOSBoxDriveHandle:dosboxDrive]];
    
	//Post a notification to whoever's listening
	NSDictionary *userInfo = @{
                               BXEmulatorDriveKey: drive,
                               BXEmulatorFileURLKey: fileURL,
                               BXEmulatorLogicalURLKey: fileURL,
                            };
	
	[self _postNotificationName: BXEmulatorDidRemoveFileNotification
			   delegateSelector: @selector(emulatorDidRemoveFile:)
					   userInfo: userInfo];	
}


#pragma mark -
#pragma mark Filesystem validation

- (BOOL) _DOSBoxDriveInUseAtIndex: (NSUInteger)index
{
    //If we have no processes running, then any open file handles are leftovers and can be safely ignored, so don't bother checking.
    if (self.currentProcess == nil) return NO;

	int i;
	for (i=0; i<DOS_FILES; i++)
	{
		if (Files[i] && Files[i]->GetDrive() == index)
		{
			//DOS_File->GetDrive() returns 0 for the special CON system file,
			//which also corresponds to the drive index for A, so skip it
			if (index == 0 && !strcmp(Files[i]->GetName(), "CON")) continue;
			
			if (Files[i]->IsOpen()) return YES;
		}
	}
	return NO;
}

//If the folder was restricted, print an error to the shell and deny access
//Todo: this assumes that the check is being called from the shell;
//we should instead populate an NSError with the error details and let the upstream context handle it
- (BOOL) _shouldMountLocalPath: (const char *)localPath
{
    NSURL *fileURL = [NSURL URLFromFileSystemRepresentation: localPath];
	return [self.delegate emulator: self shouldMountDriveFromURL: fileURL];
}

//TODO: supplement this by getting entire OS X filepaths out of DOSBox, instead of just filenames
- (BOOL) _shouldShowFileWithName: (NSString *)fileName
{
    return [self.delegate emulator: self shouldShowFileWithName: fileName];
}

- (BOOL) _shouldAllowWriteAccessToLocalPath: (const char *)localPath onDOSBoxDrive: (uintptr_t)dosboxDrive
{
	BXDrive *drive = [self _driveFromDOSBoxDriveAtIndex:[self _indexOfDOSBoxDriveHandle:dosboxDrive]];
    
    NSURL *fileURL = [NSURL URLFromFileSystemRepresentation: localPath];
    return [self.delegate emulator: self shouldAllowWriteAccessToURL: fileURL onDrive: drive];
}


#pragma mark - Mapping local filesystem access


- (NSURL *) _filesystemURLForDOSPath: (const char *)dosPath
                       onDOSBoxDrive: (uintptr_t)dosboxDrive
{
	if ([BXEmulatorCore DOSBoxDriveType:dosboxDrive] == 4 ||
	    [BXEmulatorCore DOSBoxDriveType:dosboxDrive] == 3)
	{
		BXDrive *drive = [self _driveFromDOSBoxDriveAtIndex:[self _indexOfDOSBoxDriveHandle:dosboxDrive]];
        id <ADBFilesystemFileURLAccess> filesystem = (id)drive.filesystem;
        NSAssert2([filesystem conformsToProtocol: @protocol(ADBFilesystemFileURLAccess)],
                  @"Filesystem %@ for drive %@ does not support local URL file access.", filesystem, drive);
        
        //If the DOS path starts with a drive letter, snip this off
        const char *driveRelativePath;
        if (strlen(dosPath) >= 2 && dosPath[1] == ':')
            driveRelativePath = dosPath+2;
        else
            driveRelativePath = dosPath;
        
		NSUInteger hostPathLength = [BXEmulatorCore maximumDOSBoxHostPathLength];
		if (!hostPathLength) return nil;
		std::vector<char> filePath(hostPathLength);
		if (![BXEmulatorCore DOSBoxDrive:dosboxDrive mapDOSPath:driveRelativePath intoBuffer:filePath.data() capacity:filePath.size()])
			return nil;
		NSURL *localURL = [NSURL fileURLWithFileSystemRepresentation: filePath.data()
								 isDirectory: NO
								   relativeToURL: nil].URLByStandardizingPath;
        
        //Roundtrip the URL through the filesystem, in case it remaps it to another location.
        NSString *logicalPath = [filesystem pathForFileURL: localURL];
        NSURL *resolvedURL = [filesystem fileURLForPath: logicalPath];
        
        return resolvedURL;
	}
	//We can't resolve filesystem URLs for non-local drives
	else
    {
        return nil;
    }
}


- (NSURL *) _logicalURLForDOSPath: (const char *)dosCPath
                    onDOSBoxDrive: (uintptr_t)dosboxDrive
{
    BXDrive *drive = [self _driveFromDOSBoxDriveAtIndex:[self _indexOfDOSBoxDriveHandle:dosboxDrive]];
    NSString *dosPath = [NSString stringWithCString: dosCPath encoding: BXDirectStringEncoding];
    //FIXME: this will leave short filenames intact instead of resolving them back to the filesystem's own long filenames.
    return [drive logicalURLForDOSPath: dosPath];
}

- (FILE *) _openFileForCaptureOfType: (const char *)typeDescription extension: (const char *)fileExtension
{
    NSString *type  = [NSString stringWithUTF8String: typeDescription];
    NSString *ext   = [NSString stringWithUTF8String: fileExtension];
    //Strip off DOSBox's leading extension separators
    if ([ext hasPrefix: @"."])
        ext = [ext substringFromIndex: 1];
    
    return [self.delegate emulator: self openCaptureFileOfType: type extension: ext];
}

- (FILE *) _openFileAtLocalPath: (const char *)path
                  onDOSBoxDrive: (uintptr_t)dosboxDrive
                         inMode: (const char *)mode
{
    BXDrive *drive = [self _driveFromDOSBoxDriveAtIndex:[self _indexOfDOSBoxDriveHandle:dosboxDrive]];
    id <ADBFilesystemFileURLAccess> filesystem = (id)drive.filesystem;
    NSAssert2([filesystem conformsToProtocol: @protocol(ADBFilesystemFileURLAccess)],
              @"Filesystem %@ for drive %@ does not support local URL file access.", filesystem, drive);
    
    NSURL *localURL = [NSURL URLFromFileSystemRepresentation: path];
    NSString *logicalPath = [filesystem pathForFileURL: localURL];
    
    NSError *openError = nil;
    FILE * file = [drive.filesystem openFileAtPath: logicalPath inMode: mode error: &openError];
    if (!file)
    {
        //NSLog(@"Open of file %@ (%@) in mode %s failed, error: %@", logicalPath, localURL, mode, openError);
    }
    else
    {
        //NSLog(@"Opened %@ (%@) in mode %s", logicalPath, localURL, mode);
    }
    return file;
}

- (BOOL) _removeFileAtLocalPath: (const char *)path
                  onDOSBoxDrive: (uintptr_t)dosboxDrive
{
    BXDrive *drive = [self _driveFromDOSBoxDriveAtIndex:[self _indexOfDOSBoxDriveHandle:dosboxDrive]];
    id <ADBFilesystemFileURLAccess> filesystem = (id)drive.filesystem;
    NSAssert2([filesystem conformsToProtocol: @protocol(ADBFilesystemFileURLAccess)],
              @"Filesystem %@ for drive %@ does not support local URL file access.", filesystem, drive);
    
    NSURL *localURL = [NSURL URLFromFileSystemRepresentation: path];
    NSString *logicalPath = [filesystem pathForFileURL: localURL];
    
    NSError *removeError = nil;
    BOOL removed = [drive.filesystem removeItemAtPath: logicalPath error: &removeError];
    if (!removed)
    {
        //NSLog(@"Removal of %@ (%@) failed, error: %@", logicalPath, localURL, removeError);
    }
    else
    {
        //NSLog(@"Removal of %@ (%@) succeeded.", logicalPath, localURL);
    }
    return removed;
}

- (BOOL) _moveLocalPath: (const char *)sourcePath
            toLocalPath: (const char *)destinationPath
          onDOSBoxDrive: (uintptr_t)dosboxDrive
{
    BXDrive *drive = [self _driveFromDOSBoxDriveAtIndex:[self _indexOfDOSBoxDriveHandle:dosboxDrive]];
    id <ADBFilesystemPathAccess, ADBFilesystemFileURLAccess> filesystem = (id)drive.filesystem;
    NSAssert2([filesystem conformsToProtocol: @protocol(ADBFilesystemFileURLAccess)],
              @"Filesystem %@ for drive %@ does not support local URL file access.", filesystem, drive);
    
    NSURL *localSourceURL       = [NSURL URLFromFileSystemRepresentation: sourcePath];
    NSURL *localDestinationURL  = [NSURL URLFromFileSystemRepresentation: destinationPath];
    NSString *logicalSourcePath = [filesystem pathForFileURL: localSourceURL];
    NSString *logicalDestinationPath = [filesystem pathForFileURL: localDestinationURL];
    
    NSError *moveError = nil;
    BOOL moved = [filesystem moveItemAtPath: logicalSourcePath toPath: logicalDestinationPath error: &moveError];
    /*
    if (!moved)
    {
        NSLog(@"Move of %@ (%@) to %@ (%@) failed, error: %@", logicalSourcePath, localSourceURL, logicalDestinationPath, localDestinationURL, moveError);
    }
    else
    {
        NSLog(@"Move of %@ (%@) to %@ (%@) succeeded.", logicalSourcePath, localSourceURL, logicalDestinationPath, localDestinationURL);
    }
     */
    return moved;
}

- (BOOL) _createDirectoryAtLocalPath: (const char *)path
                       onDOSBoxDrive: (uintptr_t)dosboxDrive
{
	BXDrive *drive = [self _driveFromDOSBoxDriveAtIndex:[self _indexOfDOSBoxDriveHandle:dosboxDrive]];
    id <ADBFilesystemPathAccess, ADBFilesystemFileURLAccess> filesystem = (id)drive.filesystem;
    NSAssert2([filesystem conformsToProtocol: @protocol(ADBFilesystemFileURLAccess)],
              @"Filesystem %@ for drive %@ does not support local URL file access.", filesystem, drive);
    
    NSURL *localURL         = [NSURL URLFromFileSystemRepresentation: path];
    NSString *logicalPath   = [filesystem pathForFileURL: localURL];

    NSError *createError = nil;
    BOOL created = [filesystem createDirectoryAtPath: logicalPath
                         withIntermediateDirectories: NO
                                               error: &createError];
    /*
    if (!created)
    {
        NSLog(@"Creation of directory at %@ (%@) failed, error: %@", logicalPath, localURL, createError);
    }
    else
    {
        NSLog(@"Creation of directory at %@ (%@) succeeded.", logicalPath, localURL);
    }
     */
    return created;
}

- (BOOL) _removeDirectoryAtLocalPath: (const char *)path
                       onDOSBoxDrive: (uintptr_t)dosboxDrive
{
    BXDrive *drive = [self _driveFromDOSBoxDriveAtIndex:[self _indexOfDOSBoxDriveHandle:dosboxDrive]];
    id <ADBFilesystemPathAccess, ADBFilesystemFileURLAccess> filesystem = (id)drive.filesystem;
    NSAssert2([filesystem conformsToProtocol: @protocol(ADBFilesystemFileURLAccess)],
              @"Filesystem %@ for drive %@ does not support local URL file access.", filesystem, drive);
    
    NSURL *localURL = [NSURL URLFromFileSystemRepresentation: path];
    NSString *logicalPath = [filesystem pathForFileURL: localURL];
    
    NSError *removeError = nil;
    BOOL removed = [drive.filesystem removeItemAtPath: logicalPath error: &removeError];
    /*
    if (!removed)
    {
        NSLog(@"Removal of %@ (%@) failed, error: %@", logicalPath, localURL, removeError);
    }
    else
    {
        NSLog(@"Removal of %@ (%@) succeeded.", logicalPath, localURL);
    }
     */
    return removed;
}

- (BOOL) _getStats: (struct stat *)outStatus
      forLocalPath: (const char *)path
     onDOSBoxDrive: (uintptr_t)dosboxDrive
{
    BXDrive *drive = [self _driveFromDOSBoxDriveAtIndex:[self _indexOfDOSBoxDriveHandle:dosboxDrive]];
    id <ADBFilesystemPathAccess, ADBFilesystemFileURLAccess> filesystem = (id)drive.filesystem;
    NSAssert2([filesystem conformsToProtocol: @protocol(ADBFilesystemFileURLAccess)],
              @"Filesystem %@ for drive %@ does not support local URL file access.", filesystem, drive);
    
    //Round-trip the path in case the filesystem remaps it to a different file location
    NSURL *localURL         = [NSURL URLFromFileSystemRepresentation: path];
    NSString *logicalPath   = [filesystem pathForFileURL: localURL];
    
    //TWEAK: ensure that the file actually exists at that path before statting it.
    //That way we won't return stats blocks for files that are ostensibly deleted.
    //TODO: move the stats retrieval upstream into the filesystem classes where they
    //can make that call themselves; OR replace the entire downstream localDrive API
    //to avoid the need for all this bullshit.
    if (logicalPath && [filesystem fileExistsAtPath: logicalPath isDirectory: NULL])
    {
        NSURL *resolvedURL = [filesystem fileURLForPath: logicalPath];
        const char *filesystemPath = resolvedURL.fileSystemRepresentation;
        
        //NSLog(@"Getting stats block for %@ (%@)", logicalPath, resolvedURL);
        if (filesystemPath)
        {
            return stat(filesystemPath, outStatus) == 0;
        }
    }
    return NO;
}

- (BOOL) _localDirectoryExists: (const char *)path
                 onDOSBoxDrive: (uintptr_t)dosboxDrive
{
    BXDrive *drive = [self _driveFromDOSBoxDriveAtIndex:[self _indexOfDOSBoxDriveHandle:dosboxDrive]];
    id <ADBFilesystemPathAccess, ADBFilesystemFileURLAccess> filesystem = (id)drive.filesystem;
    NSAssert2([filesystem conformsToProtocol: @protocol(ADBFilesystemFileURLAccess)],
              @"Filesystem %@ for drive %@ does not support local URL file access.", filesystem, drive);
    
    BOOL isDirectory;
    NSURL *localURL = [NSURL URLFromFileSystemRepresentation: path];
    NSString *logicalPath = [filesystem pathForFileURL: localURL];
    
    BOOL exists = [filesystem fileExistsAtPath: logicalPath isDirectory: &isDirectory];
    //NSLog(@"Checking existence of %@ (%@), exists: %i is directory: %i", localURL, logicalPath, exists, exists && isDirectory);
    
    return (exists && isDirectory);
}

- (BOOL) _localFileExists: (const char *)path
            onDOSBoxDrive: (uintptr_t)dosboxDrive
{
    BXDrive *drive = [self _driveFromDOSBoxDriveAtIndex:[self _indexOfDOSBoxDriveHandle:dosboxDrive]];
    id <ADBFilesystemPathAccess, ADBFilesystemFileURLAccess> filesystem = (id)drive.filesystem;
    NSAssert2([filesystem conformsToProtocol: @protocol(ADBFilesystemFileURLAccess)],
              @"Filesystem %@ for drive %@ does not support local URL file access.", filesystem, drive);
    
    BOOL isDirectory;
    NSURL *localURL = [NSURL URLFromFileSystemRepresentation: path];
    NSString *logicalPath = [filesystem pathForFileURL: localURL];
    
    BOOL exists = [filesystem fileExistsAtPath: logicalPath isDirectory: &isDirectory];
    //NSLog(@"Checking existence of %@ (%@), exists: %i is directory: %i", localURL, logicalPath, exists, exists && isDirectory);
    
    return (exists && !isDirectory);
}

- (id <ADBFilesystemFileURLEnumeration>) _directoryEnumeratorForLocalPath: (const char *)path
                                                            onDOSBoxDrive: (uintptr_t)dosboxDrive
{
    BXDrive *drive = [self _driveFromDOSBoxDriveAtIndex:[self _indexOfDOSBoxDriveHandle:dosboxDrive]];
    id <ADBFilesystemPathAccess, ADBFilesystemFileURLAccess> filesystem = (id)drive.filesystem;
    NSAssert2([filesystem conformsToProtocol: @protocol(ADBFilesystemFileURLAccess)],
              @"Filesystem %@ for drive %@ does not support local URL file access.", filesystem, drive);
    
    NSURL *localFileURL = [NSURL URLFromFileSystemRepresentation: path];
    
    return [filesystem enumeratorAtFileURL: localFileURL
                includingPropertiesForKeys: @[NSURLIsDirectoryKey, NSURLNameKey]
                                   options: NSDirectoryEnumerationSkipsSubdirectoryDescendants
                              errorHandler: NULL];
}

@end
