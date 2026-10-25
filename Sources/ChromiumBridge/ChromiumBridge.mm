#import "include/ChromiumBridge.h"
#import "ChromiumDownloads.h"
#import "ChromiumLibrary.h"
#import "../../ThirdParty/ArdiaCore/ArdiaCore.h"
#import <dlfcn.h>
#include <string>
#include <vector>
#include <cmath>

static NSError *BridgeError(NSString *message) {
  return [NSError errorWithDomain:@"com.arcusis.browser.chromium" code:1
                        userInfo:@{NSLocalizedDescriptionKey: message}];
}

static void ClickProbeTarget(ArdiaCoreTab *tab, NSString *expression, BOOL (^current)(void),
                             void (^completion)(BOOL)) {
  [tab devToolsCall:@"Runtime.evaluate" params:@{@"expression": expression, @"returnByValue": @YES}
               timeout:5 completion:^(NSDictionary *result, NSString *error) {
    NSDictionary *point = result[@"result"][@"value"];
    if (error || ![point isKindOfClass:NSDictionary.class] || !current() ||
        ![point[@"x"] isKindOfClass:NSNumber.class] || ![point[@"y"] isKindOfClass:NSNumber.class] ||
        !std::isfinite([point[@"x"] doubleValue]) || !std::isfinite([point[@"y"] doubleValue])) {
      completion(NO);
      return;
    }
    NSDictionary *press = @{@"type": @"mousePressed", @"x": point[@"x"], @"y": point[@"y"],
                             @"button": @"left", @"buttons": @1, @"clickCount": @1};
    [tab devToolsCall:@"Input.dispatchMouseEvent" params:press timeout:5
            completion:^(NSDictionary *ignored, NSString *pressError) {
      if (pressError || !current()) { completion(NO); return; }
      NSDictionary *release = @{@"type": @"mouseReleased", @"x": point[@"x"], @"y": point[@"y"],
                                 @"button": @"left", @"buttons": @0, @"clickCount": @1};
      [tab devToolsCall:@"Input.dispatchMouseEvent" params:release timeout:5
              completion:^(NSDictionary *ignoredRelease, NSString *releaseError) {
        completion(releaseError == nil && current());
      }];
    }];
  }];
}

static BOOL ValidID(NSString *value) {
  return [[[[NSUUID alloc] initWithUUIDString:value] UUIDString] isEqualToString:value];
}

