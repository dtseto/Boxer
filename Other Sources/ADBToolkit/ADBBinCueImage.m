/*
 *  Copyright (c) 2013, Alun Bestor (alun.bestor@gmail.com)
 *  All rights reserved.
 *
 *  Redistribution and use in source and binary forms, with or without modification,
 *  are permitted provided that the following conditions are met:
 *
 *		Redistributions of source code must retain the above copyright notice, this
 *	    list of conditions and the following disclaimer.
 *
 *		Redistributions in binary form must reproduce the above copyright notice,
 *	    this list of conditions and the following disclaimer in the documentation
 *      and/or other materials provided with the distribution.
 *
 *	THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
 *	ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
 *	WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED.
 *	IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT,
 *	INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING,
 *	BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA,
 *	OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY,
 *	WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 *	ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
 *	POSSIBILITY OF SUCH DAMAGE.
 */

#import "ADBBinCueImage.h"
#import "ADBISOImagePrivate.h"
#import "NSURL+ADBFilesystemHelpers.h"
#import "RegexKitLite.h"


/// Matches the following lines with optional leading and trailing whitespace:
/// FILE MAX.gog BINARY
/// FILE "MAX.gog" BINARY
/// FILE "Armin van Buuren - A State of Trance 179 (16-12-2004) Part2.wav" WAV
/// FILE 01_armin_van_buuren_-_in_the_mix_(asot179)-cable-12-16-2004-hsalive.mp3 MP3
NSString * const ADBCueErrorDomain = @"ADBCueErrorDomain";
NSString * const ADBCueFileDescriptorSyntax = @"(?im)^[\\t ]*FILE[\\t ]+(?:\"((?:\\\\.|[^\"])*)\"|(\\S+))[\\t ]+\\S+";

/// The maximum size in bytes that a cue file is expected to be, before we consider it not a cue file.
/// This is used as a sanity check by +isCueAtPath: to avoid scanning large files unnecessarily.
#define ADBCueMaxFileSize 10240


@implementation ADBBinCueImage

+ (NSError *) _cueErrorWithCode: (ADBCueErrorCode)code URL: (NSURL *)URL path: (NSString *)path
{
    NSString *description = nil;
    NSString *suggestion = nil;
    switch (code)
    {
        case ADBCueErrorUnsafePath:
            description = NSLocalizedString(@"The CUE image contains an unsafe track path.", @"CUE traversal error description");
            suggestion = [NSString stringWithFormat: NSLocalizedString(@"The track path “%@” escapes the CUE folder. Remove parent-directory components and try again.", @"CUE traversal recovery suggestion"), path ?: @""];
            break;
        case ADBCueErrorMissingTrack:
            description = NSLocalizedString(@"A track referenced by the CUE image is missing.", @"Missing CUE track error description");
            suggestion = [NSString stringWithFormat: NSLocalizedString(@"Make sure “%@” is alongside the CUE image and try again.", @"Missing CUE track recovery suggestion"), path ?: @""];
            break;
        case ADBCueErrorUnreadableTrack:
            description = NSLocalizedString(@"A track referenced by the CUE image cannot be read.", @"Unreadable CUE track error description");
            suggestion = [NSString stringWithFormat: NSLocalizedString(@"Check the permissions for “%@” and try again.", @"Unreadable CUE track recovery suggestion"), path ?: @""];
            break;
        default:
            description = NSLocalizedString(@"The CUE image is not structurally usable.", @"Malformed CUE error description");
            suggestion = NSLocalizedString(@"The file must contain FILE and TRACK directives.", @"Malformed CUE recovery suggestion");
            break;
    }
    NSMutableDictionary *userInfo = [NSMutableDictionary dictionaryWithObjectsAndKeys:
                                     description, NSLocalizedDescriptionKey,
                                     suggestion, NSLocalizedRecoverySuggestionErrorKey, nil];
    if (URL) [userInfo setObject: URL forKey: NSURLErrorKey];
    if (path) [userInfo setObject: path forKey: NSFilePathErrorKey];
    return [NSError errorWithDomain: ADBCueErrorDomain code: code userInfo: userInfo];
}

+ (NSArray<NSTextCheckingResult *> *) _fileMatchesInContents: (NSString *)contents error: (NSError **)outError
{
    NSRegularExpression *expression = [NSRegularExpression regularExpressionWithPattern: ADBCueFileDescriptorSyntax
                                                                                 options: 0
                                                                                   error: outError];
    if (!expression) return nil;
    return [expression matchesInString: contents options: 0 range: NSMakeRange(0, contents.length)];
}

+ (NSString *) _rawPathForMatch: (NSTextCheckingResult *)match contents: (NSString *)contents
{
    for (NSUInteger capture = 1; capture <= 2; capture++)
    {
        NSRange range = [match rangeAtIndex: capture];
        if (range.location != NSNotFound)
        {
            NSString *path = [contents substringWithRange: range];
            return [path stringByReplacingOccurrencesOfString: @"\\\"" withString: @"\""];
        }
    }
    return nil;
}

