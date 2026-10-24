#import "ChromiumDownloads.h"
#import "../../ThirdParty/ArdiaCore/ac_engine.h"
#include <dlfcn.h>
#include <string.h>

static NSError *DownloadError(NSString *message) {
  return [NSError errorWithDomain:@"com.arcusis.browser.downloads" code:1
                        userInfo:@{NSLocalizedDescriptionKey: message}];
}

static NSDictionary *DownloadJSON(const char *json) {
  if (!json) return nil;
  NSData *data = [NSData dataWithBytes:json length:strlen(json)];
  id value = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
  return [value isKindOfClass:NSDictionary.class] ? value : nil;
}

static void DownloadReply(void *context, const char *json) {
  void (^done)(NSDictionary *) = (__bridge_transfer void (^)(NSDictionary *))context;
  done(DownloadJSON(json) ?: @{@"error": @"Invalid download service response."});
}

@interface ARCDownloadService ()
- (void)receiveTopic:(NSString *)topic payload:(NSDictionary *)payload;
@end

static void DownloadEvent(void *context, const char *topic, const char *json) {
  if (!topic) return;
  NSString *name = [NSString stringWithUTF8String:topic];
  if (![name isEqualToString:@"downloads.changed"] && ![name isEqualToString:@"downloads.removed"]) return;
  NSDictionary *payload = DownloadJSON(json);
  if (payload) [(__bridge ARCDownloadService *)context receiveTopic:name payload:payload];
}

@implementation ARCDownloadService {
  ac_engine_set_event_sink_t _setSink;
  NSDictionary<NSString *, NSValue *> *_calls;
  NSMutableDictionary<NSString *, NSString *> *_paths;
  NSMutableDictionary<NSString *, NSString *> *_profilesByPath;
  BOOL _started;
}

- (instancetype)initWithLibrary:(void *)library error:(NSError **)error {
  if (!(self = [super init])) return nil;
  auto version = (ac_engine_abi_version_t)dlsym(library, "ac_engine_abi_version");
  _setSink = (ac_engine_set_event_sink_t)dlsym(library, "ac_engine_set_event_sink");
  NSMutableDictionary *calls = [NSMutableDictionary dictionary];
  for (NSString *name in @[@"list", @"pause", @"resume", @"cancel", @"remove"]) {
    NSString *symbol = [@"ac_downloads_" stringByAppendingString:name];
    void *address = dlsym(library, symbol.UTF8String);
    if (address) calls[name] = [NSValue valueWithPointer:address];
  }
  if (!version || version() != AC_ENGINE_ABI_VERSION || !_setSink || calls.count != 5) {
    if (error) *error = DownloadError(@"The engine does not expose the pinned download service ABI.");
    return nil;
  }
  _calls = calls;
  _paths = [NSMutableDictionary dictionary];
  _profilesByPath = [NSMutableDictionary dictionary];
  return self;
}

- (void)start {
  NSAssert(NSThread.isMainThread, @"Download services must run on the engine UI thread");
  if (_started) return;
  _started = YES;
  _setSink(DownloadEvent, (__bridge void *)self);
}

- (void)dealloc {
  if (_started) _setSink(nullptr, nullptr);
}

- (void)watchProfileID:(NSString *)profileID path:(NSString *)path
           completion:(void (^)(NSArray<NSDictionary *> *, NSError *))completion {
  NSAssert(NSThread.isMainThread, @"Download services must run on the engine UI thread");
  NSString *canonical = path.stringByStandardizingPath.stringByResolvingSymlinksInPath;
  NSString *owner = _profilesByPath[canonical];
  if (!_started || ![[NSUUID alloc] initWithUUIDString:profileID] || !path.isAbsolutePath ||
      (owner && ![owner isEqualToString:profileID]) ||
      (_paths[profileID] && ![_paths[profileID] isEqualToString:canonical])) {
    completion(nil, DownloadError(@"The download profile could not be verified."));
    return;
  }
  _paths[profileID] = canonical;
  _profilesByPath[canonical] = profileID;
  [self call:@"list" profileID:profileID args:@{} completion:^(NSDictionary *result) {
    NSArray *rows = result[@"downloads"];
    if ([result[@"error"] isKindOfClass:NSString.class] || ![rows isKindOfClass:NSArray.class]) {
      completion(nil, DownloadError(@"Downloads could not be restored for this profile."));
    } else {
      for (id row in rows) {
        if (![row isKindOfClass:NSDictionary.class]) {
          completion(nil, DownloadError(@"Invalid download history response."));
          return;
        }
      }
      completion(rows, nil);
    }
  }];
}

- (void)command:(NSString *)command downloadID:(NSString *)downloadID profileID:(NSString *)profileID
     completion:(void (^)(NSError *))completion {
  if (![@[@"pause", @"resume", @"cancel", @"remove"] containsObject:command] ||
      ![[NSUUID alloc] initWithUUIDString:downloadID]) {
    completion(DownloadError(@"Invalid download action."));
    return;
  }
  [self call:command profileID:profileID args:@{@"id": downloadID} completion:^(NSDictionary *result) {
    NSString *message = result[@"error"];
    if ([message isKindOfClass:NSString.class]) {
      completion(DownloadError([message isEqualToString:@"can't resume"]
        ? @"This download cannot be resumed." : @"The download action could not be completed."));
    } else if (![result[@"ok"] isEqual:@YES]) {
      completion(DownloadError(@"The engine did not confirm the download action."));
    } else {
      completion(nil);
    }
  }];
}

- (void)call:(NSString *)name profileID:(NSString *)profileID args:(NSDictionary *)args
  completion:(void (^)(NSDictionary *))completion {
  NSAssert(NSThread.isMainThread, @"Download services must run on the engine UI thread");
  NSString *path = _paths[profileID];
  auto call = (ac_engine_call_t)_calls[name].pointerValue;
  NSData *data = [NSJSONSerialization dataWithJSONObject:args options:0 error:nil];
  NSString *json = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
  if (!_started || !path || !call || !json) {
    completion(@{@"error": @"Unknown download profile or action."});
    return;
  }
  call(path.UTF8String, json.UTF8String, DownloadReply, (__bridge_retained void *)[completion copy]);
}

- (void)receiveTopic:(NSString *)topic payload:(NSDictionary *)payload {
  NSAssert(NSThread.isMainThread, @"Download services must run on the engine UI thread");
  NSString *path = payload[@"profile"];
  if (![path isKindOfClass:NSString.class] || !path.isAbsolutePath) return;
  NSString *profileID = _profilesByPath[path.stringByStandardizingPath.stringByResolvingSymlinksInPath];
  // Unknown engine profiles never fall back to a default or inferred directory name.
  if (!profileID) return;
  if ([topic isEqualToString:@"downloads.changed"]) {
    NSDictionary *item = payload[@"download"];
    if ([item isKindOfClass:NSDictionary.class] && _onChanged) _onChanged(profileID, item);
  } else {
    NSString *identity = payload[@"id"];
    if ([identity isKindOfClass:NSString.class] && _onRemoved) _onRemoved(profileID, identity);
  }
}
@end