static BOOL ValidExtensionID(NSString *value) {
  return value.length == 32 && [value rangeOfCharacterFromSet:
    [[NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnop"] invertedSet]].location == NSNotFound;
}

BOOL ARCReservedBrowserShortcut(NSString *key, NSEventModifierFlags modifiers) {
  NSEventModifierFlags chord = modifiers & (NSEventModifierFlagCommand | NSEventModifierFlagControl |
    NSEventModifierFlagOption | NSEventModifierFlagShift | NSEventModifierFlagFunction);
  if (chord == NSEventModifierFlagCommand) {
    return [@[@"n", @"t", @"l", @"w", @"s", @"q", @"r", @"f", @"g", @"d", @"y"] containsObject:key.lowercaseString];
  }
  if (chord == (NSEventModifierFlagCommand | NSEventModifierFlagShift)) {
    return [@[@"w", @"g", @"j", @"t"] containsObject:key.lowercaseString];
  }
  return chord == (NSEventModifierFlagControl | NSEventModifierFlagOption) &&
    [@[@"[", @"]"] containsObject:key];
}

@interface ARCNativeWindowState : NSObject
@property(copy) NSString *identity;
@property(strong) ArdiaCoreWindow *native;
@property(copy) NSString *selectedTabID;
@property(copy) NSString *findTabID;
@property(copy) NSString *findRequestID;
@property(copy) NSString *findText;
@property(strong) ArdiaCoreTab *popup;
@property(copy) NSString *popupID;
@property(copy) NSString *popupOwnerTabID;
@property(copy) NSString *popupExtensionID;
@property BOOL closing;
@property BOOL closed;
@property BOOL awaitingBrowserTab;
@property BOOL closeWhenEmpty;
@property BOOL rejectsEngineTabs;
@property(strong) NSMutableDictionary<NSString *, NSArray<NSString *> *> *tabOrders;
@property(strong) NSMutableDictionary<NSString *, NSArray<NSString *> *> *tabPins;
@property(strong) ArdiaCoreTab *incomingTab;
@property(copy) NSString *incomingOpenerID;
@property NSUInteger hostSelectionDepth;
@end
@implementation ARCNativeWindowState
@end

@interface ARCChromiumRuntime () <ArdiaCoreEngineDelegate, ArdiaCoreWindowDelegate,
                                ArdiaCoreTabDelegate>
- (void)closedWindowID:(NSString *)identity;
@end

@implementation ARCChromiumRuntime {
  void *_library;
  Class _engineClass;
  ArdiaCoreEngine *_engine;
  NSString *_primaryWindowID;
  NSMutableDictionary<NSString *, ARCNativeWindowState *> *_windows;
  NSMutableDictionary<NSString *, NSString *> *_tabWindows;
  NSMutableDictionary<NSString *, id> *_windowCloseObservers;
  NSMutableSet<NSString *> *_retiredWindowIDs;
  NSMutableDictionary<NSString *, ArdiaCoreProfile *> *_profiles;
  NSMutableDictionary<NSString *, ArdiaCoreTab *> *_tabs;
  NSMutableDictionary<NSString *, NSString *> *_owners;
  NSMutableDictionary<NSString *, NSMutableArray *> *_profileWaiters;
  NSString *_openingTabID;
  NSString *_openingProfileID;
  NSString *_openingWindowID;
  BOOL _testing;
  BOOL _probeTLS;
  NSURL *_probeRoot;
  NSMutableDictionary<NSString *, NSDictionary *> *_pendingInstalls;
  NSMutableDictionary<NSString *, NSDictionary *> *_pendingMedia;
  NSMutableDictionary<NSString *, NSMutableArray<NSDictionary *> *> *_probeExtensions;
  NSMutableArray<NSDictionary *> *_probeDiagnostics;
  NSMutableSet<NSString *> *_pendingHostClosures;
  BOOL _closingBrowser;
  ARCDownloadService *_downloadService;
  ARCEngineServices *_services;
  ARCLibraryService *_libraryService;
}

- (instancetype)initWithFrameworkURL:(NSURL *)url error:(NSError **)error {
  if (!(self = [super init])) return nil;
  NSURL *binary = [url URLByAppendingPathComponent:@"Versions/Current/Chromium Framework"];
  _library = dlopen(binary.fileSystemRepresentation, RTLD_NOW | RTLD_GLOBAL);
  if (!_library) {
    if (error) *error = BridgeError([NSString stringWithFormat:@"Cannot load Chromium: %s", dlerror()]);
    return nil;
  }
  _engineClass = NSClassFromString(@"ArdiaCoreEngine");
  if (!_engineClass || !NSClassFromString(@"ArdiaCoreWindow")) {
    if (error) *error = BridgeError(@"The framework does not expose the pinned ArdiaCore API.");
    return nil;
  }
  _profiles = [NSMutableDictionary dictionary];
  _primaryWindowID = NSUUID.UUID.UUIDString;
  _windows = [NSMutableDictionary dictionary];
  _tabWindows = [NSMutableDictionary dictionary];
  _windowCloseObservers = [NSMutableDictionary dictionary];
  _retiredWindowIDs = [NSMutableSet set];
  _tabs = [NSMutableDictionary dictionary];
  _owners = [NSMutableDictionary dictionary];
  _profileWaiters = [NSMutableDictionary dictionary];
  _pendingInstalls = [NSMutableDictionary dictionary];
  _pendingMedia = [NSMutableDictionary dictionary];
  _pendingHostClosures = [NSMutableSet set];
  _probeExtensions = [NSMutableDictionary dictionary];
  _probeDiagnostics = [NSMutableArray array];
  _services = [[ARCEngineServices alloc] initWithLibrary:_library error:error];
  if (!_services) return nil;
  _downloadService = [[ARCDownloadService alloc] initWithServices:_services];
  _libraryService = [[ARCLibraryService alloc] initWithServices:_services];
  __weak ARCChromiumRuntime *weakSelf = self;
  _services.onEvent = ^(NSString *topic, NSString *profile, NSDictionary *payload) {
    ARCChromiumRuntime *owner = weakSelf;
    if (!owner) return;
    if ([topic hasPrefix:@"downloads."]) {
      [owner->_downloadService receiveTopic:topic profileID:profile payload:payload];
    } else if (owner.onLibraryChanged) {
      owner.onLibraryChanged(profile, [topic hasPrefix:@"bookmarks."] ? @"bookmarks" : @"history");
    }
  };
  _libraryService.onError = ^(NSString *profile, NSString *section, NSString *message) {
    ARCChromiumRuntime *owner = weakSelf;
    if (owner.onLibraryError) owner.onLibraryError(profile, section, message);
  };
  _downloadService.onChanged = ^(NSString *profile, NSDictionary *download) {
    ARCChromiumRuntime *owner = weakSelf;
    if (owner.onDownloadChanged) owner.onDownloadChanged(profile, download);
  };
  _downloadService.onRemoved = ^(NSString *profile, NSString *identity) {
    ARCChromiumRuntime *owner = weakSelf;
    if (owner.onDownloadRemoved) owner.onDownloadRemoved(profile, identity);
  };
  return self;
}

- (int)runWithDataDirectory:(NSURL *)directory testing:(BOOL)testing {
  return [self runWithDataDirectory:directory testing:testing probeTLSFingerprint:nil];
}
- (int)runWithDataDirectory:(NSURL *)directory testing:(BOOL)testing probeTLSFingerprint:(NSString *)fingerprint {
  NSAssert(NSThread.isMainThread, @"Chromium must start on the main thread");
  NSError *configurationError = nil;
  NSString *tlsArgument = ARCProbeTLSArgument(directory, fingerprint, testing, &configurationError);
  if (configurationError) return 1;
  _testing = testing;
  _probeTLS = tlsArgument != nil;
  if (testing) _probeRoot = directory.URLByDeletingLastPathComponent.URLByResolvingSymlinksInPath;
  // Never forward arbitrary launch flags into company profiles.
  std::vector<std::string> strings = {
    NSProcessInfo.processInfo.arguments.firstObject.UTF8String,
    "--user-data-dir=" + std::string(directory.fileSystemRepresentation),
    "--disable-stack-profiler",
    "--disable-features=MacAppCodeSignClone,DevToolsAcceptDebuggingConnections",
    "--profile-directory=Default"
  };
  if (testing) {
    // Disposable fixture profiles only. Real profiles always use the OS keychain.
    strings.push_back("--use-mock-keychain");
    strings.push_back("--disable-background-networking");
    strings.push_back("--disable-component-update");
    strings.push_back("--disable-backgrounding-occluded-windows");
    strings.push_back("--mute-audio");
    strings.push_back("--use-fake-device-for-media-stream");
    strings.push_back("--ardia-test-system-media-permission=granted");
    if (tlsArgument) strings.push_back(tlsArgument.UTF8String);
  }
  std::vector<const char *> arguments;
  for (const auto &value : strings) arguments.push_back(value.c_str());
  return [_engineClass runWithArgc:(int)arguments.size() argv:arguments.data() delegate:self];
}

- (void)engineDidStart {
  _engine = [_engineClass sharedEngine];
  [_services start];
  if (_testing && !_probeTLS) {
    // Diagnostics only for the empty Bitwarden store-probe profile. No credential entry occurs.
    _engine.pageScript = @"(function(post){"
      "if(location.protocol==='chrome-extension:' && location.host==='nngceckbapebfimnlniiiahkandclblb'){"
      "const report=(kind,value)=>post('arcusisProbeDiagnostic',JSON.stringify({kind,message:String(value).slice(0,8192),url:location.href}));"
      "addEventListener('error',e=>report('error',e.message+' '+(e.error?.stack||'')));"
      "addEventListener('unhandledrejection',e=>report('rejection',e.reason?.stack||e.reason));"
      "const original=console.error;console.error=(...args)=>{report('console',args.map(String).join(' '));return original.apply(console,args);};"
      "}return function(){};})";
  }
  if (_testing) [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
  [self createWindowID:_primaryWindowID error:nil];
  if (_onReady) _onReady();
}

- (NSString *)primaryWindowID { return _primaryWindowID; }
- (BOOL)isQuitting { return _closingBrowser; }
- (NSWindow *)window { return [self windowForID:_primaryWindowID]; }
- (NSView *)hostView { return [self hostViewForWindowID:_primaryWindowID]; }
- (NSWindow *)windowForID:(NSString *)identity { return _windows[identity].closed ? nil : _windows[identity].native.window; }
- (NSView *)hostViewForWindowID:(NSString *)identity { return _windows[identity].closed ? nil : _windows[identity].native.hostView; }
- (NSString *)windowIDForTabID:(NSString *)identity { return _tabWindows[identity]; }
- (int)chromeWindowIDForProfileID:(NSString *)profileID windowID:(NSString *)identity {
  ARCNativeWindowState *state = _windows[identity];
  ArdiaCoreProfile *profile = _profiles[profileID];
  if (!state || state.closed || state.closing || !profile) return -1;
  return [state.native chromeWindowIdForProfile:profile];
}
- (ARCNativeWindowState *)stateForTabID:(NSString *)identity { return identity ? _windows[_tabWindows[identity] ?: @""] : nil; }
- (ARCNativeWindowState *)stateForWindow:(ArdiaCoreWindow *)window {
  for (ARCNativeWindowState *state in _windows.allValues) if (state.native == window) return state;
  return nil;
}
- (ARCNativeWindowState *)stateForPopupID:(NSString *)identity {
  for (ARCNativeWindowState *state in _windows.allValues) if ([state.popupID isEqualToString:identity]) return state;
  return nil;
}
- (ARCNativeWindowState *)stateForPopupTab:(ArdiaCoreTab *)tab {
  if (!tab) return nil;
  for (ARCNativeWindowState *state in _windows.allValues) if (state.popup == tab) return state;
  return nil;
}
- (BOOL)isSelectedTabID:(NSString *)identity {
  ARCNativeWindowState *state = [self stateForTabID:identity];
  return state && !state.closed && !state.closing && !_closingBrowser &&
    state.native.activeProfile == _tabs[identity].profile && [state.selectedTabID isEqualToString:identity];
}
- (BOOL)createWindowID:(NSString *)identity error:(NSError **)error {
  NSAssert(NSThread.isMainThread, @"Window creation requires the UI thread");
  identity = [identity copy];
  if (!_engine || _closingBrowser || !ValidID(identity) || _windows[identity] || [_retiredWindowIDs containsObject:identity]) {
    if (error) *error = BridgeError(@"Invalid or reused native window identity.");
    return NO;
  }
  ARCNativeWindowState *state = [[ARCNativeWindowState alloc] init];
  state.tabOrders = [NSMutableDictionary dictionary];
  state.tabPins = [NSMutableDictionary dictionary];
  state.identity = identity;
  state.native = [[NSClassFromString(@"ArdiaCoreWindow") alloc] initWithContentRect:NSMakeRect(0, 0, 1200, 780)];
  if (!state.native || !state.native.window) {
    if (error) *error = BridgeError(@"Chromium could not create the native window.");
    return NO;
  }
  state.native.delegate = self;
  _windows[identity] = state;
  __weak ARCChromiumRuntime *weakSelf = self;
  _windowCloseObservers[identity] = [NSNotificationCenter.defaultCenter addObserverForName:NSWindowWillCloseNotification
    object:state.native.window queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
      [weakSelf closedWindowID:identity];
    }];
  return YES;
}
- (BOOL)closeWindowID:(NSString *)identity {
  ARCNativeWindowState *state = _windows[identity];
  if (!state || state.closing || state.closed || _closingBrowser) return NO;
  state.closing = YES;
  [state.native close];
  return YES;
}
- (void)closedWindowID:(NSString *)identity {
  ARCNativeWindowState *state = _windows[identity];
  if (!state || state.closed) return;
  state.closed = YES;
  state.closing = YES;
  BOOL quitting = _closingBrowser;
  dispatch_async(dispatch_get_main_queue(), ^{
    for (NSString *requestID in [self->_pendingInstalls.allKeys copy]) {
      if ([self->_pendingInstalls[requestID][@"windowID"] isEqualToString:identity]) [self resolveInstallRequestID:requestID accepted:NO];
    }
    for (NSString *requestID in [self->_pendingMedia.allKeys copy]) {
      if ([self->_pendingMedia[requestID][@"windowID"] isEqualToString:identity]) [self resolveWebsiteMediaRequestID:requestID accepted:NO];
    }
    [self closeExtensionPopupForWindowID:identity];
    for (NSString *tabID in [self->_tabWindows.allKeys copy]) {
      if (![self->_tabWindows[tabID] isEqualToString:identity]) continue;
      [self->_pendingHostClosures removeObject:tabID];
      [self->_tabs removeObjectForKey:tabID];
      [self->_owners removeObjectForKey:tabID];
      [self->_tabWindows removeObjectForKey:tabID];
    }
    id observer = self->_windowCloseObservers[identity];
    if (observer) [NSNotificationCenter.defaultCenter removeObserver:observer];
    [self->_windowCloseObservers removeObjectForKey:identity];
    [self->_retiredWindowIDs addObject:identity];
    [self->_windows removeObjectForKey:identity];
    if (self->_onWindowClosed) self->_onWindowClosed(identity, quitting);
  });
}
- (void)dealloc {
  for (id observer in _windowCloseObservers.allValues) [NSNotificationCenter.defaultCenter removeObserver:observer];
}
- (NSString *)chromiumVersion { return _engine.chromiumVersion ?: @"unavailable"; }

- (void)loadProfileID:(NSString *)profileID completion:(void (^)(NSError *))completion {
  NSAssert(NSThread.isMainThread, @"Profile loading must run on the main thread");
  if (!ValidID(profileID) || !_engine) {
    completion(BridgeError(@"Invalid profile identity or engine not ready."));
    return;
  }
  if (_profiles[profileID]) { completion(nil); return; }
  if (_profileWaiters[profileID]) {
    [_profileWaiters[profileID] addObject:[completion copy]];
    return;
  }
  _profileWaiters[profileID] = [NSMutableArray arrayWithObject:[completion copy]];
  NSString *directory = [@"Profile " stringByAppendingString:profileID.lowercaseString];
  [_engine loadProfile:directory completion:^(ArdiaCoreProfile *profile) {
    NSError *error = nil;
    if (profile && !profile.offTheRecord && !profile.destroyed &&
        [self->_services bindProfileID:profileID path:profile.path error:&error]) {
      self->_profiles[profileID] = profile;
      if (self->_testing) [profile setBoolPreference:@"extensions.ui.developer_mode" value:YES];
      [self->_windows[self->_primaryWindowID].native prepareProfile:profile];
      [self->_libraryService watchProfileID:profileID];
      [self->_downloadService watchProfileID:profileID completion:^(NSArray *rows, NSError *failure) {
        if (failure) {
          if (self->_onNotice) self->_onNotice(failure.localizedDescription);
        } else if (self->_onDownloadsRestored) {
          self->_onDownloadsRestored(profileID, rows);
        }
      }];
    } else {
      error = error ?: BridgeError(@"Chromium could not load the requested persistent profile.");
    }
    NSArray *waiters = [self->_profileWaiters[profileID] copy];
    [self->_profileWaiters removeObjectForKey:profileID];
    for (void (^waiter)(NSError *) in waiters) waiter(error);
  }];
}

- (BOOL)openTabID:(NSString *)tabID profileID:(NSString *)profileID url:(NSString *)url
           error:(NSError **)error {
  return [self openTabID:tabID profileID:profileID windowID:_primaryWindowID url:url error:error];
}
- (BOOL)openTabID:(NSString *)tabID profileID:(NSString *)profileID windowID:(NSString *)windowID url:(NSString *)url
           error:(NSError **)error {
  NSAssert(NSThread.isMainThread, @"Tab creation must run on the main thread");
  ARCNativeWindowState *state = _windows[windowID];
  if (!state || state.closed || state.closing || _closingBrowser) {
    if (error) *error = BridgeError(@"The tab has no open native window.");
    return NO;
  }
  if (_tabs[tabID]) {
    BOOL matches = [_owners[tabID] isEqualToString:profileID] && [_tabWindows[tabID] isEqualToString:windowID];
    if (!matches && error) *error = BridgeError(@"A live tab cannot silently change its profile or native window.");
    return matches;
  }
  if (!ValidID(tabID) || !_profiles[profileID]) {
    if (error) *error = BridgeError(@"The tab has no loaded profile; refusing a default-profile fallback.");
    return NO;
  }
  _openingTabID = tabID;
  _openingProfileID = profileID;
  _openingWindowID = windowID;
  ArdiaCoreTab *tab = [state.native openTab:url profile:_profiles[profileID] foreground:NO];
  _openingTabID = nil;
  _openingProfileID = nil;
  _openingWindowID = nil;
  if (!tab) {
    if (error) *error = BridgeError(@"Chromium could not create the tab.");
    return NO;
  }
  _tabs[tabID] = tab;
  _owners[tabID] = profileID;
  _tabWindows[tabID] = windowID;
  tab.delegate = self;
  [self publish:tab];
  return YES;
}

- (NSString *)identityForTab:(ArdiaCoreTab *)tab {
  if (!tab) return nil;
  return [_tabs allKeysForObject:tab].firstObject;
}

- (void)publish:(ArdiaCoreTab *)tab {
  NSString *identity = [self identityForTab:tab];
  ARCNativeWindowState *state = identity ? [self stateForTabID:identity] : nil;
  if (!state || state.closing || state.closed || _closingBrowser) return;
  if (identity && _onTabChanged) {
    _onTabChanged(identity, tab.url ?: @"", tab.title ?: @"", tab.loading,
                  tab.canGoBack, tab.canGoForward);
  }
}

- (void)window:(ArdiaCoreWindow *)window didInsertTab:(ArdiaCoreTab *)tab
        opener:(ArdiaCoreTab *)opener disposition:(NSString *)disposition {
  ARCNativeWindowState *state = [self stateForWindow:window];
  if (!state || state.closing || state.closed || _closingBrowser) {
    dispatch_async(dispatch_get_main_queue(), ^{ [tab closeNow]; });
    return;
  }
  if (_openingTabID) {
    if (![state.identity isEqualToString:_openingWindowID]) return;
    _tabs[_openingTabID] = tab;
    _owners[_openingTabID] = _openingProfileID;
    _tabWindows[_openingTabID] = state.identity;
    tab.delegate = self;
    return;
  }
  NSString *existingID = [self identityForTab:tab];
  if (existingID) {
    BOOL newBrowser = state.awaitingBrowserTab;
    state.awaitingBrowserTab = NO;
    ARCNativeWindowState *original = [self stateForTabID:existingID];
    if (original == state) return;
    // An extension can request windows.create({tabId}) or tabs.move. Existing
    // live identities cannot acquire a second owner. Return the same document
    // after this notification, then restore its application's ordering/selection.
    dispatch_async(dispatch_get_main_queue(), ^{
      if (tab.closed || self->_closingBrowser) return;
      if (!original || original.closed || original.closing) {
        [tab closeNow];
        return;
      }
      [original.native adoptTab:tab];
      NSString *profileID = self->_owners[existingID];
      NSArray *order = original.tabOrders[profileID];
      if (order) [self placeTabIDs:order pinnedIDs:original.tabPins[profileID] ?: @[]
                        profileID:profileID windowID:original.identity];
      if (original.selectedTabID) [self activateTabID:original.selectedTabID];
      if (state.selectedTabID) [self activateTabID:state.selectedTabID];
      if (newBrowser && !state.closed && !state.closing) [self closeWindowID:state.identity];
      if (self->_onNotice) self->_onNotice(@"Moving live tabs between windows is not supported.");
    });
    return;
  }
  NSString *profileID = [_profiles allKeysForObject:tab.profile].firstObject;
  if (!profileID || state.rejectsEngineTabs) {
    dispatch_async(dispatch_get_main_queue(), ^{ [tab closeNow]; });
    return;
  }
  BOOL adopting = state.incomingTab == tab;
  BOOL browserFirstTab = state.awaitingBrowserTab;
  state.awaitingBrowserTab = NO;
  NSString *adoptedOpenerID = adopting ? state.incomingOpenerID : nil;
  if (adopting) {
    state.incomingTab = nil;
    state.incomingOpenerID = nil;
  }
  if (_onWindowRequest && !adopting && !browserFirstTab &&
      ([@[@"popup", @"window"] containsObject:disposition])) {
    NSString *openerID = [self identityForTab:opener];
    // Page popups are inserted in the source browser first. Adopt only this new,
    // unclaimed tab after the tab-strip notification; existing tab IDs never move.
    dispatch_async(dispatch_get_main_queue(), ^{
      if (tab.closed || state.closed || state.closing || self->_closingBrowser) return;
      NSString *targetID = self->_onWindowRequest ? self->_onWindowRequest(profileID,
        [disposition isEqualToString:@"popup"] ? @"popup" : @"normal") : nil;
      ARCNativeWindowState *target = targetID ? self->_windows[targetID] : nil;
      if (!target || target == state || target.closed || target.closing) {
        [tab closeNow];
        return;
      }
      target.incomingTab = tab;
      target.closeWhenEmpty = YES;
      target.incomingOpenerID = openerID;
      [target.native adoptTab:tab];
      NSString *identity = [self identityForTab:tab];
      if (!identity || ![self->_tabWindows[identity] isEqualToString:targetID]) {
        target.incomingTab = nil;
        target.incomingOpenerID = nil;
        [tab closeNow];
        [self closeWindowID:targetID];
        if (self->_onNotice) self->_onNotice(@"The requested page could not be adopted into its window.");
      } else if (self->_onWindowShowRequest) {
        self->_onWindowShowRequest(targetID, YES);
      }
    });
    return;
  }
  NSString *identity = NSUUID.UUID.UUIDString;
  _tabs[identity] = tab;
  _owners[identity] = profileID;
  _tabWindows[identity] = state.identity;
  tab.delegate = self;
  NSString *openerID = adoptedOpenerID ?: [self identityForTab:opener];
  dispatch_async(dispatch_get_main_queue(), ^{
    if (!tab.closed && !state.closing && !state.closed && self->_onNewTab) {
      self->_onNewTab(identity, profileID, tab.url.length ? tab.url : @"about:blank",
                     openerID, ![disposition isEqualToString:@"background_tab"]);
    }
  });
}

- (NSView *)viewForTabID:(NSString *)tabID { return _tabs[tabID].view; }
- (void)activateTabID:(NSString *)tabID {
  ArdiaCoreTab *tab = _tabs[tabID];
  ARCNativeWindowState *state = [self stateForTabID:tabID];
  if (!tab || tab.closed || !state || state.closing || state.closed || _closingBrowser) return;
  if (state.popup && ![state.popupOwnerTabID isEqualToString:tabID]) [self closeExtensionPopupForWindowID:state.identity];
  if (state.findTabID && ![state.findTabID isEqualToString:tabID]) [self stopFindingInTabID:state.findTabID];
  if (_testing && ![state.selectedTabID isEqualToString:tabID]) {
    [_tabs[state.selectedTabID ?: @""] noteShownByHost:NO];
    [tab noteShownByHost:YES];
  }
  state.selectedTabID = tabID;
  state.hostSelectionDepth++;
  state.native.activeProfile = tab.profile;
  [state.native activateTab:tab];
  state.hostSelectionDepth--;
}
- (void)window:(ArdiaCoreWindow *)window didActivateTab:(ArdiaCoreTab *)tab {
  ARCNativeWindowState *state = [self stateForWindow:window];
  NSString *identity = [self identityForTab:tab];
  NSString *profileID = identity ? _owners[identity] : nil;
  // Each profile has its own native tab strip. Initial/background-profile and
  // host-selected changes must not replace the visible application's selection.
  if (!state || state.closed || state.closing || _closingBrowser || state.hostSelectionDepth ||
      [_openingWindowID isEqualToString:state.identity] || !identity || !profileID || tab.closed ||
      ![_tabWindows[identity] isEqualToString:state.identity] ||
      state.native.activeProfile != tab.profile || [state.selectedTabID isEqualToString:identity]) return;
  if (_testing) {
    [_tabs[state.selectedTabID ?: @""] noteShownByHost:NO];
    [tab noteShownByHost:YES];
  }
  state.selectedTabID = identity;
  // Deliver model selection during the notification; clients must defer tab-strip
  // reconciliation until it unwinds. Otherwise an intervening metadata save can
  // re-activate the old model selection and erase the engine's activation.
  if (_onTabActivated) _onTabActivated(identity, profileID);
  if (state.findTabID && ![state.findTabID isEqualToString:state.selectedTabID]) [self stopFindingInTabID:state.findTabID];
  if (state.popup && ![state.popupOwnerTabID isEqualToString:state.selectedTabID]) [self closeExtensionPopupForWindowID:state.identity];
}
- (void)clearActiveTab {
  [self clearActiveTabInWindowID:_primaryWindowID];
}
- (void)clearActiveTabInWindowID:(NSString *)identity {
  ARCNativeWindowState *state = _windows[identity];
  if (!state || state.closed) return;
  if (state.findTabID) [self stopFindingInTabID:state.findTabID];
  if (_testing) [_tabs[state.selectedTabID ?: @""] noteShownByHost:NO];
  state.selectedTabID = nil;
  [self closeExtensionPopupForWindowID:identity];
}
- (void)closeTabID:(NSString *)tabID {
  ArdiaCoreTab *tab = _tabs[tabID];
  ARCNativeWindowState *state = [self stateForTabID:tabID];
  if (!tab || _closingBrowser || state.closed || state.closing) return;
  if (tab.closed) { [self tabWillClose:tab]; return; }
  [_pendingHostClosures addObject:tabID];
  [tab close];
}
- (void)focusTabID:(NSString *)tabID { [_tabs[tabID] focus]; }
- (void)discardTabID:(NSString *)tabID {
  // The model has already removed this tab or rejected its creation.
  ArdiaCoreTab *tab = _tabs[tabID];
  [_pendingHostClosures removeObject:tabID];
  [self stopFindingInTabID:tabID];
  [_tabs removeObjectForKey:tabID];
  [_owners removeObjectForKey:tabID];
  [_tabWindows removeObjectForKey:tabID];
  [tab closeNow];
}
- (void)activateProfileID:(NSString *)profileID {
  [self activateProfileID:profileID windowID:_primaryWindowID];
}
- (void)activateProfileID:(NSString *)profileID windowID:(NSString *)identity {
  ARCNativeWindowState *state = _windows[identity];
  if (_profiles[profileID] && state && !state.closed && !state.closing && !_closingBrowser) {
    state.hostSelectionDepth++;
    state.native.activeProfile = _profiles[profileID];
    state.hostSelectionDepth--;
  }
}
- (void)goBackInTabID:(NSString *)tabID { [_tabs[tabID] goBack]; }
- (void)goForwardInTabID:(NSString *)tabID { [_tabs[tabID] goForward]; }
- (void)reloadTabID:(NSString *)tabID { [_tabs[tabID] reload]; }
- (BOOL)reloadTabID:(NSString *)tabID profileID:(NSString *)profileID {
  ArdiaCoreTab *tab = _tabs[tabID];
  if (!tab || tab.closed || ![self isSelectedTabID:tabID] ||
      ![_owners[tabID] isEqualToString:profileID]) return NO;
  [tab reload];
  return YES;
}
- (BOOL)placeTabIDs:(NSArray<NSString *> *)tabIDs pinnedIDs:(NSArray<NSString *> *)pinnedIDs
         profileID:(NSString *)profileID {
  return [self placeTabIDs:tabIDs pinnedIDs:pinnedIDs profileID:profileID windowID:_primaryWindowID];
}
- (BOOL)placeTabIDs:(NSArray<NSString *> *)tabIDs pinnedIDs:(NSArray<NSString *> *)pinnedIDs
         profileID:(NSString *)profileID windowID:(NSString *)windowID {
  ARCNativeWindowState *state = _windows[windowID];
  NSSet *identities = [NSSet setWithArray:tabIDs];
  NSSet *pins = [NSSet setWithArray:pinnedIDs];
  ArdiaCoreProfile *profile = _profiles[profileID];
  if (!state || state.closed || state.closing || !profile || profile.destroyed || profile.offTheRecord || identities.count != tabIDs.count ||
      pins.count != pinnedIDs.count || ![pins isSubsetOfSet:identities]) return NO;
  BOOL seenUnpinned = NO;
  for (NSString *identity in tabIDs) {
    ArdiaCoreTab *tab = _tabs[identity];
    BOOL pinned = [pins containsObject:identity];
    if (!tab || tab.closed || tab.profile != profile || ![_tabWindows[identity] isEqualToString:windowID] || ![_owners[identity] isEqualToString:profileID] ||
        (pinned && seenUnpinned)) return NO;
    if (!pinned) seenUnpinned = YES;
  }
  // Set all pin states before the final ordering pass: Chromium constrains
  // pinned indices, so unpinning several tabs during one pass can shift earlier moves.
  state.hostSelectionDepth++;
  for (int pass = 0; pass < 2; pass++) {
    [tabIDs enumerateObjectsUsingBlock:^(NSString *identity, NSUInteger index, BOOL *stop) {
      [state.native placeTab:self->_tabs[identity] index:(int)index pinned:[pins containsObject:identity]];
    }];
  }
  state.hostSelectionDepth--;
  state.tabOrders[profileID] = [tabIDs copy];
  state.tabPins[profileID] = [pinnedIDs copy];
  return YES;
}
- (void)downloadCommand:(NSString *)command downloadID:(NSString *)downloadID profileID:(NSString *)profileID
            completion:(void (^)(NSError *))completion {
  if (!_profiles[profileID] || _profiles[profileID].destroyed || _profiles[profileID].offTheRecord) {
    completion(BridgeError(@"Unknown download profile."));
    return;
  }
  [_downloadService command:command downloadID:downloadID profileID:profileID completion:completion];
}
- (void)refreshDownloadsForProfileID:(NSString *)profileID {
  ArdiaCoreProfile *profile = _profiles[profileID];
  if (!profile || profile.destroyed || profile.offTheRecord) return;
  [_downloadService watchProfileID:profileID completion:^(NSArray *rows, NSError *error) {
    if (error) {
      if (self->_onNotice) self->_onNotice(error.localizedDescription);
    } else if (self->_onDownloadsRestored) {
      self->_onDownloadsRestored(profileID, rows);
    }
  }];
}

- (void)bookmarksForProfileID:(NSString *)profileID completion:(void (^)(NSDictionary *, NSError *))completion {
  [_libraryService bookmarksForProfileID:profileID completion:completion];
}
- (void)applyBookmarkOperation:(NSDictionary *)operation profileID:(NSString *)profileID completion:(void (^)(NSError *))completion {
  [_libraryService applyBookmarkOperation:operation profileID:profileID completion:completion];
}
- (void)historyForProfileID:(NSString *)profileID limit:(NSInteger)limit completion:(void (^)(NSArray<NSDictionary *> *, NSError *))completion {
  [_libraryService historyForProfileID:profileID limit:limit completion:completion];
}
- (void)deleteHistoryURL:(NSString *)url profileID:(NSString *)profileID completion:(void (^)(NSError *))completion {
  [_libraryService deleteHistoryURL:url profileID:profileID completion:completion];
}
- (BOOL)findInTabID:(NSString *)tabID profileID:(NSString *)profileID requestID:(NSString *)requestID
              text:(NSString *)text forward:(BOOL)forward {
  ArdiaCoreTab *tab = _tabs[tabID];
  ARCNativeWindowState *state = [self stateForTabID:tabID];
  if (!tab || tab.closed || !text.length || !ValidID(requestID) ||
      ![self isSelectedTabID:tabID] || ![_owners[tabID] isEqualToString:profileID]) return NO;
  if (state.findTabID && ![state.findTabID isEqualToString:tabID]) [self stopFindingInTabID:state.findTabID];
  // A new query starts a new Chromium find session. Its helper rejects replies
  // from an aborted session; the native token also gates the SwiftUI state.
  if (![state.findText isEqualToString:text]) {
    state.findRequestID = nil;
    [tab find:@"" forward:YES];
  }
  state.findTabID = tabID;
  state.findRequestID = requestID;
  state.findText = text;
  [tab find:text forward:forward];
  return YES;
}
- (void)stopFindingInTabID:(NSString *)tabID {
  ARCNativeWindowState *state = [self stateForTabID:tabID];
  if (![state.findTabID isEqualToString:tabID]) return;
  state.findTabID = nil;
  state.findRequestID = nil;
  state.findText = nil;
  ArdiaCoreTab *tab = _tabs[tabID];
  if (tab && !tab.closed) {
    [tab find:@"" forward:YES];
    [tab stopFinding];
  }
}
- (void)evaluateInTabID:(NSString *)tabID script:(NSString *)script
            completion:(void (^)(NSString *))completion {
  [self evaluateTab:_tabs[tabID] script:script completion:completion];
}
- (void)evaluateTab:(ArdiaCoreTab *)tab script:(NSString *)script completion:(void (^)(NSString *))completion {
  [self evaluateTab:tab script:script userGesture:NO completion:completion];
}
- (void)evaluateProbeUserGestureInTabID:(NSString *)tabID script:(NSString *)script completion:(void (^)(NSString *))completion {
  if (!_testing) { completion(nil); return; }
  [self evaluateTab:_tabs[tabID] script:script userGesture:YES completion:completion];
}
- (void)evaluateTab:(ArdiaCoreTab *)tab script:(NSString *)script userGesture:(BOOL)userGesture completion:(void (^)(NSString *))completion {
  if (!tab || tab.closed) { completion(nil); return; }
  __block BOOL answered = NO;
  void (^reply)(NSString *) = ^(NSString *json) {
    if (answered) return;
    answered = YES;
    completion(json);
  };
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
    reply(nil);
  });
  // ArdiaCore expects a named message whose payload is an already serialized JSON string.
  [tab evaluate:[NSString stringWithFormat:@"post('result', JSON.stringify(%@));", script]
      userGesture:userGesture completion:reply];
}
- (void)quit { _closingBrowser = YES; [_engine quit]; }
- (void)engineQuitCancelled {
  _closingBrowser = NO;
  for (ARCNativeWindowState *state in _windows.allValues) if (!state.closed) state.closing = NO;
}
- (void)engineWillShutDown { _closingBrowser = YES; }
- (BOOL)windowShouldClose:(ArdiaCoreWindow *)window {
  ARCNativeWindowState *state = [self stateForWindow:window];
  if (!state || state.closed) return NO;
  state.closing = YES;
  return YES;
}
- (void)windowDidCancelClose:(ArdiaCoreWindow *)window {
  ARCNativeWindowState *state = [self stateForWindow:window];
  if (!state.closed) state.closing = NO;
}

- (void)window:(ArdiaCoreWindow *)window didRemoveTab:(ArdiaCoreTab *)tab {
  NSString *identity = [self identityForTab:tab];
  ARCNativeWindowState *state = [self stateForWindow:window];
  if (!state || !identity || ![_tabWindows[identity] isEqualToString:state.identity] || ![_pendingHostClosures containsObject:identity]) return;
  // The pinned API suppresses tabWillClose for host-initiated closes. Observe
  // removal, then confirm destruction after the tab-strip notification unwinds.
  // A canceled beforeunload or a live tab detached elsewhere is not a closure.
  dispatch_async(dispatch_get_main_queue(), ^{
    if (self->_closingBrowser || state.closing || state.closed || self->_tabs[identity] != tab ||
        ![self->_pendingHostClosures containsObject:identity]) return;
    [self->_pendingHostClosures removeObject:identity];
    if (tab.closed) [self tabWillClose:tab];
  });
}
- (NSArray<NSDictionary<NSString *, id> *> *)extensionsForProfileID:(NSString *)profileID {
  NSMutableArray *result = [NSMutableArray arrayWithArray:_profiles[profileID].extensions ?: @[]];
  if (_testing) [result addObjectsFromArray:_probeExtensions[profileID] ?: @[]];
  return result;
}

- (void)resolveInstallRequestID:(NSString *)requestID accepted:(BOOL)accepted {
  NSDictionary *request = _pendingInstalls[requestID];
  if (!request) return;
  [_pendingInstalls removeObjectForKey:requestID];
  NSString *tabID = request[@"tabID"];
  BOOL contextMatches = [_owners[tabID] isEqualToString:request[@"profileID"]] &&
    [_tabWindows[tabID] isEqualToString:request[@"windowID"]] &&
    [self isSelectedTabID:tabID] && [_tabs[tabID].url isEqualToString:request[@"sourceURL"]];
  [_engineClass resolveExtensionInstallPrompt:requestID accepted:accepted && contextMatches];
}
- (void)resolveWebsiteMediaRequestID:(NSString *)requestID accepted:(BOOL)accepted {
  NSDictionary *request = _pendingMedia[requestID];
  if (!request) return;
  [_pendingMedia removeObjectForKey:requestID];
  NSString *tabID = request[@"tabID"];
  NSArray *kinds = request[@"permissions"];
  BOOL supported = [kinds isKindOfClass:NSArray.class] && kinds.count > 0 && kinds.count <= 2;
  if (supported) {
    for (NSString *kind in kinds) supported &= [@[@"camera", @"microphone"] containsObject:kind];
  }
  BOOL current = [self isSelectedTabID:tabID] &&
    [_tabWindows[tabID] isEqualToString:request[@"windowID"]] &&
    [_owners[tabID] isEqualToString:request[@"profileID"]] &&
    [_tabs[tabID].url isEqualToString:request[@"pageURL"]];
  [_engine resolvePermission:requestID result:accepted && current && supported ? @"accept" : @"deny" remember:NO];
}

- (BOOL)showPopupForExtension:(NSString *)extensionID tabID:(NSString *)tabID error:(NSError **)error {
  ArdiaCoreTab *owner = _tabs[tabID];
  ARCNativeWindowState *state = [self stateForTabID:tabID];
  if (!ValidExtensionID(extensionID) || !owner || owner.closed || ![self isSelectedTabID:tabID]) {
    if (error) *error = BridgeError(@"Extension actions require the selected tab in its owning profile.");
    return NO;
  }
  NSDictionary *action = [owner actionStatesForExtensions:@[extensionID]][extensionID];
  NSURL *url = [NSURL URLWithString:action[@"popup"] ?: @""];
  if (![[url scheme] isEqualToString:@"chrome-extension"] || ![url.host isEqualToString:extensionID] ||
      url.user || url.password || url.port) {
    if (error) *error = BridgeError(@"The extension has no valid popup for this tab and profile.");
    return NO;
  }
  if (state.popup && [state.popupOwnerTabID isEqualToString:tabID] && [state.popupExtensionID isEqualToString:extensionID]) return YES;
  [self closeExtensionPopupForWindowID:state.identity];
  ArdiaCoreTab *popup = [state.native openExtensionView:url.absoluteString profile:owner.profile kind:@"popup"];
  if (!popup || popup.profile != owner.profile) {
    [popup closeNow];
    if (error) *error = BridgeError(@"The extension popup could not be opened in its owning profile.");
    return NO;
  }
  state.popup = popup;
  state.popupID = NSUUID.UUID.UUIDString;
  state.popupOwnerTabID = tabID;
  state.popupExtensionID = extensionID;
  popup.delegate = self;
  if (_onExtensionPopup) _onExtensionPopup(@{
    @"id": state.popupID, @"tabID": tabID, @"profileID": _owners[tabID], @"extensionID": extensionID, @"windowID": state.identity
  });
  return YES;
}

- (BOOL)executeExtensionID:(NSString *)extensionID tabID:(NSString *)tabID error:(NSError **)error {
  ArdiaCoreTab *tab = _tabs[tabID];
  NSDictionary *state = ValidExtensionID(extensionID) && tab ? [tab actionStatesForExtensions:@[extensionID]][extensionID] : nil;
  if (!ValidExtensionID(extensionID) || !tab || tab.closed || ![self isSelectedTabID:tabID] ||
      ![state[@"enabled"] boolValue]) {
    if (error) *error = BridgeError(@"This extension action is unavailable in the selected profile.");
    return NO;
  }
  NSString *route = [tab executeExtensionAction:extensionID];
  if ([route isEqualToString:@"popup"]) return [self showPopupForExtension:extensionID tabID:tabID error:error];
  if ([route isEqualToString:@"sidePanel"]) {
    if (error) *error = BridgeError(@"Extension side panels are not available yet.");
    return NO;
  }
  return YES;
}

- (NSView *)viewForExtensionPopupID:(NSString *)popupID {
  ARCNativeWindowState *state = [self stateForPopupID:popupID];
  return state.closed ? nil : state.popup.view;
}

- (void)closeExtensionPopup {
  [self closeExtensionPopupForWindowID:_primaryWindowID];
}
- (void)closeExtensionPopupForWindowID:(NSString *)windowID {
  ARCNativeWindowState *state = _windows[windowID];
  ArdiaCoreTab *tab = state.popup;
  NSString *identity = state.popupID;
  state.popup = nil;
  state.popupID = nil;
  state.popupOwnerTabID = nil;
  state.popupExtensionID = nil;
  [tab closeNow];
  if (identity && _onExtensionPopupClosed) _onExtensionPopupClosed(identity);
}

- (NSString *)loadProbeExtensionAtURL:(NSURL *)url profileID:(NSString *)profileID error:(NSError **)error {
  NSURL *resolved = url.URLByStandardizingPath.URLByResolvingSymlinksInPath;
  NSString *prefix = [_probeRoot.path stringByAppendingString:@"/"];
  if (!_testing || !prefix || ![resolved.path hasPrefix:prefix] || !_profiles[profileID]) {
    if (error) *error = BridgeError(@"Component loading is restricted to disposable probe profiles.");
    return nil;
  }
  NSString *identity = [_profiles[profileID] loadComponentExtension:resolved.path];
  if (!identity) {
    if (error) *error = BridgeError(@"The MV3 probe extension could not be loaded.");
    return nil;
  }
  if (!_probeExtensions[profileID]) _probeExtensions[profileID] = [NSMutableArray array];
  NSData *manifestData = [NSData dataWithContentsOfURL:[resolved URLByAppendingPathComponent:@"manifest.json"]];
  NSDictionary *manifest = manifestData ? [NSJSONSerialization JSONObjectWithData:manifestData options:0 error:nil] : nil;
  [_probeExtensions[profileID] addObject:@{@"id": identity, @"name": manifest[@"name"] ?: @"Probe extension",
                                         @"version": manifest[@"version"] ?: @"unknown"}];
  return identity;
}

- (void)evaluateProbePopupID:(NSString *)popupID script:(NSString *)script completion:(void (^)(NSString *))completion {
  ARCNativeWindowState *state = [self stateForPopupID:popupID];
  if (!_testing || !state || state.closed) { completion(nil); return; }
  [self evaluateTab:state.popup script:script completion:completion];
}
- (void)captureProbeTabID:(NSString *)tabID completion:(void (^)(NSData *))completion {
  [self captureProbeTab:_tabs[tabID] completion:completion];
}
- (void)clickProbePopupID:(NSString *)popupID buttonTitle:(NSString *)title completion:(void (^)(BOOL))completion {
  ARCNativeWindowState *state = [self stateForPopupID:popupID];
  if (!_testing || !state || state.closed || !state.popup || state.popup.closed) {
    completion(NO);
    return;
  }
  NSData *encoded = [NSJSONSerialization dataWithJSONObject:title options:NSJSONWritingFragmentsAllowed error:nil];
  NSString *literal = encoded ? [[NSString alloc] initWithData:encoded encoding:NSUTF8StringEncoding] : nil;
  if (!literal) { completion(NO); return; }
  NSString *expression = [NSString stringWithFormat:
    @"(()=>{const button=[...document.querySelectorAll('button,a,[role=button]')].find(b=>"
     "b.innerText.trim().replace(/\\s+/g,' ')===%@ && b.getBoundingClientRect().width>0 && b.getBoundingClientRect().height>0 && !b.disabled);"
     "if(!button)return null;button.scrollIntoView({block:'center'});const r=button.getBoundingClientRect();"
     "return {x:r.x+r.width/2,y:r.y+r.height/2};})()", literal];
  ArdiaCoreTab *popup = state.popup;
  ClickProbeTarget(popup, expression, ^BOOL { return !state.closed && [state.popupID isEqualToString:popupID]; }, completion);
}
- (void)clickProbeElementInTabID:(NSString *)tabID elementID:(NSString *)elementID completion:(void (^)(BOOL))completion {
  ArdiaCoreTab *tab = _tabs[tabID];
  if (!_testing || !tab || tab.closed || ![self isSelectedTabID:tabID] || elementID.length > 128) {
    completion(NO);
    return;
  }
  NSData *data = [NSJSONSerialization dataWithJSONObject:elementID options:NSJSONWritingFragmentsAllowed error:nil];
  NSString *literal = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
  if (!literal) { completion(NO); return; }
  NSString *expression = [NSString stringWithFormat:
    @"(()=>{const e=document.getElementById(%@);if(!e)return null;e.scrollIntoView({block:'center'});"
     "const r=e.getBoundingClientRect();return r.width>0&&r.height>0?{x:r.x+r.width/2,y:r.y+r.height/2}:null;})()", literal];
  ClickProbeTarget(tab, expression, ^BOOL {
    return !tab.closed && self->_tabs[tabID] == tab && [self isSelectedTabID:tabID];
  }, completion);
}
- (void)captureProbePopupID:(NSString *)popupID completion:(void (^)(NSData *))completion {
  ARCNativeWindowState *state = [self stateForPopupID:popupID];
  if (!state || state.closed) { completion(nil); return; }
  [self captureProbeTab:state.popup completion:completion];
}
- (void)probeTLSResourceURL:(NSURL *)url tabID:(NSString *)tabID completion:(void (^)(NSDictionary *))completion {
  ArdiaCoreTab *tab = _tabs[tabID];
  if (!_testing || !_probeTLS || !tab || tab.closed || ![self isSelectedTabID:tabID] ||
      ![url.scheme isEqualToString:@"https"] || ![url.host isEqualToString:@"127.0.0.1"] ||
      !url.port || url.port.integerValue < 1 || url.port.integerValue > 65535 ||
      url.user || url.password || url.query || url.fragment ||
      ![@[@"/alive", @"/icons/arcusis-fixture.invalid/icon.png"] containsObject:url.path]) {
    completion(@{@"failureStage": @"context", @"testing": @(_testing), @"tlsEnabled": @(_probeTLS),
                 @"tabAvailable": @(tab && !tab.closed), @"selected": @([self isSelectedTabID:tabID])});
    return;
  }
  [tab devToolsCall:@"Page.getFrameTree" params:@{} timeout:5 completion:^(NSDictionary *tree, NSString *error) {
    NSString *frame = tree[@"frameTree"][@"frame"][@"id"];
    if (error || ![frame isKindOfClass:NSString.class] || tab.closed || ![self isSelectedTabID:tabID]) {
      completion(@{@"failureStage": @"frame", @"commandFailed": @(error != nil),
                   @"frameAvailable": @([frame isKindOfClass:NSString.class])});
      return;
    }
    [tab devToolsCall:@"Network.loadNetworkResource"
      params:@{@"frameId": frame, @"url": url.absoluteString,
               @"options": @{@"disableCache": @YES, @"includeCredentials": @NO}}
      timeout:5 completion:^(NSDictionary *result, NSString *loadError) {
        NSDictionary *resource = result[@"resource"];
        if (loadError || ![resource isKindOfClass:NSDictionary.class] || tab.closed || ![self isSelectedTabID:tabID]) {
          completion(@{@"failureStage": @"resource", @"commandFailed": @(loadError != nil),
                       @"resourceAvailable": @([resource isKindOfClass:NSDictionary.class])});
          return;
        }
        NSMutableDictionary *safe = [NSMutableDictionary dictionary];
        for (NSString *key in @[@"success", @"netError", @"netErrorName", @"httpStatusCode"]) {
          id value = resource[key];
          if ([value isKindOfClass:NSNumber.class] || [value isKindOfClass:NSString.class]) safe[key] = value;
        }
        NSString *stream = resource[@"stream"];
        if ([stream isKindOfClass:NSString.class]) {
          [tab devToolsCall:@"IO.close" params:@{@"handle": stream} timeout:5
            completion:^(NSDictionary *ignored, NSString *closeError) {
              // Ardia detaches an idle CDP client before delivering its reply. Chromium
              // discards that client's streams; a later close can confirm it is gone.
              BOOL released = !closeError || [closeError isEqualToString:@"Invalid stream handle"];
              completion(!released || tab.closed || ![self isSelectedTabID:tabID]
                ? @{@"failureStage": @"stream-close"} : safe);
            }];
        } else completion(safe);
      }];
  }];
}
- (int)nativeTabIDForID:(NSString *)tabID { return _tabs[tabID] ? _tabs[tabID].tabId : -1; }
- (BOOL)crashProbeTabID:(NSString *)tabID {
  ArdiaCoreTab *tab = _tabs[tabID];
  NSURL *url = tab ? [NSURL URLWithString:tab.url] : nil;
  if (!_testing || !tab || tab.closed || ![@[@"127.0.0.1", @"localhost"] containsObject:url.host] ||
      ![url.scheme isEqualToString:@"http"] || ![url.path hasPrefix:@"/renderer-crash-"]) return NO;
  // The target may disappear before CDP can acknowledge Page.crash; the renderer callback is the evidence.
  [tab devToolsCall:@"Page.crash" params:@{} timeout:5 completion:^(NSDictionary *result, NSString *error) {}];
  return YES;
}
- (void)captureProbeTab:(ArdiaCoreTab *)tab completion:(void (^)(NSData *))completion {
  if (!_testing || !tab || tab.closed) { completion(nil); return; }
  [tab devToolsCall:@"Page.captureScreenshot"
             params:@{@"format": @"png", @"captureBeyondViewport": @YES}
            timeout:5
         completion:^(NSDictionary *result, NSString *error) {
    NSString *base64 = result[@"data"];
    completion(base64 ? [[NSData alloc] initWithBase64EncodedString:base64 options:0] : nil);
  }];
}
- (void)tabDidChangeTitle:(ArdiaCoreTab *)tab { [self publish:tab]; }
- (void)tabDidChangeURL:(ArdiaCoreTab *)tab { [self publish:tab]; }
- (void)tabDidChangeLoading:(ArdiaCoreTab *)tab { [self publish:tab]; }
- (void)tabDidChangeNavigationState:(ArdiaCoreTab *)tab { [self publish:tab]; }
- (void)tab:(ArdiaCoreTab *)tab rendererGone:(NSString *)status code:(int)code {
  ARCNativeWindowState *popupState = [self stateForPopupTab:tab];
  if (popupState) {
    [self closeExtensionPopupForWindowID:popupState.identity];
    if (_onNotice) _onNotice(@"The extension stopped working. Open it again to retry.");
    return;
  }
  NSString *identity = [self identityForTab:tab];
  NSString *profile = identity ? _owners[identity] : nil;
  if (!identity || !profile || tab.closed) return;
  [self stopFindingInTabID:identity];
  if (_onRendererGone) _onRendererGone(identity, profile, status, code);
}
- (void)tabDidCommitDocument:(ArdiaCoreTab *)tab {
  NSString *identity = [self identityForTab:tab];
  NSString *profile = identity ? _owners[identity] : nil;
  if (identity && profile && !tab.closed && _onDocumentCommitted) _onDocumentCommitted(identity, profile);
}
- (void)tab:(ArdiaCoreTab *)tab didFindMatches:(int)count active:(int)active final:(BOOL)final {
  NSString *identity = [self identityForTab:tab];
  ARCNativeWindowState *state = [self stateForTabID:identity];
  if (state.findRequestID && [identity isEqualToString:state.findTabID] &&
      [self isSelectedTabID:identity] && _onFindResult) {
    _onFindResult(identity, state.findRequestID, count, active, final);
  }
}
- (void)tab:(ArdiaCoreTab *)tab didChangeMediaAccess:(NSDictionary<NSString *, NSNumber *> *)access {
  NSString *identity = [self identityForTab:tab];
  if (identity && _onMediaAccess) _onMediaAccess(identity, access);
}
- (void)tab:(ArdiaCoreTab *)tab preferredSizeDidChange:(NSSize)size {
  ARCNativeWindowState *state = [self stateForPopupTab:tab];
  if (state.popupID && !state.closed && _onExtensionPopupSize) _onExtensionPopupSize(state.popupID, size);
}
- (void)tab:(ArdiaCoreTab *)tab didReceivePageMessage:(NSString *)kind json:(NSString *)json {
  if (!_testing || ![kind isEqualToString:@"arcusisProbeDiagnostic"] || _probeDiagnostics.count >= 100 ||
      ![tab.url hasPrefix:@"chrome-extension://nngceckbapebfimnlniiiahkandclblb/"]) return;
  NSData *data = [json dataUsingEncoding:NSUTF8StringEncoding];
  id event = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
  if (![event isKindOfClass:NSDictionary.class]) return;
  [_probeDiagnostics addObject:event];
  NSData *report = [NSJSONSerialization dataWithJSONObject:_probeDiagnostics options:NSJSONWritingPrettyPrinted error:nil];
  [report writeToURL:[_probeRoot URLByAppendingPathComponent:@"bitwarden-renderer-errors.json"] atomically:YES];
}
- (void)tabWillClose:(ArdiaCoreTab *)tab {
  ARCNativeWindowState *popupState = [self stateForPopupTab:tab];
  if (popupState) {
    NSString *identity = popupState.popupID;
    popupState.popup = nil;
    popupState.popupID = nil;
    popupState.popupOwnerTabID = nil;
    popupState.popupExtensionID = nil;
    if (identity && _onExtensionPopupClosed) _onExtensionPopupClosed(identity);
    return;
  }
  NSString *identity = [self identityForTab:tab];
  if (!identity) return;
  ARCNativeWindowState *state = [self stateForTabID:identity];
  BOOL notify = !_closingBrowser && !state.closing && !state.closed;
  [_pendingHostClosures removeObject:identity];
  [self stopFindingInTabID:identity];
  if ([state.selectedTabID isEqualToString:identity]) state.selectedTabID = nil;
  [_tabs removeObjectForKey:identity];
  [_owners removeObjectForKey:identity];
  [_tabWindows removeObjectForKey:identity];
  dispatch_async(dispatch_get_main_queue(), ^{
    if (notify && self->_onTabClosed) self->_onTabClosed(identity);
    if (notify && state.closeWhenEmpty && !state.closing && !state.closed &&
        ![self->_tabWindows.allValues containsObject:state.identity]) {
      [self closeWindowID:state.identity];
    }
  });
}
- (ArdiaCoreWindow *)engineWindowForNewBrowserOfProfile:(ArdiaCoreProfile *)profile type:(NSString *)type {
  NSString *profileID = [_profiles allKeysForObject:profile].firstObject;
  if (_closingBrowser) return nil;
  if (_onWindowRequest) {
    NSString *identity = profileID && !profile.offTheRecord && !profile.destroyed ? _onWindowRequest(profileID, type) : nil;
    ARCNativeWindowState *state = identity ? _windows[identity] : nil;
    if (state && !state.closed && !state.closing) {
      state.awaitingBrowserTab = YES;
      state.closeWhenEmpty = YES;
      return state.native;
    }
    // Returning nil lets Chromium build an unmanaged stock window. Instead host
    // unsupported/private requests briefly in an unseen, unsaved sink and close
    // it after the synchronous browser-creation notification has unwound.
    NSString *rejectedID = NSUUID.UUID.UUIDString;
    if (![self createWindowID:rejectedID error:nil]) return nil;
    ARCNativeWindowState *rejected = _windows[rejectedID];
    rejected.native.internal = YES;
    rejected.rejectsEngineTabs = YES;
    rejected.awaitingBrowserTab = YES;
    rejected.closeWhenEmpty = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
      [self closeWindowID:rejectedID];
      if (self->_onNotice) self->_onNotice(@"This browser window type or profile is unavailable.");
    });
    return rejected.native;
  }
  if (!profileID || profile.offTheRecord || profile.destroyed) return nil;
  // Legacy disposable clients do not install a managed host.
  for (ARCNativeWindowState *state in _windows.allValues) {
    if (!state.closed && !state.closing && state.native.window.isKeyWindow) return state.native;
  }
  ARCNativeWindowState *primary = _windows[_primaryWindowID];
  return primary.closed || primary.closing ? nil : primary.native;
}
- (void)window:(ArdiaCoreWindow *)window showRequestedActive:(BOOL)active {
  ARCNativeWindowState *state = [self stateForWindow:window];
  if (state && !state.closed && !state.closing && !state.rejectsEngineTabs && !_closingBrowser && _onWindowShowRequest) {
    _onWindowShowRequest(state.identity, active);
  }
}
- (void)engine:(ArdiaCoreEngine *)engine permissionRequest:(NSDictionary *)request tab:(ArdiaCoreTab *)tab {
  NSString *identity = request[@"id"];
  NSString *tabID = [self identityForTab:tab];
  NSString *profileID = tabID ? _owners[tabID] : nil;
  if (!identity.length || !profileID || ![self isSelectedTabID:tabID] || !_onWebsiteMediaRequest ||
      _pendingMedia.count >= 10) {
    if (identity) [engine resolvePermission:identity result:@"deny" remember:NO];
    return;
  }
  NSMutableDictionary *bound = request.mutableCopy;
  bound[@"tabID"] = tabID;
  bound[@"profileID"] = profileID;
  bound[@"windowID"] = _tabWindows[tabID];
  bound[@"pageURL"] = tab.url ?: @"";
  _pendingMedia[identity] = bound;
  _onWebsiteMediaRequest(bound);
}
- (void)engine:(ArdiaCoreEngine *)engine permissionRequestDismissed:(NSString *)requestID {
  [_pendingMedia removeObjectForKey:requestID];
  if (_onWebsiteMediaDismissed) _onWebsiteMediaDismissed(requestID);
}
- (void)engine:(ArdiaCoreEngine *)engine extensionInstallPrompt:(NSDictionary *)prompt tab:(ArdiaCoreTab *)tab {
  NSString *identity = prompt[@"requestId"];
  NSString *tabID = [self identityForTab:tab];
  if (!tabID) tabID = [self stateForPopupTab:tab].popupOwnerTabID;
  NSString *profileID = tabID ? _owners[tabID] : nil;
  NSString *directory = profileID ? _profiles[profileID].path.lastPathComponent : nil;
  if (!identity.length || !profileID || ![directory isEqualToString:prompt[@"profile"]] ||
      ![self isSelectedTabID:tabID] || !_onInstallRequest || _pendingInstalls.count >= 10) {
    if (identity) [_engineClass resolveExtensionInstallPrompt:identity accepted:NO];
    if (_onNotice) _onNotice(@"The extension request has no active profile context and was canceled.");
    return;
  }
  NSMutableDictionary *request = prompt.mutableCopy;
  request[@"profileID"] = profileID;
  request[@"tabID"] = tabID;
  request[@"windowID"] = _tabWindows[tabID];
  request[@"sourceURL"] = _tabs[tabID].url ?: @"";
  _pendingInstalls[identity] = request;
  [self closeExtensionPopupForWindowID:_tabWindows[tabID]];
  _onInstallRequest(request);
}
- (BOOL)engine:(ArdiaCoreEngine *)engine extensionActionPopup:(NSDictionary *)popup tab:(ArdiaCoreTab *)tab {
  NSString *identity = [self identityForTab:tab];
  return identity ? [self showPopupForExtension:popup[@"extensionId"] tabID:identity error:nil] : NO;
}
- (BOOL)engineIsReservedKeyEvent:(NSEvent *)event {
  return ARCReservedBrowserShortcut(event.charactersIgnoringModifiers ?: @"", event.modifierFlags);
}
- (void)window:(ArdiaCoreWindow *)window confirmCloseWithDownloads:(int)count completion:(void (^)(BOOL))completion {
  // Tests must resolve their own transfers before shutdown, without opening a dialog.
  if (_testing) { completion(NO); return; }
  NSAlert *alert = [[NSAlert alloc] init];
  alert.messageText = @"Downloads are still running";
  alert.informativeText = [NSString stringWithFormat:@"Closing the browser will cancel %d active download%@.", count, count == 1 ? @"" : @"s"];
  [alert addButtonWithTitle:@"Keep Browser Open"];
  NSButton *quit = [alert addButtonWithTitle:@"Close and Cancel Downloads"];
  quit.hasDestructiveAction = YES;
  [alert beginSheetModalForWindow:window.window completionHandler:^(NSModalResponse response) {
    completion(response == NSAlertSecondButtonReturn);
  }];
}
- (BOOL)engineIsReservedKey:(NSString *)key unshiftedKey:(NSString *)unshiftedKey modifiers:(NSEventModifierFlags)modifiers {
  return ARCReservedBrowserShortcut(unshiftedKey.length ? unshiftedKey : key, modifiers);
}
@end
