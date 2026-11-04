// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#import "ChromiumBridge.h"

NS_ASSUME_NONNULL_BEGIN

/// Directory changes are acknowledged by the selected Shaar profile before the app saves them.
@interface ARCShaarRuntime (DownloadDirectorySettings)
- (void)configureDownloadDirectory:(nullable NSURL *)directory profileID:(NSString *)profileID
    completion:(void (NS_SWIFT_UI_ACTOR ^)(NSURL * _Nullable, NSError * _Nullable))completion NS_SWIFT_UI_ACTOR;
@end

NS_ASSUME_NONNULL_END
