// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#import "ChromiumShaarPrivateSupport.h"

#import <objc/runtime.h>

#include <atomic>
#include <dlfcn.h>
#include <cstring>

namespace {
char kPrivateStateKey;
std::atomic<uint64_t> kPrivateRequestID{1ULL << 62};

void Reply(void *context, const shaar_result *result) {
  void (^finish)(NSDictionary *) = (__bridge_transfer id)context;
  if (!result) {
    finish(@{@"error": @"Shaar private operation failed."});
    return;
  }
  if (result->size < sizeof(*result) ||
      result->error.size < sizeof(result->error)) {
    finish(@{@"error": @"Shaar private operation returned an invalid result."});
    return;
  }
  if (result->error.code != SHAAR_OK) {
    finish(@{@"error": @"Shaar private operation failed."});
    return;
  }
  NSData *data = [NSData dataWithBytes:result->payload_json.data ?: ""
                                length:result->payload_json.size];
  NSDictionary *payload = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
  finish([payload isKindOfClass:NSDictionary.class] ? payload : @{@"ok": @YES});
}
}  // namespace

NSMutableDictionary *ARCPrivateShaarState(ARCShaarRuntime *runtime) {
  NSMutableDictionary *state = objc_getAssociatedObject(runtime, &kPrivateStateKey);
  if (state) return state;
  state = [@{@"contexts": [NSMutableDictionary dictionary],
             @"windows": [NSMutableDictionary dictionary],
             @"tabs": [NSMutableDictionary dictionary],
             @"retired": [NSMutableSet set]} mutableCopy];
  objc_setAssociatedObject(runtime, &kPrivateStateKey, state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  return state;
}

shaar_bytes ARCPrivateShaarBytes(NSString *value) {
  const char *text = value.UTF8String;
  return {text, text ? std::strlen(text) : 0};
}

shaar_error ARCPrivateShaarEmptyError(void) {
  shaar_error error = {};
  error.size = sizeof(error);
  return error;
}

BOOL ARCPrivateShaarSubmit(ARCShaarRuntime *runtime, shaar_scope scope,
                           shaar_window *window, shaar_tab *tab,
                           shaar_operation operation, NSDictionary *payload,
                           void (^completion)(NSDictionary *reply)) {
  auto engine = [runtime privateEngineHandle];
  auto submit = reinterpret_cast<decltype(&shaar_submit)>(dlsym(RTLD_DEFAULT, "shaar_submit"));
  if (!engine || !submit || !completion) return NO;
  NSData *json = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
  if (!json) return NO;
  void *context = (__bridge_retained void *)[completion copy];
  shaar_error error = ARCPrivateShaarEmptyError();
  const uint64_t requestID = operation == SHAAR_OP_DEVTOOLS_CALL
      ? [runtime nextPrivateDevToolsRequestID] : kPrivateRequestID.fetch_add(1);
  shaar_error_code code = submit(engine, scope, window, tab, operation,
                                 {(const char *)json.bytes, json.length},
                                 requestID, Reply, context, &error);
  if (code == SHAAR_OK) return YES;
  CFBridgingRelease(context);
  return NO;
}
