// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#import "include/ChromiumBridge.h"
#import "ChromiumRuntimeInternal.h"
#import "ChromiumLocalState.h"
#import "ChromiumShaarExtensionsInternal.h"
#import "ChromiumShaarPrivateSupport.h"
#import "ChromiumShaarFeatureTransport.h"
#import "ChromiumMediaSession.h"
#import "ChromiumShaarActivation.h"

#include <dlfcn.h>
#include <cstdlib>
#include <cstring>

#include "../../ThirdParty/ChromiumEngine/layer/chrome/browser/shaar/public/shaar_engine.h"

// Optional for older engine builds that do not emit tab "opened" events.
extern "C" shaar_error_code shaar_tab_find(
    shaar_engine *engine, shaar_bytes window_id, shaar_bytes tab_id,
    shaar_tab **out, shaar_error *error);

namespace {

NSError *ShaarError(NSString *message) {
  return [NSError errorWithDomain:@"org.arcusis.shaar.engine" code:1
                         userInfo:@{NSLocalizedDescriptionKey: message}];
}

NSError *ShaarStatusError(NSString *message, shaar_error_code status) {
  return [NSError errorWithDomain:@"org.arcusis.shaar.engine" code:status
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
  decltype(&shaar_abi_minor) abi_minor = nullptr;
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
  decltype(&shaar_tab_find) tab_find = nullptr;
  decltype(&shaar_tab_close) tab_close = nullptr;
  decltype(&shaar_tab_favicon_png) tab_favicon_png = nullptr;
  decltype(&shaar_tab_host_view) tab_host_view = nullptr;
  decltype(&shaar_tab_view_attach) tab_view_attach = nullptr;
  decltype(&shaar_tab_view_detach) tab_view_detach = nullptr;
  decltype(&shaar_tab_view_focus) tab_view_focus = nullptr;
  decltype(&shaar_submit) submit = nullptr;

  bool Load(void *library) {
#define SHAAR_LOAD(field, symbol) \
  field = reinterpret_cast<decltype(field)>(dlsym(library, "shaar_" #symbol))
    SHAAR_LOAD(abi_minor, abi_minor);
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
    SHAAR_LOAD(tab_favicon_png, tab_favicon_png);
    SHAAR_LOAD(tab_host_view, tab_host_view);
    SHAAR_LOAD(tab_view_attach, tab_view_attach);
    SHAAR_LOAD(tab_view_detach, tab_view_detach);
    SHAAR_LOAD(tab_view_focus, tab_view_focus);
    SHAAR_LOAD(submit, submit);
#undef SHAAR_LOAD
    return abi_minor && create && run && request_quit && release && profile_open &&
           window_open && window_close && window_host_view && window_host_resize &&
           window_native_window && tab_open && tab_close && tab_favicon_png && tab_host_view &&
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
  NSMutableDictionary<NSString *, NSMutableArray *> *_shaarProfileWaiters;
  NSMutableDictionary<NSString *, NSValue *> *_shaarWindows;
  NSMutableDictionary<NSString *, NSValue *> *_shaarTabs;
  NSMutableDictionary<NSString *, NSString *> *_shaarTabWindows;
  NSMutableDictionary<NSString *, NSString *> *_shaarTabProfiles;
  NSMutableDictionary<NSString *, NSString *> *_shaarSelectedTabs;
  NSMutableDictionary<NSString *, id> *_hostResizeObservers;
  NSMutableDictionary<NSString *, id> *_hostCloseObservers;
  NSMutableDictionary<NSString *, NSValue *> *_hostSizes;
  NSMutableDictionary<NSString *, NSString *> *_shaarFindTokens;
  NSMutableDictionary<NSString *, NSString *> *_shaarFindRequests;
  NSMutableDictionary<NSString *, NSString *> *_shaarMediaRequests;
  uint64_t _nextRequestID;
  BOOL _shaarQuitting;
  BOOL _shaarTesting;
  BOOL _shaarMediaConsentAvailable;
  NSString *_shaarStartupNotice;
}
- (void)receiveEvent:(const shaar_event *)event;
- (void)adoptOpenedTabFromEvent:(const shaar_event *)event
                        payload:(NSDictionary *)payload
                      profileID:(NSString *)profileID;
- (BOOL)submitTabID:(NSString *)tabID operation:(shaar_operation)operation
            payload:(NSDictionary *)payload;
- (BOOL)submitWindowID:(NSString *)windowID profileID:(NSString *)profileID
             operation:(shaar_operation)operation payload:(NSDictionary *)payload;
- (void)finishProfileLoadID:(NSString *)profileID error:(NSError *)error;
- (void)finishWindowID:(NSString *)windowID;
- (void)submitProfileID:(NSString *)profileID operation:(shaar_operation)operation
                payload:(NSDictionary *)payload
             completion:(void (^)(NSDictionary *, NSError *))completion;
@end

#include "ChromiumShaarFeatureTransport.inc"

static void ShaarEventCallback(void *context, const shaar_event *event) {
  ARCPerformShaarEventCallback(^{
    [(__bridge ARCShaarRuntime *)context receiveEvent:event];
  });
}

@implementation ARCShaarRuntime

- (NSString *)startupNotice { return _shaarStartupNotice; }

- (instancetype)initWithFrameworkURL:(NSURL *)url error:(NSError **)error {
  if (!(self = [super init])) return nil;
  self.languageIdentifier = @"en";
  _shaarPrimaryWindowID = NSUUID.UUID.UUIDString;
  _shaarProfiles = [NSMutableDictionary dictionary];
  _shaarProfileWaiters = [NSMutableDictionary dictionary];
  _shaarWindows = [NSMutableDictionary dictionary];
  _shaarTabs = [NSMutableDictionary dictionary];
  _shaarTabWindows = [NSMutableDictionary dictionary];
  _shaarTabProfiles = [NSMutableDictionary dictionary];
  _shaarSelectedTabs = [NSMutableDictionary dictionary];
  _hostResizeObservers = [NSMutableDictionary dictionary];
  _hostCloseObservers = [NSMutableDictionary dictionary];
  _hostSizes = [NSMutableDictionary dictionary];
  _shaarFindTokens = [NSMutableDictionary dictionary];
  _shaarFindRequests = [NSMutableDictionary dictionary];
  _shaarMediaRequests = [NSMutableDictionary dictionary];
  _nextRequestID = 1;
  NSURL *binary = [url URLByAppendingPathComponent:@"Versions/Current/Chromium Framework"];
  _shaarLibrary = dlopen(binary.fileSystemRepresentation, RTLD_NOW | RTLD_GLOBAL);
  if (!_shaarLibrary || !_symbols.Load(_shaarLibrary)) {
    if (error) {
      NSString *format = ARCBridgeLocalizedString(@"Cannot load Chromium: %@");
      NSString *message = [NSString stringWithFormat:format, binary.path];
      *error = [NSError errorWithDomain:@"com.arcusis.browser.chromium" code:1
                              userInfo:@{NSLocalizedDescriptionKey: message}];
    }
    if (_shaarLibrary) dlclose(_shaarLibrary);
    _shaarLibrary = nullptr;
    return nil;
  }
  _shaarMediaConsentAvailable = _symbols.abi_minor() >= 8;
  _symbols.tab_find = reinterpret_cast<decltype(_symbols.tab_find)>(
      dlsym(_shaarLibrary, "shaar_tab_find"));
  return self;
}

- (int)runWithDataDirectory:(NSURL *)directory testing:(BOOL)testing {
  NSAssert(NSThread.isMainThread, @"Shaar engine requires the main thread");
  if (![NSFileManager.defaultManager createDirectoryAtURL:directory
                              withIntermediateDirectories:YES attributes:nil error:nil]) return 1;
  ARCDisableBackgroundMode(directory);
  char *resolved = realpath(directory.fileSystemRepresentation, nullptr);
  if (!resolved) return 1;
  NSString *path = [NSString stringWithUTF8String:resolved];
  free(resolved);
  shaar_config config = {};
  config.size = sizeof(config);
  config.requested_major = SHAAR_ENGINE_ABI_MAJOR;
  // Minor 7 remains the launch baseline; website media consent is gated below.
  config.requested_minor = 7;
  config.data_root = Bytes(path);
  config.locale = Bytes(self.languageIdentifier ?: @"en");
  config.on_event = ShaarEventCallback;
  config.event_context = (__bridge void *)self;
  shaar_error error = EmptyError();
  // shaar.6 has a fixed Safe Storage keychain identity shared with the regular app.
  BOOL previewBundle = [NSBundle.mainBundle.bundleIdentifier
      isEqualToString:@"com.arcusis.browser.engine-preview"];
  id mockKeychainSetting = [NSBundle.mainBundle objectForInfoDictionaryKey:@"ShaarUseMockKeychain"];
  BOOL previewMockKeychain = previewBundle &&
      [mockKeychainSetting respondsToSelector:@selector(boolValue)] && [mockKeychainSetting boolValue];
  setenv("SHAAR_ENGINE_TESTING", testing || previewMockKeychain ? "1" : "0", 1);
  if (_symbols.create(&config, &_shaarEngine, &error) != SHAAR_OK) {
    unsetenv("SHAAR_ENGINE_TESTING");
    return 1;
  }
  _shaarTesting = testing;
  const shaar_error_code result = _symbols.run(_shaarEngine, &error);
  unsetenv("SHAAR_ENGINE_TESTING");
  // Remaining native handles are being torn down, not closed by the user.
  _shaarQuitting = YES;
  if (self.onQuitRequested) self.onQuitRequested();
  for (NSString *windowID in [_shaarWindows.allKeys copy]) [self finishWindowID:windowID];
  for (id observer in _hostResizeObservers.allValues)
    [NSNotificationCenter.defaultCenter removeObserver:observer];
  [_hostResizeObservers removeAllObjects];
  for (id observer in _hostCloseObservers.allValues)
    [NSNotificationCenter.defaultCenter removeObserver:observer];
  [_hostCloseObservers removeAllObjects];
  [_hostSizes removeAllObjects];
  [_shaarWindows removeAllObjects];
  [_shaarTabs removeAllObjects];
  [_shaarFindTokens removeAllObjects];
  [_shaarFindRequests removeAllObjects];
  [_shaarMediaRequests removeAllObjects];
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
  if (event->kind == SHAAR_EVENT_ENGINE && !event->session_id.size &&
      [kind isEqualToString:@"storage.keychainUnavailable"] &&
      [payload[@"schemaVersion"] isEqual:@1] &&
      [payload[@"restartRequired"] isEqual:@YES] &&
      [payload[@"persistentCookiesAvailable"] isEqual:@NO]) {
    _shaarStartupNotice = ARCBridgeLocalizedString(@"Browsing is available, but saved cookies and passwords are unavailable for this launch. Unlock your keychain or approve access, then restart Shaar.");
    if (self.onNotice) self.onNotice(_shaarStartupNotice);
    return;
  }
  if (event->session_id.size) {
    [self receivePrivateEvent:event payload:payload];
    return;
  }
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
  if (event->kind == SHAAR_EVENT_ENGINE &&
      ([kind isEqualToString:@"engine.quitRequested"] ||
       [kind isEqualToString:@"engine.willShutDown"])) {
    _shaarQuitting = YES;
    if (self.onQuitRequested) self.onQuitRequested();
    return;
  }
  if (event->kind == SHAAR_EVENT_ENGINE && [kind isEqualToString:@"engine.quitCancelled"]) {
    _shaarQuitting = NO;
    if (self.onQuitCancelled) self.onQuitCancelled();
    return;
  }
  NSString *tabID = String(event->tab_id);
  NSString *profileID = String(event->profile_id).uppercaseString;
  if (event->kind == SHAAR_EVENT_PERMISSION &&
      [kind isEqualToString:@"websiteMediaDismissed"]) {
    NSString *requestID = payload[@"id"];
    if (![payload[@"schemaVersion"] isEqual:@1] ||
        ![requestID isKindOfClass:NSString.class] ||
        ![_shaarMediaRequests[requestID] isEqualToString:tabID]) return;
    [_shaarMediaRequests removeObjectForKey:requestID];
    if (self.onWebsiteMediaDismissed) self.onWebsiteMediaDismissed(requestID);
    return;
  }
  if (event->kind == SHAAR_EVENT_PERMISSION &&
      [kind isEqualToString:@"websiteMediaRequested"]) {
    NSString *windowID = String(event->window_id);
    NSString *requestID = payload[@"id"];
    if (!_shaarMediaConsentAvailable || event->session_id.size ||
        ![payload[@"schemaVersion"] isEqual:@1] ||
        ![requestID isKindOfClass:NSString.class] || !requestID.length ||
        requestID.length > 128 || _shaarMediaRequests[requestID] ||
        !_shaarTabs[tabID] ||
        ![profileID isEqualToString:_shaarTabProfiles[tabID]] ||
        ![windowID isEqualToString:_shaarTabWindows[tabID]]) return;
    _shaarMediaRequests[requestID] = tabID;
    NSMutableDictionary *request = [payload mutableCopy];
    request[@"profileID"] = profileID;
    request[@"tabID"] = tabID;
    request[@"windowID"] = windowID;
    if (self.onWebsiteMediaRequest) {
      self.onWebsiteMediaRequest(request);
    } else {
      [self resolveWebsiteMediaRequestID:requestID accepted:NO];
    }
    return;
  }
  if (event->kind == SHAAR_EVENT_DEVTOOLS && [kind isEqualToString:@"panelEvent"] &&
      !event->session_id.size && [payload[@"schemaVersion"] isEqual:@1] &&
      _shaarTabs[tabID] && [profileID isEqualToString:_shaarTabProfiles[tabID]] &&
      [String(event->window_id) isEqualToString:_shaarTabWindows[tabID]] &&
      self.onDevToolsPanelEvent) {
    self.onDevToolsPanelEvent(tabID, profileID, String(event->window_id), data,
                              event->sequence);
    return;
  }
  if (event->kind == SHAAR_EVENT_DEVTOOLS &&
      [kind isEqualToString:@"openURLRequested"]) {
    NSString *windowID = String(event->window_id);
    NSString *requestedProfile = payload[@"profileID"];
    if ([payload[@"schemaVersion"] intValue] != 1 ||
        ![payload[@"sourceWindowID"] isEqualToString:windowID] ||
        ![payload[@"sourceTabID"] isEqualToString:tabID] ||
        ![requestedProfile isKindOfClass:NSString.class] ||
        ![requestedProfile.uppercaseString isEqualToString:profileID]) return;
    NSMutableDictionary *request = [payload mutableCopy];
    request[@"profileID"] = profileID;
    NSString *contextID = String(event->session_id).uppercaseString;
    if (contextID.length) request[@"contextID"] = contextID;
    if (self.onDevToolsOpenURLRequest) self.onDevToolsOpenURLRequest(request);
    return;
  }
  if (event->kind == SHAAR_EVENT_DEVTOOLS && [kind isEqualToString:@"controlStatus"] &&
      [payload[@"schemaVersion"] isEqual:@1] && !event->session_id.size &&
      [[NSSet setWithArray:payload.allKeys] isSubsetOfSet:
          [NSSet setWithArray:@[@"schemaVersion", @"kind", @"enabled", @"connectionCount"]]] &&
      _shaarTabs[tabID] && [profileID isEqualToString:_shaarTabProfiles[tabID]] &&
      [String(event->window_id) isEqualToString:_shaarTabWindows[tabID]] &&
      [payload[@"enabled"] isKindOfClass:NSNumber.class] &&
      [payload[@"connectionCount"] isKindOfClass:NSNumber.class] &&
      self.onAgentBridgeStatus) {
    self.onAgentBridgeStatus(tabID, profileID, payload);
    return;
  }
  if (event->kind == SHAAR_EVENT_FIND) {
    NSString *token = _shaarFindTokens[payload[@"requestID"]];
    if (token && _shaarTabs[tabID] && self.onFindResult)
      self.onFindResult(tabID, token, [payload[@"matchCount"] intValue],
                        [payload[@"activeMatch"] intValue], [payload[@"final"] boolValue]);
    return;
  }
  if (event->kind == SHAAR_EVENT_BOOKMARK && !event->session_id.size &&
      _shaarProfiles[profileID]) {
    if (self.onLibraryChanged) self.onLibraryChanged(profileID, @"bookmarks");
    return;
  }
  if (event->kind == SHAAR_EVENT_HISTORY && !event->session_id.size &&
      _shaarProfiles[profileID]) {
    if (self.onLibraryChanged) self.onLibraryChanged(profileID, @"history");
    return;
  }
  if (event->kind == SHAAR_EVENT_WINDOW && [kind isEqualToString:@"closed"]) {
    [self finishWindowID:String(event->window_id)];
    return;
  }
  if (event->kind == SHAAR_EVENT_TAB && [kind isEqualToString:@"opened"]) {
    [self adoptOpenedTabFromEvent:event payload:payload profileID:profileID];
    return;
  }
  if (event->kind == SHAAR_EVENT_TAB && [kind isEqualToString:@"closed"]) {
    for (NSString *requestID in [_shaarMediaRequests allKeysForObject:tabID])
      [self resolveWebsiteMediaRequestID:requestID accepted:NO];
    NSString *windowID = _shaarTabWindows[tabID];
    if (windowID && [_shaarSelectedTabs[windowID] isEqualToString:tabID])
      [_shaarSelectedTabs removeObjectForKey:windowID];
    [_shaarTabs removeObjectForKey:tabID];
    [self forgetShaarMediaForTabID:tabID];
    [self stopFindingInTabID:tabID];
    [_shaarTabWindows removeObjectForKey:tabID];
    [_shaarTabProfiles removeObjectForKey:tabID];
    if (self.onTabClosed) self.onTabClosed(tabID);
    return;
  }
  if (event->kind == SHAAR_EVENT_DOWNLOAD) {
    [self shaarReceiveDownloadEventForProfileID:
        [self shaarProfileIDForNativeID:String(event->profile_id)] payload:payload];
    return;
  }
  if (event->kind == SHAAR_EVENT_MEDIA) {
    if (_shaarTabs[tabID] && [profileID isEqualToString:_shaarTabProfiles[tabID]] &&
        [String(event->window_id) isEqualToString:_shaarTabWindows[tabID]])
      [self receiveShaarMediaEventForTabID:tabID payload:payload];
    return;
  }
  if (event->kind != SHAAR_EVENT_NAVIGATION || !_shaarTabs[tabID]) return;
  NSString *url = [payload[@"url"] isKindOfClass:NSString.class] ? payload[@"url"] : @"";
  NSString *title = [payload[@"title"] isKindOfClass:NSString.class] ? payload[@"title"] : @"";
  if (self.onTabChanged) {
    self.onTabChanged(tabID, url, title, [payload[@"loading"] boolValue],
                      [payload[@"canGoBack"] boolValue], [payload[@"canGoForward"] boolValue]);
  }
  if ([payload[@"phase"] isEqualToString:@"committed"] && self.onDocumentCommitted)
    self.onDocumentCommitted(tabID, _shaarTabProfiles[tabID] ?: @"");
  if ([payload[@"phase"] isEqualToString:@"committed"] && self.onLibraryChanged)
    self.onLibraryChanged(_shaarTabProfiles[tabID] ?: @"", @"history");
  NSDictionary *failure = [payload[@"failure"] isKindOfClass:NSDictionary.class]
      ? payload[@"failure"] : nil;
  if ([failure[@"descriptionCode"] isEqualToString:@"renderer_gone"] && self.onRendererGone)
    self.onRendererGone(tabID, _shaarTabProfiles[tabID] ?: @"", @"renderer_gone", 0);
}

- (void)loadProfileID:(NSString *)profileID completion:(void (^)(NSError *))completion {
  if ([self isPrivateIdentity:profileID]) {
    completion(ShaarError(@"Invalid profile identity or engine not ready."));
    return;
  }
  if (_shaarProfiles[profileID]) {
    NSMutableArray *waiters = _shaarProfileWaiters[profileID];
    if (waiters) [waiters addObject:[completion copy]];
    else completion(nil);
    return;
  }
  _shaarProfileWaiters[profileID] = [NSMutableArray arrayWithObject:[completion copy]];
  NSString *canonicalID = profileID.lowercaseString;
  NSString *directory = [@"Profile " stringByAppendingString:canonicalID];
  __weak ARCShaarRuntime *weakSelf = self;
  void (^reply)(NSError *) = ^(NSError *failure) {
    if (failure) {
      [weakSelf finishProfileLoadID:profileID error:failure];
      return;
    }
    [weakSelf submitProfileID:profileID operation:SHAAR_OP_BOOKMARK_WATCH
                       payload:@{@"schemaVersion": @1, @"enabled": @YES}
                    completion:^(NSDictionary *result, NSError *error) {}];
    [weakSelf shaarPrimeSiteControlsForProfileID:profileID completion:^{
      [weakSelf shaarPrimeEngineServicesForProfileID:profileID completion:^{
        [weakSelf finishProfileLoadID:profileID error:nil];
      }];
    }];
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
    [self finishProfileLoadID:profileID error:ShaarError(@"Shaar could not open the profile.")];
    return;
  }
  _shaarProfiles[profileID] = [NSValue valueWithPointer:profile];
}

- (void)finishProfileLoadID:(NSString *)profileID error:(NSError *)error {
  NSArray *waiters = [_shaarProfileWaiters[profileID] copy];
  [_shaarProfileWaiters removeObjectForKey:profileID];
  if (error) [_shaarProfiles removeObjectForKey:profileID];
  for (id pending in waiters) {
    void (^complete)(NSError *) = pending;
    complete(error);
  }
}

- (shaar_engine *)privateEngineHandle { return _shaarEngine; }
- (uint64_t)nextPrivateDevToolsRequestID { return _nextRequestID++; }
- (shaar_profile *)privateProfileHandleForID:(NSString *)profileID {
  return (shaar_profile *)_shaarProfiles[profileID].pointerValue;
}

- (NSString *)primaryWindowID { return _shaarPrimaryWindowID; }
- (BOOL)isQuitting { return _shaarQuitting; }
- (NSString *)chromiumVersion { return @"155.0.8059.84"; }
- (NSWindow *)window { return [self windowForID:_shaarPrimaryWindowID]; }
- (NSView *)hostView { return [self hostViewForWindowID:_shaarPrimaryWindowID]; }

- (BOOL)createWindowID:(NSString *)windowID error:(NSError **)error {
  if ([self privateIdentityOccupied:windowID]) {
    if (error) *error = ShaarError(@"Invalid or reused native window identity.");
    return NO;
  }
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
  NSWindow *nativeWindow = (__bridge NSWindow *)_symbols.window_native_window(window);
  if (nativeWindow) {
    __weak ARCShaarRuntime *weakSelf = self;
    _hostCloseObservers[windowID] = [NSNotificationCenter.defaultCenter
        addObserverForName:NSWindowWillCloseNotification object:nativeWindow
                     queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *notification) {
      [weakSelf finishWindowID:windowID];
    }];
  }
  return YES;
}

- (BOOL)closeWindowID:(NSString *)windowID {
  shaar_window *window = (shaar_window *)_shaarWindows[windowID].pointerValue;
  if (!window) return NO;
  shaar_error error = EmptyError();
  if (_symbols.window_close(window, &error) != SHAAR_OK) return NO;
  return YES;
}

- (BOOL)isWindowOpenID:(NSString *)windowID {
  shaar_window *window = (shaar_window *)_shaarWindows[windowID].pointerValue;
  return window && _symbols.window_native_window(window) != nullptr;
}

- (void)retireClosedWindowID:(NSString *)windowID {
  [self finishWindowID:windowID];
}

- (void)finishWindowID:(NSString *)windowID {
  if (!_shaarWindows[windowID]) return;
  id observer = _hostResizeObservers[windowID];
  if (observer) [NSNotificationCenter.defaultCenter removeObserver:observer];
  id closeObserver = _hostCloseObservers[windowID];
  if (closeObserver) [NSNotificationCenter.defaultCenter removeObserver:closeObserver];
  [_hostResizeObservers removeObjectForKey:windowID];
  [_hostCloseObservers removeObjectForKey:windowID];
  [_hostSizes removeObjectForKey:windowID];
  [_shaarSelectedTabs removeObjectForKey:windowID];
  for (NSString *tabID in [_shaarTabWindows.allKeys copy]) {
    if (![_shaarTabWindows[tabID] isEqualToString:windowID]) continue;
    [_shaarTabs removeObjectForKey:tabID];
    [_shaarTabWindows removeObjectForKey:tabID];
    [_shaarTabProfiles removeObjectForKey:tabID];
  }
  [_shaarWindows removeObjectForKey:windowID];
  [self closeExtensionPopupForWindowID:windowID];
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

- (void)adoptOpenedTabFromEvent:(const shaar_event *)event
                        payload:(NSDictionary *)payload
                      profileID:(NSString *)profileID {
  if (!_symbols.tab_find || !_shaarEngine || event->session_id.size) return;
  if ([payload[@"schemaVersion"] intValue] != 1) return;
  NSString *tabID = String(event->tab_id);
  NSString *windowID = String(event->window_id);
  if (!tabID.length || !windowID.length || _shaarTabs[tabID]) return;
  NSString *openerID = [payload[@"openerTabID"] isKindOfClass:NSString.class]
      ? payload[@"openerTabID"] : nil;
  NSString *storedProfile = openerID.length ? _shaarTabProfiles[openerID] : nil;
  if (storedProfile.length) profileID = storedProfile;
  shaar_tab *tab = nullptr;
  shaar_error error = EmptyError();
  if (_symbols.tab_find(_shaarEngine, Bytes(windowID), Bytes(tabID), &tab, &error) != SHAAR_OK ||
      !tab) return;
  if (!_shaarWindows[windowID] || !_shaarProfiles[profileID]) {
    _shaarTabs[tabID] = [NSValue valueWithPointer:tab];
    [self closeTabID:tabID];
    return;
  }
  _shaarTabs[tabID] = [NSValue valueWithPointer:tab];
  _shaarTabWindows[tabID] = windowID;
  _shaarTabProfiles[tabID] = profileID;
  NSString *url = [payload[@"url"] isKindOfClass:NSString.class] ? payload[@"url"] : @"";
  if (self.onNewTab) {
    self.onNewTab(tabID, profileID, url, openerID, [payload[@"foreground"] boolValue]);
  } else {
    [self closeTabID:tabID];
  }
}

- (NSString *)windowIDForTabID:(NSString *)tabID { return _shaarTabWindows[tabID]; }

- (BOOL)openTabID:(NSString *)tabID profileID:(NSString *)profileID windowID:(NSString *)windowID
               url:(NSString *)url error:(NSError **)error {
  if ([self isPrivateIdentity:tabID] || [self isPrivateIdentity:profileID]) {
    if (error) *error = ShaarError(@"Private identities cannot enter regular tab ownership.");
    return NO;
  }
  if (![self isWindowOpenID:windowID]) {
    if (error) *error = ShaarStatusError(@"Shaar window is closed.", SHAAR_NOT_FOUND);
    return NO;
  }
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
    if (_shaarTesting) {
      fprintf(stderr, "Shaar tab_open failed: status=%d native=%d profile=%s window=%s\n",
              (int)status, (int)nativeError.code, profileID.UTF8String,
              windowID.UTF8String);
    }
    if (error) *error = ShaarStatusError(@"Shaar could not open the tab.", status);
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
  if (![_shaarSelectedTabs[windowID] isEqualToString:tabID])
    [self closeExtensionPopupForWindowID:windowID];
  _shaarSelectedTabs[windowID] = tabID;
  // Native notifications must unwind before reentering TabStripModel. Host
  // actions can activate immediately, without waiting behind Chromium's pump.
  __weak ARCShaarRuntime *weakSelf = self;
  ARCDispatchShaarTabActivation(^{
    ARCShaarRuntime *owner = weakSelf;
    if (!owner || !owner->_shaarEngine || !owner->_shaarTabs[tabID] ||
        ![owner->_shaarSelectedTabs[windowID] isEqualToString:tabID]) return;
    [owner shaarSubmit:SHAAR_OP_WINDOW_ACTIVATE_TAB
            profileID:owner->_shaarTabProfiles[tabID] tabID:tabID
              payload:@{@"schemaVersion": @1, @"tabID": tabID}
           completion:^(NSDictionary *, NSError *error) {
      ARCShaarRuntime *current = weakSelf;
      // Wait for the native completion task, after Chromium's tab-strip update
      // unwinds. Swift can then restore the page once rather than cycling
      // reconcile/activate to repair presentation.
      if (error || !current || !current->_shaarTabs[tabID] ||
          ![current->_shaarSelectedTabs[windowID] isEqualToString:tabID]) return;
      if (current.onTabActivated)
        current.onTabActivated(tabID, current->_shaarTabProfiles[tabID]);
    }];
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

- (void)submitProfileID:(NSString *)profileID operation:(shaar_operation)operation
                payload:(NSDictionary *)payload
             completion:(void (^)(NSDictionary *, NSError *))completion {
  shaar_profile *profile = (shaar_profile *)_shaarProfiles[profileID].pointerValue;
  NSData *json = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
  if (!profile || !json || !_shaarEngine) {
    completion(nil, ShaarError(@"Shaar profile operation is unavailable."));
    return;
  }
  shaar_scope scope = {};
  scope.size = sizeof(scope);
  scope.profile = profile;
  void (^reply)(NSDictionary *, NSError *) = [completion copy];
  void *context = (__bridge_retained void *)reply;
  shaar_error error = EmptyError();
  shaar_error_code status = _symbols.submit(
      _shaarEngine, scope, nullptr, nullptr, operation,
      {(const char *)json.bytes, json.length}, _nextRequestID++,
      [](void *context, const shaar_result *result) {
        void (^finish)(NSDictionary *, NSError *) = (__bridge_transfer id)context;
        if (!result || result->error.code != SHAAR_OK) {
          finish(nil, ShaarError(@"Shaar profile operation failed."));
          return;
        }
        NSData *bytes = [NSData dataWithBytes:result->payload_json.data ?: ""
                                      length:result->payload_json.size];
        NSDictionary *value = bytes.length
            ? [NSJSONSerialization JSONObjectWithData:bytes options:0 error:nil] : @{};
        if (![value isKindOfClass:NSDictionary.class]) {
          finish(nil, ShaarError(@"Shaar returned an invalid profile response."));
          return;
        }
        finish(value, nil);
      }, context, &error);
  if (status != SHAAR_OK) {
    CFBridgingRelease(context);
    completion(nil, ShaarError(@"Shaar rejected the profile operation."));
  }
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

- (BOOL)navigateTabID:(NSString *)tabID profileID:(NSString *)profileID
             windowID:(NSString *)windowID url:(NSString *)url {
  if (![_shaarTabProfiles[tabID] isEqualToString:profileID] ||
      ![_shaarTabWindows[tabID] isEqualToString:windowID]) return NO;
  return [self submitTabID:tabID operation:SHAAR_OP_TAB_NAVIGATE
                  payload:@{@"schemaVersion": @1, @"url": url,
                            @"userInitiated": @YES}];
}

- (void)goBackInTabID:(NSString *)tabID {
  [self submitTabID:tabID operation:SHAAR_OP_TAB_GO
            payload:@{@"schemaVersion": @1, @"direction": @"back"}];
}
- (void)goForwardInTabID:(NSString *)tabID {
  [self submitTabID:tabID operation:SHAAR_OP_TAB_GO
            payload:@{@"schemaVersion": @1, @"direction": @"forward"}];
}
- (void)reloadTabID:(NSString *)tabID {
  [self reloadTabID:tabID profileID:_shaarTabProfiles[tabID] mode:ARCPageReloadModeNormal];
}
- (BOOL)reloadTabID:(NSString *)tabID profileID:(NSString *)profileID {
  return [self reloadTabID:tabID profileID:profileID mode:ARCPageReloadModeNormal];
}
- (BOOL)reloadTabID:(NSString *)tabID profileID:(NSString *)profileID
                mode:(ARCPageReloadMode)mode {
  if (![_shaarTabProfiles[tabID] isEqualToString:profileID] ||
      mode == ARCPageReloadModeNewRenderer) return NO;
  return [self submitTabID:tabID operation:SHAAR_OP_TAB_RELOAD
                  payload:@{@"schemaVersion": @1,
                            @"mode": mode == ARCPageReloadModeBypassingCache ?
                                @"bypass_cache" : @"normal"}];
}

- (NSImage *)faviconForTabID:(NSString *)tabID profileID:(NSString *)profileID
                    windowID:(NSString *)windowID {
  if (!_shaarEngine || ![_shaarTabProfiles[tabID] isEqualToString:profileID] ||
      ![_shaarTabWindows[tabID] isEqualToString:windowID]) return nil;
  shaar_profile *profile = (shaar_profile *)_shaarProfiles[profileID].pointerValue;
  shaar_window *window = (shaar_window *)_shaarWindows[windowID].pointerValue;
  shaar_tab *tab = (shaar_tab *)_shaarTabs[tabID].pointerValue;
  if (!profile || !window || !tab) return nil;
  shaar_scope scope = {.size = sizeof(scope), .profile = profile};
  shaar_bytes png = {};
  shaar_error error = EmptyError();
  if (_symbols.tab_favicon_png(_shaarEngine, scope, window, tab, &png, &error) != SHAAR_OK ||
      !png.data || !png.size) return nil;
  return [[NSImage alloc] initWithData:[NSData dataWithBytes:png.data length:png.size]];
}

- (int)chromeWindowIDForProfileID:(NSString *)profileID windowID:(NSString *)windowID {
  return -1;  // Native Chromium window IDs are not part of the Shaar ABI.
}

- (int)nativeTabIDForID:(NSString *)tabID { return -1; }

- (void)resolveExternalAppRequestID:(NSString *)requestID accepted:(BOOL)accepted {
  // No Shaar external-app request ABI exists yet.
}

- (BOOL)findInTabID:(NSString *)tabID profileID:(NSString *)profileID
         requestID:(NSString *)requestID text:(NSString *)text forward:(BOOL)forward {
  NSString *windowID = _shaarTabWindows[tabID];
  if (!text.length || ![[NSUUID alloc] initWithUUIDString:requestID] ||
      ![_shaarTabProfiles[tabID] isEqualToString:profileID] ||
      ![_shaarSelectedTabs[windowID] isEqualToString:tabID]) return NO;
  NSString *previous = _shaarFindRequests[tabID];
  if (previous) [_shaarFindTokens removeObjectForKey:previous];
  NSString *nativeID = [NSString stringWithFormat:@"%llu", _nextRequestID];
  _shaarFindTokens[nativeID] = requestID;
  _shaarFindRequests[tabID] = nativeID;
  BOOL accepted = [self submitTabID:tabID operation:SHAAR_OP_TAB_FIND
                           payload:@{@"schemaVersion": @1, @"query": text,
                                     @"forward": @(forward)}];
  if (!accepted) {
    [_shaarFindTokens removeObjectForKey:nativeID];
    [_shaarFindRequests removeObjectForKey:tabID];
  }
  return accepted;
}

- (void)stopFindingInTabID:(NSString *)tabID {
  NSString *nativeID = _shaarFindRequests[tabID];
  if (!nativeID) return;
  [_shaarFindRequests removeObjectForKey:tabID];
  [_shaarFindTokens removeObjectForKey:nativeID];
  if (_shaarTabs[tabID])
    [self submitTabID:tabID operation:SHAAR_OP_TAB_STOP_FIND
              payload:@{@"schemaVersion": @1, @"selection": @"keep"}];
}

- (void)evaluateInTabID:(NSString *)tabID script:(NSString *)script
            completion:(void (^)(NSString *))completion {
  NSString *profileID = _shaarTabProfiles[tabID];
  NSString *windowID = _shaarTabWindows[tabID];
  if (!script.length || ![self shaarDevToolsOwnsTabID:tabID profileID:profileID
                                           windowID:windowID]) {
    completion(nil);
    return;
  }
  [self shaarDevToolsCall:@"Runtime.evaluate"
                  params:@{@"expression": script, @"returnByValue": @YES}
              capability:SHAAR_DEVTOOLS_CAPABILITY_DEVELOPER tabID:tabID
               profileID:profileID windowID:windowID
              completion:^(NSDictionary *result, NSError *error) {
    NSDictionary *remote = [result[@"result"] isKindOfClass:NSDictionary.class]
                             ? result[@"result"] : nil;
    id value = remote[@"value"];
    if (error || result[@"exceptionDetails"] || !value) {
      completion(nil);
      return;
    }
    NSData *json = [NSJSONSerialization dataWithJSONObject:value
                                               options:NSJSONWritingFragmentsAllowed error:nil];
    completion(json ? [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding] : nil);
  }];
}

- (void)bookmarksForProfileID:(NSString *)profileID
                  completion:(void (^)(NSDictionary *, NSError *))completion {
  [self submitProfileID:profileID operation:SHAAR_OP_BOOKMARK_TREE
                payload:@{@"schemaVersion": @1}
             completion:^(NSDictionary *result, NSError *error) {
    if (error || ![result[@"bar"] isKindOfClass:NSDictionary.class] ||
        ![result[@"other"] isKindOfClass:NSDictionary.class]) {
      completion(nil, error ?: ShaarError(@"Invalid Shaar bookmark tree."));
      return;
    }
    completion(result, nil);
  }];
}

- (void)applyBookmarkOperation:(NSDictionary *)operation profileID:(NSString *)profileID
                    completion:(void (^)(NSError *))completion {
  if (![operation isKindOfClass:NSDictionary.class]) {
    completion(ShaarError(@"Invalid Shaar bookmark action."));
    return;
  }
  [self submitProfileID:profileID operation:SHAAR_OP_BOOKMARK_APPLY
                payload:@{@"schemaVersion": @1, @"ops": @[operation]}
             completion:^(NSDictionary *result, NSError *error) {
    NSArray *invalid = result[@"invalid"];
    BOOL confirmed = [result[@"applied"] isEqual:@1] &&
                     [result[@"skipped"] isEqual:@0] &&
                     [invalid isKindOfClass:NSArray.class] && !invalid.count;
    if (error) { completion(error); return; }
    completion(confirmed ? nil : ShaarError(@"Shaar did not confirm the bookmark action."));
  }];
}

- (void)historyForProfileID:(NSString *)profileID limit:(NSInteger)limit
                 completion:(void (^)(NSArray<NSDictionary *> *, NSError *))completion {
  if (limit < 1 || limit > 5000) {
    completion(nil, ShaarError(@"Invalid Shaar history limit."));
    return;
  }
  [self submitProfileID:profileID operation:SHAAR_OP_HISTORY_QUERY
                payload:@{@"schemaVersion": @1, @"maxUrls": @(limit),
                          @"maxVisitsPerUrl": @1}
             completion:^(NSDictionary *result, NSError *error) {
    NSArray *entries = result[@"entries"];
    if (error || ![entries isKindOfClass:NSArray.class]) {
      completion(nil, error ?: ShaarError(@"Invalid Shaar history response."));
      return;
    }
    NSMutableArray<NSDictionary *> *rows = [NSMutableArray arrayWithCapacity:entries.count];
    for (id entry in entries) {
      if (![entry isKindOfClass:NSDictionary.class] ||
          ![entry[@"url"] isKindOfClass:NSString.class] ||
          ![entry[@"title"] isKindOfClass:NSString.class] ||
          ![entry[@"visitCount"] isKindOfClass:NSNumber.class] ||
          ![entry[@"visits"] isKindOfClass:NSArray.class]) {
        completion(nil, ShaarError(@"Invalid Shaar history entry."));
        return;
      }
      [rows addObject:@{@"u": entry[@"url"], @"t": entry[@"title"],
                        @"n": entry[@"visitCount"], @"v": entry[@"visits"]}];
    }
    completion(rows, nil);
  }];
}

- (void)deleteHistoryURL:(NSString *)url profileID:(NSString *)profileID
              completion:(void (^)(NSError *))completion {
  NSURL *address = [NSURL URLWithString:url];
  if (![@[@"http", @"https"] containsObject:address.scheme.lowercaseString]) {
    completion(ShaarError(@"Invalid Shaar history address."));
    return;
  }
  [self submitProfileID:profileID operation:SHAAR_OP_HISTORY_DELETE
                payload:@{@"schemaVersion": @1, @"urls": @[url]}
             completion:^(NSDictionary *result, NSError *error) {
    if (error) { completion(error); return; }
    if (![result[@"deleted"] isKindOfClass:NSNumber.class]) {
      completion(ShaarError(@"Shaar did not confirm history deletion."));
      return;
    }
    if (self.onLibraryChanged) self.onLibraryChanged(profileID, @"history");
    completion(nil);
  }];
}

- (void)importHistoryRows:(NSArray<NSDictionary *> *)rows source:(NSString *)source
                profileID:(NSString *)profileID completion:(void (^)(NSError *))completion {
  if (![@[@"safari", @"chrome", @"arc", @"firefox"] containsObject:source] ||
      !rows.count || rows.count > 5000) {
    completion(ShaarError(@"Unsupported Shaar history import."));
    return;
  }
  NSMutableArray<NSDictionary *> *pages = [NSMutableArray arrayWithCapacity:rows.count];
  for (NSDictionary *row in rows) {
    if (![row isKindOfClass:NSDictionary.class] ||
        ![row[@"u"] isKindOfClass:NSString.class] ||
        ![row[@"t"] isKindOfClass:NSString.class] ||
        ![row[@"v"] isKindOfClass:NSArray.class]) {
      completion(ShaarError(@"Invalid Shaar history import row."));
      return;
    }
    [pages addObject:@{@"url": row[@"u"], @"title": row[@"t"],
                       @"visits": row[@"v"]}];
  }
  [self submitProfileID:profileID operation:SHAAR_OP_HISTORY_INSERT
                payload:@{@"schemaVersion": @1, @"source": source, @"pages": pages}
             completion:^(NSDictionary *result, NSError *error) {
    NSArray *rejected = result[@"rejected"];
    BOOL confirmed = [result[@"accepted"] isEqual:@(rows.count)] &&
                     [rejected isKindOfClass:NSArray.class] && !rejected.count;
    if (error) { completion(error); return; }
    if (!confirmed) {
      completion(ShaarError(@"Shaar did not import every history row."));
      return;
    }
    if (self.onLibraryChanged) self.onLibraryChanged(profileID, @"history");
    completion(nil);
  }];
}

- (BOOL)shaarSubmitExtensionOperation:(shaar_operation)operation
                           profileID:(NSString *)profileID tabID:(NSString *)tabID
                             payload:(NSDictionary *)payload
                          completion:(void (^)(NSString *, shaar_error_code))completion {
  shaar_profile *profile = (shaar_profile *)_shaarProfiles[profileID].pointerValue;
  NSString *windowID = tabID ? _shaarTabWindows[tabID] : _shaarPrimaryWindowID;
  shaar_window *window = (shaar_window *)_shaarWindows[windowID].pointerValue;
  shaar_tab *tab = tabID ? (shaar_tab *)_shaarTabs[tabID].pointerValue : nullptr;
  const BOOL profileOnly = operation == SHAAR_OP_EXTENSION_LIST ||
      operation == SHAAR_OP_PROBE_FRAMEWORK_DEVTOOLS;
  if (!_shaarEngine || !profile || (!profileOnly && !window) || (tabID && (!tab ||
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

- (NSString *)shaarWindowIDForTabID:(NSString *)tabID {
  return _shaarTabWindows[tabID];
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

- (NSView *)shaarExtensionPopupViewForID:(NSString *)popupID
                                 windowID:(NSString *)windowID {
  shaar_window *window = (shaar_window *)_shaarWindows[windowID].pointerValue;
  if (!_shaarEngine || !window || !popupID.length) return nil;
  auto popupView = reinterpret_cast<decltype(&shaar_extension_popup_view)>(
      dlsym(_shaarLibrary, "shaar_extension_popup_view"));
  return popupView ? (__bridge NSView *)popupView(_shaarEngine, window, Bytes(popupID)) : nil;
}

- (void)quit {
  if (!_shaarEngine) return;
  _shaarQuitting = YES;
  if (self.onQuitRequested) self.onQuitRequested();
  shaar_error error = EmptyError();
  shaar_error_code status = _symbols.request_quit(_shaarEngine, &error);
  if (status != SHAAR_OK && status != SHAAR_SHUTTING_DOWN) {
    _shaarQuitting = NO;
    if (self.onQuitCancelled) self.onQuitCancelled();
  }
}

- (BOOL)findInPrivateTabID:(NSString *)tabID windowID:(NSString *)windowID
                contextID:(NSString *)contextID requestID:(NSString *)requestID
                     text:(NSString *)text forward:(BOOL)forward {
  if (self.onNotice) self.onNotice(@"Private page find is unsupported by this Shaar engine.");
  return NO;
}

- (void)stopFindingInPrivateTabID:(NSString *)tabID windowID:(NSString *)windowID
                       contextID:(NSString *)contextID {
  if (self.onNotice) self.onNotice(@"Private page find is unsupported by this Shaar engine.");
}

- (void)resolveInstallRequestID:(NSString *)requestID accepted:(BOOL)accepted {
  if (self.onNotice) self.onNotice(@"Extension installation is unsupported by this Shaar engine.");
}

- (void)resolveWebsiteMediaRequestID:(NSString *)requestID accepted:(BOOL)accepted {
  if (!_shaarMediaConsentAvailable) {
    if (self.onNotice) self.onNotice(@"Website media approval is unsupported by this Shaar engine.");
    return;
  }
  NSString *tabID = _shaarMediaRequests[requestID];
  if (!tabID) return;
  [_shaarMediaRequests removeObjectForKey:requestID];
  [self submitTabID:tabID operation:SHAAR_OP_MEDIA_PERMISSION_DECISION
            payload:@{@"schemaVersion": @1, @"id": requestID,
                      @"accepted": @(accepted)}];
}

- (void)resolveDesktopCaptureRequestID:(NSString *)requestID sourceID:(NSString *)sourceID {
  if (self.onNotice) self.onNotice(@"Desktop capture is unsupported by this Shaar engine.");
}

- (void)dealloc {
  for (id observer in _hostResizeObservers.allValues)
    [NSNotificationCenter.defaultCenter removeObserver:observer];
  if (_shaarLibrary) dlclose(_shaarLibrary);
}

@end
