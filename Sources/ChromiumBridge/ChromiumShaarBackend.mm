// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#import "include/ChromiumBridge.h"
#import "ChromiumShaarExtensionsInternal.h"

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

NSString *String(shaar_bytes bytes) {
  if (!bytes.data || !bytes.size) return @"";
  return [[NSString alloc] initWithBytes:bytes.data length:bytes.size
                               encoding:NSUTF8StringEncoding] ?: @"";
}

shaar_error EmptyError() {
  shaar_error error = {};
  error.size = sizeof(error);
  return error;
}

void IgnoreReply(void *, const shaar_result *) {}

struct Symbols {
  decltype(&shaar_engine_create) create = nullptr;
  decltype(&shaar_engine_run) run = nullptr;
  decltype(&shaar_engine_request_quit) request_quit = nullptr;
  decltype(&shaar_engine_release) release = nullptr;
  decltype(&shaar_profile_open) profile_open = nullptr;
  decltype(&shaar_window_open) window_open = nullptr;
  decltype(&shaar_window_close) window_close = nullptr;
  decltype(&shaar_window_host_view) window_host_view = nullptr;
  decltype(&shaar_window_host_resize) window_host_resize = nullptr;
  decltype(&shaar_window_native_window) window_native_window = nullptr;
  decltype(&shaar_tab_open) tab_open = nullptr;
  decltype(&shaar_tab_close) tab_close = nullptr;
  decltype(&shaar_tab_host_view) tab_host_view = nullptr;
  decltype(&shaar_tab_view_attach) tab_view_attach = nullptr;
  decltype(&shaar_tab_view_detach) tab_view_detach = nullptr;
  decltype(&shaar_tab_view_focus) tab_view_focus = nullptr;
  decltype(&shaar_submit) submit = nullptr;

