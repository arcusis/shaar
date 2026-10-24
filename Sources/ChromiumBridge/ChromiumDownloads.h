#import <Foundation/Foundation.h>
#import "ChromiumEngineServices.h"

NS_ASSUME_NONNULL_BEGIN

/// Direct adapter for the pinned engine's profile-scoped download service ABI.
@interface ARCDownloadService : NSObject
@property(copy, nullable) void (^onChanged)(NSString *profileID, NSDictionary<NSString *, id> *download);
@property(copy, nullable) void (^onRemoved)(NSString *profileID, NSString *downloadID);
- (instancetype)initWithServices:(ARCEngineServices *)services;
- (void)watchProfileID:(NSString *)profileID
           completion:(void (^)(NSArray<NSDictionary *> * _Nullable, NSError * _Nullable))completion;
- (void)command:(NSString *)command downloadID:(NSString *)downloadID profileID:(NSString *)profileID
     completion:(void (^)(NSError * _Nullable))completion;
- (void)receiveTopic:(NSString *)topic profileID:(NSString *)profileID payload:(NSDictionary *)payload;
@end

NS_ASSUME_NONNULL_END
