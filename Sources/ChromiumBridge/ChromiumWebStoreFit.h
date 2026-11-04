// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class ARCShaarRuntime;

/// Zooms Chrome Web Store tabs out just enough to fit the store's fixed body minimum width,
/// and back to 100% once the page card is wide enough. A manual zoom holds until the next navigation.
@interface ARCWebStoreFit : NSObject
- (instancetype)init NS_UNAVAILABLE;
- (instancetype)initWithTesting:(BOOL)testing;
/// Shaar navigation events carry the tab identity; the page view supplies resize notifications.
- (void)shaarTabDidReceiveEvent:(NSDictionary *)event tabID:(NSString *)tabID runtime:(ARCShaarRuntime *)runtime;
- (void)shaarTabWillCloseID:(NSString *)tabID;
@end

NS_ASSUME_NONNULL_END
