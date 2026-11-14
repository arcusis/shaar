// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Included by ChromiumShaarBackend.mm so feature operations use its owned ABI
// handles and symbol table without duplicating engine state.
#import "ChromiumShaarFeatureTransport.h"

@implementation ARCShaarRuntime (FeatureTransport)

- (BOOL)shaarHasProfileID:(NSString *)profileID {
  return _shaarEngine && _shaarProfiles[profileID] != nil;
}

- (NSString *)shaarProfileIDForTabID:(NSString *)tabID {
  return _shaarEngine && _shaarTabs[tabID] ? _shaarTabProfiles[tabID] : nil;
}

- (NSString *)shaarProfileIDForNativeID:(NSString *)nativeID {
  for (NSString *profileID in _shaarProfiles)
    if ([profileID caseInsensitiveCompare:nativeID] == NSOrderedSame) return profileID;
  return nil;
}

- (BOOL)shaarHasTabID:(NSString *)tabID profileID:(NSString *)profileID selected:(BOOL)selected {
  NSString *windowID = _shaarTabWindows[tabID];
  if (!_shaarEngine || !_shaarTabs[tabID] || !_shaarWindows[windowID] ||
      ![_shaarTabProfiles[tabID] isEqualToString:profileID]) return NO;
  return !selected || [_shaarSelectedTabs[windowID] isEqualToString:tabID];
}

- (BOOL)shaarSubmit:(shaar_operation)operation profileID:(NSString *)profileID
              tabID:(NSString *)tabID payload:(NSDictionary *)payload
         completion:(void (^)(NSDictionary *, NSError *))completion {
  shaar_profile *profile = (shaar_profile *)_shaarProfiles[profileID].pointerValue;
  NSString *windowID = tabID ? _shaarTabWindows[tabID] : nil;
  shaar_window *window = (shaar_window *)_shaarWindows[windowID].pointerValue;
  shaar_tab *tab = (shaar_tab *)_shaarTabs[tabID].pointerValue;
  NSData *json = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
  if (!_shaarEngine || !profile || (tabID && (!window || !tab ||
      ![_shaarTabProfiles[tabID] isEqualToString:profileID])) || !json) {
    if (completion) completion(nil, ShaarError(@"Shaar feature scope is unavailable."));
    return NO;
  }
  shaar_scope scope = {};
  scope.size = sizeof(scope);
  scope.profile = profile;
  shaar_error error = EmptyError();
  void (^reply)(NSDictionary *, NSError *) = [completion copy];
  void *context = reply ? (__bridge_retained void *)reply : nullptr;
  shaar_error_code status = _symbols.submit(
      _shaarEngine, scope, window, tab, operation,
      {(const char *)json.bytes, json.length}, _nextRequestID++,
      [](void *context, const shaar_result *result) {
        if (!context) return;
        void (^finish)(NSDictionary *, NSError *) = (__bridge_transfer id)context;
        if (!result) {
          finish(nil, ShaarError(@"Shaar feature operation failed."));
          return;
        }
        if (result->size < sizeof(*result) ||
            result->error.size < sizeof(result->error)) {
          finish(nil, ShaarError(@"Shaar feature operation returned an invalid result."));
          return;
        }
        if (result->error.code != SHAAR_OK) {
          finish(nil, ShaarError(@"Shaar feature operation failed."));
          return;
        }
        NSData *data = [NSData dataWithBytes:result->payload_json.data ?: ""
                                      length:result->payload_json.size];
        id value = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        finish([value isKindOfClass:NSDictionary.class] ? value : @{}, nil);
      }, context, &error);
  if (status == SHAAR_OK) return YES;
  if (context) CFBridgingRelease(context);
  if (_shaarTesting) {
    fprintf(stderr, "Shaar feature submit rejected: operation=%d status=%d native=%d\n",
            (int)operation, (int)status, (int)error.code);
  }
  if (completion) completion(nil, ShaarStatusError(@"Shaar rejected the feature operation.", status));
  return NO;
}

- (BOOL)shaarDeleteProfileID:(NSString *)profileID {
  shaar_profile *profile = (shaar_profile *)_shaarProfiles[profileID].pointerValue;
  if (!profile || !_shaarEngine) return NO;
  for (NSString *owner in _shaarTabProfiles.allValues)
    if ([owner isEqualToString:profileID]) return NO;
  auto remove = (decltype(&shaar_profile_delete))dlsym(_shaarLibrary, "shaar_profile_delete");
  shaar_error error = EmptyError();
  if (!remove || remove(profile, &error) != SHAAR_OK) return NO;
  [_shaarProfiles removeObjectForKey:profileID];
  return YES;
}

- (NSWindow *)shaarPictureInPictureWindowForTabID:(NSString *)tabID {
  shaar_tab *tab = (shaar_tab *)_shaarTabs[tabID].pointerValue;
  shaar_profile *profile = (shaar_profile *)_shaarProfiles[_shaarTabProfiles[tabID]].pointerValue;
  auto lookup = (decltype(&shaar_media_pip_window))dlsym(_shaarLibrary, "shaar_media_pip_window");
  if (!tab || !profile || !lookup) return nil;
  shaar_scope scope = {};
  scope.size = sizeof(scope);
  scope.profile = profile;
  shaar_window *window = nullptr;
  shaar_error error = EmptyError();
  if (lookup(scope, tab, &window, &error) != SHAAR_OK || !window) return nil;
  return (__bridge NSWindow *)_symbols.window_native_window(window);
}

- (NSDictionary *)shaarSecurityInfoForTabID:(NSString *)tabID profileID:(NSString *)profileID {
  if (![self shaarHasTabID:tabID profileID:profileID selected:YES]) return nil;
  NSString *windowID = _shaarTabWindows[tabID];
  shaar_window *window = (shaar_window *)_shaarWindows[windowID].pointerValue;
  shaar_tab *tab = (shaar_tab *)_shaarTabs[tabID].pointerValue;
  shaar_profile *profile = (shaar_profile *)_shaarProfiles[profileID].pointerValue;
  auto inspect = (decltype(&shaar_site_security_info))dlsym(_shaarLibrary, "shaar_site_security_info");
  if (!inspect || !window || !tab || !profile) return nil;
  shaar_scope scope = {};
  scope.size = sizeof(scope);
  scope.profile = profile;
  shaar_bytes response = {};
  shaar_error error = EmptyError();
  if (inspect(_shaarEngine, scope, window, tab, &response, &error) != SHAAR_OK || !response.data)
    return nil;
  NSData *data = [NSData dataWithBytes:response.data length:response.size];
  id value = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
  return [value isKindOfClass:NSDictionary.class] ? value : nil;
}

@end