  bool Load(void *library) {
#define SHAAR_LOAD(field, symbol) \
  field = reinterpret_cast<decltype(field)>(dlsym(library, "shaar_" #symbol))
    SHAAR_LOAD(create, engine_create);
    SHAAR_LOAD(run, engine_run);
    SHAAR_LOAD(request_quit, engine_request_quit);
    SHAAR_LOAD(release, engine_release);
    SHAAR_LOAD(profile_open, profile_open);
    SHAAR_LOAD(window_open, window_open);
    SHAAR_LOAD(window_close, window_close);
    SHAAR_LOAD(window_host_view, window_host_view);
    SHAAR_LOAD(window_host_resize, window_host_resize);
    SHAAR_LOAD(window_native_window, window_native_window);
    SHAAR_LOAD(tab_open, tab_open);
    SHAAR_LOAD(tab_close, tab_close);
    SHAAR_LOAD(tab_host_view, tab_host_view);
    SHAAR_LOAD(tab_view_attach, tab_view_attach);
    SHAAR_LOAD(tab_view_detach, tab_view_detach);
    SHAAR_LOAD(tab_view_focus, tab_view_focus);
    SHAAR_LOAD(submit, submit);
#undef SHAAR_LOAD
    return create && run && request_quit && release && profile_open &&
           window_open && window_close && window_host_view && window_host_resize &&
           window_native_window && tab_open && tab_close && tab_host_view &&
           tab_view_attach && tab_view_detach && tab_view_focus && submit;
  }
};

}  // namespace

@interface ARCShaarRuntime () {
  void *_shaarLibrary;
  shaar_engine *_shaarEngine;
  Symbols _symbols;
  NSString *_shaarPrimaryWindowID;
  NSMutableDictionary<NSString *, NSValue *> *_shaarProfiles;
  NSMutableDictionary<NSString *, NSValue *> *_shaarWindows;
  NSMutableDictionary<NSString *, NSValue *> *_shaarTabs;
  NSMutableDictionary<NSString *, NSString *> *_shaarTabWindows;
  NSMutableDictionary<NSString *, NSString *> *_shaarTabProfiles;
  NSMutableDictionary<NSString *, NSString *> *_shaarSelectedTabs;
  NSMutableDictionary<NSString *, id> *_hostResizeObservers;
  NSMutableDictionary<NSString *, NSValue *> *_hostSizes;
  uint64_t _nextRequestID;
  BOOL _shaarQuitting;
  BOOL _shaarTesting;
}
- (void)receiveEvent:(const shaar_event *)event;
- (BOOL)submitTabID:(NSString *)tabID operation:(shaar_operation)operation
            payload:(NSDictionary *)payload;
- (BOOL)submitWindowID:(NSString *)windowID profileID:(NSString *)profileID
             operation:(shaar_operation)operation payload:(NSDictionary *)payload;
- (void)removeFailedProfileID:(NSString *)profileID;
- (void)finishWindowID:(NSString *)windowID;
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
  _shaarWindows = [NSMutableDictionary dictionary];
  _shaarTabs = [NSMutableDictionary dictionary];
  _shaarTabWindows = [NSMutableDictionary dictionary];
  _shaarTabProfiles = [NSMutableDictionary dictionary];
  _shaarSelectedTabs = [NSMutableDictionary dictionary];
  _hostResizeObservers = [NSMutableDictionary dictionary];
  _hostSizes = [NSMutableDictionary dictionary];
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
  for (id observer in _hostResizeObservers.allValues)
    [NSNotificationCenter.defaultCenter removeObserver:observer];
  [_hostResizeObservers removeAllObjects];
  [_hostSizes removeAllObjects];
  [_shaarWindows removeAllObjects];
  [_shaarTabs removeAllObjects];
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
  [self shaarExtensionEvent:event payload:payload];
  NSString *kind = payload[@"kind"];
  if (event->kind == SHAAR_EVENT_ENGINE && [kind isEqualToString:@"engine.ready"]) {
    if (_shaarTesting) [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
    NSError *error = nil;
    if (![self createWindowID:_shaarPrimaryWindowID error:&error]) {
      if (self.onNotice) self.onNotice(error.localizedDescription);
      [self quit];
      return;
    }
    if (self.onReady) self.onReady();
    return;
  }
  if (event->kind == SHAAR_EVENT_ENGINE && [kind isEqualToString:@"engine.quitCancelled"]) {
    _shaarQuitting = NO;
    if (self.onQuitCancelled) self.onQuitCancelled();
    return;
  }
  NSString *tabID = String(event->tab_id);
  if (event->kind == SHAAR_EVENT_WINDOW && [kind isEqualToString:@"closed"]) {
    [self finishWindowID:String(event->window_id)];
    return;
  }
  if (event->kind == SHAAR_EVENT_TAB && [kind isEqualToString:@"closed"]) {
    NSString *windowID = _shaarTabWindows[tabID];
    if (windowID && [_shaarSelectedTabs[windowID] isEqualToString:tabID])
      [_shaarSelectedTabs removeObjectForKey:windowID];
    [_shaarTabs removeObjectForKey:tabID];
    [_shaarTabWindows removeObjectForKey:tabID];
    [_shaarTabProfiles removeObjectForKey:tabID];
    if (self.onTabClosed) self.onTabClosed(tabID);
    return;
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
- (NSWindow *)window { return [self windowForID:_shaarPrimaryWindowID]; }
- (NSView *)hostView { return [self hostViewForWindowID:_shaarPrimaryWindowID]; }

- (BOOL)createWindowID:(NSString *)windowID error:(NSError **)error {
  if (!_shaarEngine || _shaarWindows[windowID]) return NO;
  shaar_window *window = nullptr;
  shaar_error nativeError = EmptyError();
  const shaar_error_code status = _symbols.window_open(
      _shaarEngine, SHAAR_WINDOW_REGULAR, nullptr, Bytes(windowID), &window,
      &nativeError);
  if (status != SHAAR_OK) {
    if (error) *error = ShaarError(@"Shaar could not open the window.");
    return NO;
  }
  _shaarWindows[windowID] = [NSValue valueWithPointer:window];
  return YES;
}

- (BOOL)closeWindowID:(NSString *)windowID {
  shaar_window *window = (shaar_window *)_shaarWindows[windowID].pointerValue;
  if (!window) return NO;
  shaar_error error = EmptyError();
  if (_symbols.window_close(window, &error) != SHAAR_OK) return NO;
  if (!_symbols.window_host_view(window)) [self finishWindowID:windowID];
  return YES;
}

- (void)finishWindowID:(NSString *)windowID {
  if (!_shaarWindows[windowID]) return;
  id observer = _hostResizeObservers[windowID];
  if (observer) [NSNotificationCenter.defaultCenter removeObserver:observer];
  [_hostResizeObservers removeObjectForKey:windowID];
  [_hostSizes removeObjectForKey:windowID];
  [_shaarSelectedTabs removeObjectForKey:windowID];
  [_shaarWindows removeObjectForKey:windowID];
  if (self.onWindowClosed) self.onWindowClosed(windowID, _shaarQuitting);
}

- (NSWindow *)windowForID:(NSString *)windowID {
  shaar_window *window = (shaar_window *)_shaarWindows[windowID].pointerValue;
  return window ? (__bridge NSWindow *)_symbols.window_native_window(window) : nil;
}

- (NSView *)hostViewForWindowID:(NSString *)windowID {
  shaar_window *window = (shaar_window *)_shaarWindows[windowID].pointerValue;
  if (!window) return nil;
  NSView *view = (__bridge NSView *)_symbols.window_host_view(window);
  if (!view || _hostResizeObservers[windowID]) return view;
  view.postsFrameChangedNotifications = YES;
  __weak ARCShaarRuntime *weakSelf = self;
  _hostResizeObservers[windowID] = [NSNotificationCenter.defaultCenter
      addObserverForName:NSViewFrameDidChangeNotification object:view
                   queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *notification) {
    ARCShaarRuntime *owner = weakSelf;
    if (!owner) return;
    shaar_window *current = (shaar_window *)owner->_shaarWindows[windowID].pointerValue;
    if (!current || !owner->_shaarEngine) return;
    NSSize size = [(NSView *)notification.object bounds].size;
    NSValue *last = owner->_hostSizes[windowID];
    if (last && NSEqualSizes(last.sizeValue, size)) return;
    owner->_hostSizes[windowID] = [NSValue valueWithSize:size];
    shaar_error error = EmptyError();
    owner->_symbols.window_host_resize(owner->_shaarEngine, current,
                                        size.width, size.height, &error);
  }];
  return view;
}

- (NSString *)windowIDForTabID:(NSString *)tabID { return _shaarTabWindows[tabID]; }

- (BOOL)openTabID:(NSString *)tabID profileID:(NSString *)profileID windowID:(NSString *)windowID
               url:(NSString *)url error:(NSError **)error {
  shaar_window *window = (shaar_window *)_shaarWindows[windowID].pointerValue;
  shaar_profile *profile = (shaar_profile *)_shaarProfiles[profileID].pointerValue;
  if (!window || !profile || _shaarTabs[tabID]) {
    if (error) *error = ShaarError(@"Shaar tab scope is unavailable.");
    return NO;
  }
  shaar_scope scope = {};
  scope.size = sizeof(scope);
  scope.profile = profile;
  shaar_tab *tab = nullptr;
  shaar_error nativeError = EmptyError();
  const shaar_error_code status = _symbols.tab_open(
      scope, window, Bytes(tabID), Bytes(url), 0, &tab, &nativeError);
  if (status != SHAAR_OK) {
    if (error) *error = ShaarError(@"Shaar could not open the tab.");
    return NO;
  }
  _shaarTabs[tabID] = [NSValue valueWithPointer:tab];
  _shaarTabWindows[tabID] = windowID;
  _shaarTabProfiles[tabID] = profileID;
  if (self.onTabChanged) self.onTabChanged(tabID, url, @"", url.length > 0, NO, NO);
  return YES;
}

- (BOOL)openTabID:(NSString *)tabID profileID:(NSString *)profileID url:(NSString *)url
              error:(NSError **)error {
  return [self openTabID:tabID profileID:profileID windowID:_shaarPrimaryWindowID
                    url:url error:error];
}

- (NSView *)viewForTabID:(NSString *)tabID {
  shaar_tab *tab = (shaar_tab *)_shaarTabs[tabID].pointerValue;
  return tab ? (__bridge NSView *)_symbols.tab_host_view(tab) : nil;
}

- (void)activateTabID:(NSString *)tabID {
  NSString *windowID = _shaarTabWindows[tabID];
  shaar_window *window = (shaar_window *)_shaarWindows[windowID].pointerValue;
  shaar_tab *tab = (shaar_tab *)_shaarTabs[tabID].pointerValue;
  if (!window || !tab) return;
  shaar_error error = EmptyError();
  if (_symbols.tab_view_attach(_shaarEngine, window, tab, &error) != SHAAR_OK) return;
  _shaarSelectedTabs[windowID] = tabID;
  // Navigation can notify Swift while Chromium is still editing its tab strip.
  // Activate after that edit finishes to avoid reentering TabStripModel.
  __weak ARCShaarRuntime *weakSelf = self;
  dispatch_async(dispatch_get_main_queue(), ^{
    ARCShaarRuntime *owner = weakSelf;
    if (!owner || !owner->_shaarEngine || !owner->_shaarTabs[tabID] ||
        ![owner->_shaarSelectedTabs[windowID] isEqualToString:tabID]) return;
    if (![owner submitTabID:tabID operation:SHAAR_OP_WINDOW_ACTIVATE_TAB
                    payload:@{@"schemaVersion": @1, @"tabID": tabID}]) return;
    if (owner.onTabActivated)
      owner.onTabActivated(tabID, owner->_shaarTabProfiles[tabID]);
  });
}

- (void)focusTabID:(NSString *)tabID {
  NSString *windowID = _shaarTabWindows[tabID];
  shaar_window *window = (shaar_window *)_shaarWindows[windowID].pointerValue;
  shaar_tab *tab = (shaar_tab *)_shaarTabs[tabID].pointerValue;
  if (!window || !tab) return;
  shaar_error error = EmptyError();
  _symbols.tab_view_focus(_shaarEngine, window, tab, &error);
}

- (void)clearActiveTabInWindowID:(NSString *)windowID {
  NSString *tabID = _shaarSelectedTabs[windowID];
  shaar_window *window = (shaar_window *)_shaarWindows[windowID].pointerValue;
  shaar_tab *tab = (shaar_tab *)_shaarTabs[tabID].pointerValue;
  if (window && tab) {
    shaar_error error = EmptyError();
    _symbols.tab_view_detach(_shaarEngine, window, tab, &error);
  }
  [_shaarSelectedTabs removeObjectForKey:windowID];
}

- (void)clearActiveTab { [self clearActiveTabInWindowID:_shaarPrimaryWindowID]; }
- (void)activateProfileID:(NSString *)profileID {
  [self activateProfileID:profileID windowID:_shaarPrimaryWindowID];
}
- (void)activateProfileID:(NSString *)profileID windowID:(NSString *)windowID {
  [self submitWindowID:windowID profileID:profileID
             operation:SHAAR_OP_WINDOW_SET_ACTIVE_PROFILE
               payload:@{@"schemaVersion": @1,
                         @"profileID": profileID.lowercaseString}];
}

- (BOOL)placeTabIDs:(NSArray<NSString *> *)tabIDs pinnedIDs:(NSArray<NSString *> *)pinnedIDs
          profileID:(NSString *)profileID windowID:(NSString *)windowID {
  return [self submitWindowID:windowID profileID:profileID
                   operation:SHAAR_OP_WINDOW_PLACE_TABS
                     payload:@{@"schemaVersion": @1, @"tabIDs": tabIDs,
                               @"pinnedIDs": pinnedIDs}];
}

- (BOOL)placeTabIDs:(NSArray<NSString *> *)tabIDs pinnedIDs:(NSArray<NSString *> *)pinnedIDs
          profileID:(NSString *)profileID {
  return [self placeTabIDs:tabIDs pinnedIDs:pinnedIDs profileID:profileID
                 windowID:_shaarPrimaryWindowID];
}

- (void)closeTabID:(NSString *)tabID {
  shaar_tab *tab = (shaar_tab *)_shaarTabs[tabID].pointerValue;
  if (!tab) return;
  shaar_error error = EmptyError();
  _symbols.tab_close(tab, &error);
}

- (void)discardTabID:(NSString *)tabID { [self closeTabID:tabID]; }

- (BOOL)submitTabID:(NSString *)tabID operation:(shaar_operation)operation
            payload:(NSDictionary *)payload {
  NSString *windowID = _shaarTabWindows[tabID];
  shaar_window *window = (shaar_window *)_shaarWindows[windowID].pointerValue;
  shaar_tab *tab = (shaar_tab *)_shaarTabs[tabID].pointerValue;
  shaar_profile *profile = (shaar_profile *)_shaarProfiles[_shaarTabProfiles[tabID]].pointerValue;
  if (!window || !tab || !profile) return NO;
  NSData *json = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
  if (!json) return NO;
  shaar_scope scope = {};
  scope.size = sizeof(scope);
  scope.profile = profile;
  shaar_error error = EmptyError();
  return _symbols.submit(_shaarEngine, scope, window, tab, operation,
                         {(const char *)json.bytes, json.length}, _nextRequestID++,
                         IgnoreReply, nullptr, &error) == SHAAR_OK;
}

- (BOOL)submitWindowID:(NSString *)windowID profileID:(NSString *)profileID
             operation:(shaar_operation)operation payload:(NSDictionary *)payload {
  shaar_window *window = (shaar_window *)_shaarWindows[windowID].pointerValue;
  shaar_profile *profile = (shaar_profile *)_shaarProfiles[profileID].pointerValue;
  if (!window || !profile) return NO;
  NSData *json = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
  if (!json) return NO;
  shaar_scope scope = {};
  scope.size = sizeof(scope);
  scope.profile = profile;
  shaar_error error = EmptyError();
  return _symbols.submit(_shaarEngine, scope, window, nullptr, operation,
                         {(const char *)json.bytes, json.length}, _nextRequestID++,
                         IgnoreReply, nullptr, &error) == SHAAR_OK;
}

- (BOOL)shaarSubmitExtensionOperation:(shaar_operation)operation
                           profileID:(NSString *)profileID tabID:(NSString *)tabID
                             payload:(NSDictionary *)payload
                          completion:(void (^)(NSString *, shaar_error_code))completion {
  shaar_profile *profile = (shaar_profile *)_shaarProfiles[profileID].pointerValue;
  NSString *windowID = tabID ? _shaarTabWindows[tabID] : _shaarPrimaryWindowID;
  shaar_window *window = (shaar_window *)_shaarWindows[windowID].pointerValue;
  shaar_tab *tab = tabID ? (shaar_tab *)_shaarTabs[tabID].pointerValue : nullptr;
  if (!_shaarEngine || !profile || !window || (tabID && (!tab ||
      ![_shaarTabProfiles[tabID] isEqualToString:profileID]))) return NO;
  NSData *json = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
  if (!json) return NO;
  shaar_scope scope = {};
  scope.size = sizeof(scope);
  scope.profile = profile;
  void *context = (__bridge_retained void *)[completion copy];
  shaar_error error = EmptyError();
  shaar_error_code status = _symbols.submit(
      _shaarEngine, scope, window, tab, operation,
      {(const char *)json.bytes, json.length}, _nextRequestID++,
      [](void *context, const shaar_result *result) {
        void (^reply)(NSString *, shaar_error_code) = (__bridge_transfer id)context;
        NSString *json = result ? String(result->payload_json) : nil;
        reply(json, result ? result->error.code : SHAAR_CHROMIUM_ERROR);
      }, context, &error);
  if (status != SHAAR_OK) {
    CFBridgingRelease(context);
    return NO;
  }
  return YES;
}

- (BOOL)shaarOwnsSelectedTabID:(NSString *)tabID profileID:(NSString *)profileID {
  NSString *windowID = _shaarTabWindows[tabID];
  return windowID && [_shaarTabProfiles[tabID] isEqualToString:profileID] &&
         [_shaarSelectedTabs[windowID] isEqualToString:tabID];
}

- (NSString *)shaarProfileIDForTabID:(NSString *)tabID {
  return _shaarTabProfiles[tabID];
}

- (NSString *)shaarProfileIDForWindowID:(NSString *)windowID {
  NSString *selectedTabID = _shaarSelectedTabs[windowID];
  return _shaarTabProfiles[selectedTabID];
}

- (NSURL *)shaarProfileDirectoryForID:(NSString *)profileID {
  shaar_profile *profile = (shaar_profile *)_shaarProfiles[profileID].pointerValue;
  if (!profile) return nil;
  auto getPath = reinterpret_cast<decltype(&shaar_profile_get_path)>(
      dlsym(_shaarLibrary, "shaar_profile_get_path"));
  if (!getPath) return nil;
  shaar_bytes path = {};
  shaar_error error = EmptyError();
  if (getPath(profile, &path, &error) != SHAAR_OK) return nil;
  NSString *value = String(path);
  return value.length ? [NSURL fileURLWithPath:value isDirectory:YES] : nil;
}

- (void)quit {
  if (!_shaarEngine) return;
  _shaarQuitting = YES;
  shaar_error error = EmptyError();
  _symbols.request_quit(_shaarEngine, &error);
}

- (void)dealloc {
  for (id observer in _hostResizeObservers.allValues)
    [NSNotificationCenter.defaultCenter removeObserver:observer];
  if (_shaarLibrary) dlclose(_shaarLibrary);
}

@end