#pragma mark - Helper class methods

+ (NSArray *) rawPathsInCueContents: (NSString *)cueContents
{
    NSMutableArray *paths = [NSMutableArray arrayWithCapacity: 1];
    for (NSTextCheckingResult *match in [self _fileMatchesInContents: cueContents error: NULL])
    {
        NSString *path = [self _rawPathForMatch: match contents: cueContents];
        if (path.length) [paths addObject: path];
    }
	
	return paths;
}

+ (NSURL *) _caseCorrectedURLForURL: (NSURL *)URL
{
    if ([URL checkResourceIsReachableAndReturnError: NULL]) return URL;
    NSArray *components = URL.path.pathComponents;
    if (!components.count) return URL;
    NSURL *candidate = [NSURL fileURLWithPath: components.firstObject isDirectory: YES];
    NSFileManager *manager = [NSFileManager defaultManager];
    for (NSString *component in [components subarrayWithRange: NSMakeRange(1, components.count - 1)])
    {
        NSArray *children = [manager contentsOfDirectoryAtPath: candidate.path error: NULL];
        NSString *actual = nil;
        for (NSString *child in children)
        {
            if ([child caseInsensitiveCompare: component] == NSOrderedSame) { actual = child; break; }
        }
        candidate = [candidate URLByAppendingPathComponent: actual ?: component];
    }
    return candidate;
}

+ (NSArray *) resourceURLsInCueAtURL: (NSURL *)cueURL error: (out NSError **)outError
{
    NSString *cueContents = [[NSString alloc] initWithContentsOfURL: cueURL
                                                       usedEncoding: NULL
                                                              error: outError];
	
    if (!cueContents)
        return nil;
    
    NSArray *rawPaths = [self rawPathsInCueContents: cueContents];
    
    //The URL relative to which we will resolve the paths in the CUE
    NSURL *baseURL = cueURL.URLByDeletingLastPathComponent;
    
    NSMutableArray *resolvedURLs = [NSMutableArray arrayWithCapacity: rawPaths.count];
    for (NSString *rawPath in rawPaths)
    @autoreleasepool {
        //Rewrite Windows-style paths
        NSString *normalizedPath = [rawPath stringByReplacingOccurrencesOfString: @"\\" withString: @"/"];
        
        //Form an absolute path with all ../ components resolved.
        NSURL *resourceURL = nil;
        BOOL isWindowsAbsolutePath = [normalizedPath rangeOfString: @"^[A-Za-z]:/"
                                                            options: NSRegularExpressionSearch].location != NSNotFound;
        if (normalizedPath.isAbsolutePath)
            resourceURL = [NSURL fileURLWithPath: normalizedPath].URLByStandardizingPath;
        else
            resourceURL = [baseURL URLByAppendingPathComponent: normalizedPath].URLByStandardizingPath;

        resourceURL = [self _caseCorrectedURLForURL: resourceURL];
        // Absolute Windows paths cannot identify a macOS volume after the CUE has
        // been transferred. Prefer a same-folder track with the referenced basename.
        if (isWindowsAbsolutePath && ![resourceURL checkResourceIsReachableAndReturnError: NULL])
        {
            NSURL *sameFolderURL = [baseURL URLByAppendingPathComponent: normalizedPath.lastPathComponent];
            resourceURL = [self _caseCorrectedURLForURL: sameFolderURL];
        }
        [resolvedURLs addObject: resourceURL];
    }
    return resolvedURLs;
}

+ (NSArray<NSURL*> *) validatedResourceURLsInCueAtURL: (NSURL *)cueURL error: (NSError **)outError
{
    NSError *readError = nil;
    NSString *contents = [[NSString alloc] initWithContentsOfURL: cueURL usedEncoding: NULL error: &readError];
    if (!contents)
    {
        if (outError) *outError = readError;
        return nil;
    }
    NSArray<NSTextCheckingResult *> *fileMatches = [self _fileMatchesInContents: contents error: outError];
    NSArray *rawPaths = [self rawPathsInCueContents: contents];
    BOOL structurallyUsable = rawPaths.count > 0;
    for (NSUInteger index = 0; index < fileMatches.count && structurallyUsable; index++)
    {
        NSUInteger start = NSMaxRange([[fileMatches objectAtIndex: index] range]);
        NSUInteger end = (index + 1 < fileMatches.count) ? [[fileMatches objectAtIndex: index + 1] range].location : contents.length;
        NSRange section = NSMakeRange(start, end - start);
        structurallyUsable = [contents rangeOfString: @"(?im)^[\\t ]*TRACK[\\t ]+\\d+[\\t ]+\\S+"
                                                options: NSRegularExpressionSearch
                                                  range: section].location != NSNotFound;
    }
    if (!structurallyUsable)
    {
        if (outError) *outError = [self _cueErrorWithCode: ADBCueErrorMalformed URL: cueURL path: nil];
        return nil;
    }
    for (NSString *rawPath in rawPaths)
    {
        NSString *normalized = [rawPath stringByReplacingOccurrencesOfString: @"\\" withString: @"/"];
        if (!normalized.isAbsolutePath && [normalized.pathComponents containsObject: @".."])
        {
            if (outError) *outError = [self _cueErrorWithCode: ADBCueErrorUnsafePath URL: cueURL path: rawPath];
            return nil;
        }
    }
    NSArray *URLs = [self resourceURLsInCueAtURL: cueURL error: outError];
    NSFileManager *manager = [NSFileManager defaultManager];
    for (NSUInteger index = 0; index < URLs.count; index++)
    {
        NSURL *URL = [URLs objectAtIndex: index];
        BOOL isDirectory = NO;
        if (![manager fileExistsAtPath: URL.path isDirectory: &isDirectory] || isDirectory)
        {
            if (outError) *outError = [self _cueErrorWithCode: ADBCueErrorMissingTrack URL: cueURL path: [rawPaths objectAtIndex: index]];
            return nil;
        }
        if (![manager isReadableFileAtPath: URL.path])
        {
            if (outError) *outError = [self _cueErrorWithCode: ADBCueErrorUnreadableTrack URL: cueURL path: [rawPaths objectAtIndex: index]];
            return nil;
        }
    }
    return URLs;
}

