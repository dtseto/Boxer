/*
 Copyright (c) 2026 Alun Bestor and contributors. All rights reserved.
 This source file is released under the GNU General Public License 2.0. A full copy of this license
 can be found in this XCode project at Resources/English.lproj/BoxerHelp/pages/legalese.html, or read
 online at [http://www.gnu.org/licenses/gpl-2.0.txt].
 */

#import "BXConfigKey.h"

@implementation BXConfigKey

- (instancetype)initWithSection:(NSString *)section
                            key:(NSString *)key
{
    NSParameterAssert(section.length > 0);
    NSParameterAssert(key.length > 0);

    self = [super init];
    if (self)
    {
        _section = [section copy];
        _key = [key copy];
    }
    return self;
}

- (id)copyWithZone:(NSZone *)zone
{
    return self;
}

- (BOOL)isEqual:(id)object
{
    if (self == object)
        return YES;

    if (![object isKindOfClass:[BXConfigKey class]])
        return NO;

    BXConfigKey *other = object;
    return [self.section isEqualToString:other.section] &&
           [self.key isEqualToString:other.key];
}

- (NSUInteger)hash
{
    return self.section.hash ^ self.key.hash;
}

- (NSString *)description
{
    return [NSString stringWithFormat:@"[%@] %@", self.section, self.key];
}

@end
