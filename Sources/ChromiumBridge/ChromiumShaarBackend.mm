// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#import "include/ChromiumBridge.h"

#include <dlfcn.h>
#include <cstdlib>
#include <cstring>

#include "../../ThirdParty/ChromiumEngine/layer/chrome/browser/shaar/public/shaar_engine.h"

namespace {

NSError *ShaarError(NSString *message) {
  return [NSError errorWithDomain:@"org.arcusis.shaar.engine" code:1
                         userInfo:@{NSLocalizedDescriptionKey: message}];
}

shaar_bytes Bytes(NSString *value) {
  const char *text = value.UTF8String;
  return {text, text ? std::strlen(text) : 0};
}

shaar_error EmptyError() {
  shaar_error error = {};
  error.size = sizeof(error);
  return error;
}

struct Symbols {
  decltype(&shaar_engine_create) create = nullptr;
  decltype(&shaar_engine_run) run = nullptr;
  decltype(&shaar_engine_request_quit) request_quit = nullptr;
  decltype(&shaar_engine_release) release = nullptr;
  decltype(&shaar_profile_open) profile_open = nullptr;

  bool Load(void *library) {
#define SHAAR_LOAD(field, symbol) \
  field = reinterpret_cast<decltype(field)>(dlsym(library, "shaar_" #symbol))
    SHAAR_LOAD(create, engine_create);
    SHAAR_LOAD(run, engine_run);
    SHAAR_LOAD(request_quit, engine_request_quit);
    SHAAR_LOAD(release, engine_release);
    SHAAR_LOAD(profile_open, profile_open);
#undef SHAAR_LOAD
    return create && run && request_quit && release && profile_open;
  }
};

}  // namespace

@interface ARCShaarRuntime () {
  void *_shaarLibrary;
  shaar_engine *_shaarEngine;
  Symbols _symbols;
  NSString *_shaarPrimaryWindowID;
  NSMutableDictionary<NSString *, NSValue *> *_shaarProfiles;
  uint64_t _nextRequestID;
  BOOL _shaarQuitting;
  BOOL _shaarTesting;
}
- (void)receiveEvent:(const shaar_event *)event;
- (void)removeFailedProfileID:(NSString *)profileID;
@end

static void ShaarEventCallback(void *context, const shaar_event *event) {
  [(__bridge ARCShaarRuntime *)context receiveEvent:event];
}

@implementation ARCShaarRuntime

- (instancetype)initWithFrameworkURL:(NSURL *)url error:(NSError **)error {
  if (!(self = [super init])) return nil;
  self.languageIdentifier = @"en";
  _shaarPrimaryWindowID = NSUUID.UUID.UUIDString;
  _shaarProfiles = [NSMutableDictionary dictionary];
  _nextRequestID = 1;
  NSURL *binary = [url URLByAppendingPathComponent:@"Versions/Current/Chromium Framework"];
  _shaarLibrary = dlopen(binary.fileSystemRepresentation, RTLD_NOW | RTLD_GLOBAL);
  if (!_shaarLibrary || !_symbols.Load(_shaarLibrary)) {
    if (error) *error = ShaarError(@"The Chromium framework does not expose the Shaar engine ABI.");
    return nil;
  }
  return self;
}

- (int)runWithDataDirectory:(NSURL *)directory testing:(BOOL)testing {
  NSAssert(NSThread.isMainThread, @"Shaar engine requires the main thread");
  NSString *path = directory.path.stringByStandardizingPath;
  shaar_config config = {};
  config.size = sizeof(config);
  config.requested_major = SHAAR_ENGINE_ABI_MAJOR;
  config.requested_minor = SHAAR_ENGINE_ABI_MINOR;
  config.data_root = Bytes(path);
  config.locale = Bytes(self.languageIdentifier ?: @"en");
  config.on_event = ShaarEventCallback;
  config.event_context = (__bridge void *)self;
  shaar_error error = EmptyError();
  setenv("SHAAR_ENGINE_TESTING", testing ? "1" : "0", 1);
  if (_symbols.create(&config, &_shaarEngine, &error) != SHAAR_OK) {
    unsetenv("SHAAR_ENGINE_TESTING");
    return 1;
  }
  _shaarTesting = testing;
  const shaar_error_code result = _symbols.run(_shaarEngine, &error);
  unsetenv("SHAAR_ENGINE_TESTING");
  [_shaarProfiles removeAllObjects];
  _symbols.release(_shaarEngine);
  _shaarEngine = nullptr;
  return result == SHAAR_OK ? 0 : 1;
}

- (void)receiveEvent:(const shaar_event *)event {
  if (!event) return;
  NSData *data = [NSData dataWithBytes:event->payload_json.data ?: ""
                                length:event->payload_json.size];
  NSDictionary *payload = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
  if (![payload isKindOfClass:NSDictionary.class]) return;
  NSString *kind = payload[@"kind"];
  if (event->kind == SHAAR_EVENT_ENGINE && [kind isEqualToString:@"engine.ready"]) {
    if (_shaarTesting) [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
    if (self.onReady) self.onReady();
    return;
  }
  if (event->kind == SHAAR_EVENT_ENGINE && [kind isEqualToString:@"engine.quitCancelled"]) {
    _shaarQuitting = NO;
    if (self.onQuitCancelled) self.onQuitCancelled();
  }
}

- (void)loadProfileID:(NSString *)profileID completion:(void (^)(NSError *))completion {
  if (_shaarProfiles[profileID]) {
    completion(nil);
    return;
  }
  NSString *canonicalID = profileID.lowercaseString;
  NSString *directory = [@"Profile " stringByAppendingString:canonicalID];
  __weak ARCShaarRuntime *weakSelf = self;
  void (^reply)(NSError *) = ^(NSError *failure) {
    if (failure) [weakSelf removeFailedProfileID:profileID];
    completion(failure);
  };
  void *context = (__bridge_retained void *)reply;
  shaar_profile *profile = nullptr;
  shaar_error error = EmptyError();
  shaar_error_code status = _symbols.profile_open(
      _shaarEngine, Bytes(canonicalID), Bytes(directory), 1, _nextRequestID++,
      [](void *context, const shaar_result *result) {
        void (^finish)(NSError *) = (__bridge_transfer id)context;
        finish(result && result->error.code == SHAAR_OK ? nil :
               ShaarError(@"Shaar could not load the profile."));
      }, context, &profile, &error);
  if (status != SHAAR_OK) {
    CFBridgingRelease(context);
    completion(ShaarError(@"Shaar could not open the profile."));
    return;
  }
  _shaarProfiles[profileID] = [NSValue valueWithPointer:profile];
}

- (void)removeFailedProfileID:(NSString *)profileID {
  [_shaarProfiles removeObjectForKey:profileID];
}

- (NSString *)primaryWindowID { return _shaarPrimaryWindowID; }
- (BOOL)isQuitting { return _shaarQuitting; }
- (NSString *)chromiumVersion { return @"155.0.8059.84"; }

- (void)quit {
  if (!_shaarEngine) return;
  _shaarQuitting = YES;
  shaar_error error = EmptyError();
  _symbols.request_quit(_shaarEngine, &error);
}

- (void)dealloc {
  if (_shaarLibrary) dlclose(_shaarLibrary);
}

@end