+ (NSString *) cueContents: (NSString *)cueContents byReplacingReferencedPathsWith: (NSArray<NSString*> *)replacementPaths error: (NSError **)outError
{
    NSArray<NSTextCheckingResult *> *matches = [self _fileMatchesInContents: cueContents error: outError];
    if (matches.count != replacementPaths.count)
    {
        if (outError) *outError = [self _cueErrorWithCode: ADBCueErrorMalformed URL: nil path: nil];
        return nil;
    }
    NSMutableString *rewritten = [cueContents mutableCopy];
    for (NSInteger index = (NSInteger)matches.count - 1; index >= 0; index--)
    {
        NSTextCheckingResult *match = [matches objectAtIndex: (NSUInteger)index];
        NSRange pathRange = [match rangeAtIndex: 1];
        BOOL quoted = pathRange.location != NSNotFound;
        if (!quoted) pathRange = [match rangeAtIndex: 2];
        NSString *replacement = [replacementPaths objectAtIndex: (NSUInteger)index];
        if (quoted)
            replacement = [replacement stringByReplacingOccurrencesOfString: @"\"" withString: @"\\\""];
        else if ([replacement rangeOfCharacterFromSet: [NSCharacterSet whitespaceCharacterSet]].location != NSNotFound)
            replacement = [NSString stringWithFormat: @"\"%@\"", [replacement stringByReplacingOccurrencesOfString: @"\"" withString: @"\\\""]];
        [rewritten replaceCharactersInRange: pathRange withString: replacement];
    }
    return rewritten;
}

+ (NSURL *) dataImageURLInCueAtURL: (NSURL *)cueURL error: (out NSError **)outError
{
    NSArray *resolvedURLs = [self resourceURLsInCueAtURL: cueURL error: outError];
    if (!resolvedURLs.count) return nil;
    
    //Assume the first entry in the CUE file is always the binary image.
    //(This is not always true, and we should do more in-depth scanning.)
    return [resolvedURLs objectAtIndex: 0];
}

+ (BOOL) isCueAtURL: (NSURL *)cueURL error: (out NSError **)outError
{
    if (![cueURL checkResourceIsReachableAndReturnError: outError])
        return NO;
    
    NSNumber *fileSizeValue;
    BOOL checkedSize = [cueURL getResourceValue: &fileSizeValue forKey: NSURLFileSizeKey error: outError];
    if (!checkedSize)
        return NO;
    
    //If the specified file appears to be too large, assume it can't be a CUE file and bail out
    unsigned long long fileSize = fileSizeValue.unsignedLongLongValue;
    if (fileSize == 0 || fileSize > ADBCueMaxFileSize)
    {
        if (outError)
        {
            *outError = [NSError errorWithDomain: NSCocoaErrorDomain
                                            code: NSFileReadTooLargeError
                                        userInfo: @{ NSURLErrorKey: cueURL }];
        }
        return NO;
    }
    
    //Otherwise, load it in and see if it contains any track definitions.
    NSString *cueContents = [[NSString alloc] initWithContentsOfURL: cueURL
                                                       usedEncoding: NULL
                                                              error: outError];
    
    if (!cueContents)
        return NO;
    
    BOOL isCue = ([self rawPathsInCueContents: cueContents].count > 0);
    
    return isCue;
}

- (BOOL) _loadImageAtURL: (NSURL *)URL
                   error: (out NSError **)outError
{
    //Load the BIN part of the cuesheet
    if ([self.class isCueAtURL: URL error: outError])
    {
        //TODO: check the mode from the cue-sheet and populate the sector size and lead-in appropriately
        NSURL *dataURL = [self.class dataImageURLInCueAtURL: URL error: outError];
        if (dataURL)
        {
            URL = dataURL;
        }
        else
        {
            return NO;
        }
    }
    
    return [super _loadImageAtURL: URL error: outError];
}

@end
