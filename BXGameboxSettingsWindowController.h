/*
 Copyright (c) 2026 Alun Bestor and contributors. All rights reserved.
 This source file is released under the GNU General Public License 2.0.
 */

#import <Cocoa/Cocoa.h>

@class BXGamebox;
@class BXSession;

NS_ASSUME_NONNULL_BEGIN

@interface BXGameboxSettingsWindowController : NSWindowController

- (instancetype)initWithGamebox:(BXGamebox *)gamebox
                         session:(nullable BXSession *)session NS_DESIGNATED_INITIALIZER;

- (instancetype)initWithWindow:(nullable NSWindow *)window NS_UNAVAILABLE;
- (instancetype)initWithCoder:(NSCoder *)coder NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
