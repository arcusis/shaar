// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Owns the pinned ABI's single event sink and exact loaded-profile bindings.
@interface ARCEngineServices : NSObject
@property(copy, nullable) void (^onEvent)(NSString *topic, NSString *profileID, NSDictionary *payload);
- (nullable instancetype)initWithLibrary:(void *)library error:(NSError **)error;
- (void)start;
- (BOOL)bindProfileID:(NSString *)profileID path:(NSString *)path error:(NSError **)error;
- (void)call:(NSString *)method profileID:(NSString *)profileID args:(NSDictionary *)args
  completion:(void (^)(NSDictionary *result))completion;
@end

NS_ASSUME_NONNULL_END
