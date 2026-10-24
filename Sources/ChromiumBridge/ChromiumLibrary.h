#import <Foundation/Foundation.h>
#import "ChromiumEngineServices.h"

NS_ASSUME_NONNULL_BEGIN

@interface ARCLibraryService : NSObject
@property(copy, nullable) void (^onError)(NSString *profileID, NSString *section, NSString *message);
- (instancetype)initWithServices:(ARCEngineServices *)services;
- (void)watchProfileID:(NSString *)profileID;
- (void)bookmarksForProfileID:(NSString *)profileID
  completion:(void (^)(NSDictionary * _Nullable, NSError * _Nullable))completion;
- (void)applyBookmarkOperation:(NSDictionary *)operation profileID:(NSString *)profileID
  completion:(void (^)(NSError * _Nullable))completion;
- (void)historyForProfileID:(NSString *)profileID limit:(NSInteger)limit
  completion:(void (^)(NSArray<NSDictionary *> * _Nullable, NSError * _Nullable))completion;
- (void)deleteHistoryURL:(NSString *)url profileID:(NSString *)profileID
  completion:(void (^)(NSError * _Nullable))completion;
@end

NS_ASSUME_NONNULL_END
