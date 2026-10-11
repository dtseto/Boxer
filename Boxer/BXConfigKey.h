/*
 Copyright (c) 2026 Alun Bestor and contributors. All rights reserved.
 This source file is released under the GNU General Public License 2.0. A full copy of this license
 can be found in this XCode project at Resources/English.lproj/BoxerHelp/pages/legalese.html, or read
 online at [http://www.gnu.org/licenses/gpl-2.0.txt].
 */

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// An immutable value identifying a DOSBox configuration setting without exposing DOSBox types.
@interface BXConfigKey : NSObject <NSCopying>

@property (nonatomic, copy, readonly) NSString *section;
@property (nonatomic, copy, readonly) NSString *key;

- (instancetype)initWithSection:(NSString *)section
                            key:(NSString *)key NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
