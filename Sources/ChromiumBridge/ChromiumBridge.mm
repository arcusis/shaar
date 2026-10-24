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
    return [@[@"t", @"l", @"w", @"s", @"q", @"r", @"f", @"g", @"d", @"y"] containsObject:key.lowercaseString];
  }
  if (chord == (NSEventModifierFlagCommand | NSEventModifierFlagShift)) {
    return [@[@"g", @"j", @"t"] containsObject:key.lowercaseString];
  }
  return chord == (NSEventModifierFlagControl | NSEventModifierFlagOption) &&
    [@[@"[", @"]"] containsObject:key];
}

@interface ARCChromiumRuntime () <ArdiaCoreEngineDelegate, ArdiaCoreWindowDelegate,
                                ArdiaCoreTabDelegate>
@end

@implementation ARCChromiumRuntime {
  void *_library;
  Class _engineClass;
  ArdiaCoreEngine *_engine;
  ArdiaCoreWindow *_browserWindow;
  NSMutableDictionary<NSString *, ArdiaCoreProfile *> *_profiles;
  NSMutableDictionary<NSString *, ArdiaCoreTab *> *_tabs;
  NSMutableDictionary<NSString *, NSString *> *_owners;
  NSMutableDictionary<NSString *, NSMutableArray *> *_profileWaiters;
  NSString *_openingTabID;
  NSString *_openingProfileID;
  BOOL _testing;
  NSURL *_probeRoot;
  NSString *_selectedTabID;
  NSMutableDictionary<NSString *, NSDictionary *> *_pendingInstalls;
  NSMutableDictionary<NSString *, NSDictionary *> *_pendingMedia;
  NSMutableDictionary<NSString *, NSMutableArray<NSDictionary *> *> *_probeExtensions;
  ArdiaCoreTab *_extensionPopup;
  NSString *_popupID;
  NSString *_popupOwnerTabID;
  NSString *_popupExtensionID;
  NSMutableArray<NSDictionary *> *_probeDiagnostics;
  NSString *_findTabID;
  NSString *_findRequestID;
  NSString *_findText;
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
  NSAssert(NSThread.isMainThread, @"Chromium must start on the main thread");
  _testing = testing;
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
  }
  std::vector<const char *> arguments;
  for (const auto &value : strings) arguments.push_back(value.c_str());
  return [_engineClass runWithArgc:(int)arguments.size() argv:arguments.data() delegate:self];
}

- (void)engineDidStart {
  _engine = [_engineClass sharedEngine];
  [_services start];
  if (_testing) {
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
  _browserWindow = [[NSClassFromString(@"ArdiaCoreWindow") alloc]
    initWithContentRect:NSMakeRect(0, 0, 1200, 780)];
  _browserWindow.delegate = self;
  if (_onReady) _onReady();
}

- (NSWindow *)window { return _browserWindow.window; }
- (NSView *)hostView { return _browserWindow.hostView; }
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
      [self->_browserWindow prepareProfile:profile];
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
  NSAssert(NSThread.isMainThread, @"Tab creation must run on the main thread");
  if (_tabs[tabID]) {
    BOOL matches = [_owners[tabID] isEqualToString:profileID];
    if (!matches && error) *error = BridgeError(@"A live tab cannot be moved to a different profile.");
    return matches;
  }
  if (!ValidID(tabID) || !_profiles[profileID]) {
    if (error) *error = BridgeError(@"The tab has no loaded profile; refusing a default-profile fallback.");
    return NO;
  }
  _openingTabID = tabID;
  _openingProfileID = profileID;
  ArdiaCoreTab *tab = [_browserWindow openTab:url profile:_profiles[profileID] foreground:NO];
  _openingTabID = nil;
  _openingProfileID = nil;
  if (!tab) {
    if (error) *error = BridgeError(@"Chromium could not create the tab.");
    return NO;
  }
  _tabs[tabID] = tab;
  _owners[tabID] = profileID;
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
  if (identity && _onTabChanged) {
    _onTabChanged(identity, tab.url ?: @"", tab.title ?: @"", tab.loading,
                  tab.canGoBack, tab.canGoForward);
  }
}

- (void)window:(ArdiaCoreWindow *)window didInsertTab:(ArdiaCoreTab *)tab
        opener:(ArdiaCoreTab *)opener disposition:(NSString *)disposition {
  if (_openingTabID) {
    _tabs[_openingTabID] = tab;
    _owners[_openingTabID] = _openingProfileID;
    tab.delegate = self;
    return;
  }
  NSString *profileID = [_profiles allKeysForObject:tab.profile].firstObject;
  if (!profileID) {
    dispatch_async(dispatch_get_main_queue(), ^{ [tab closeNow]; });
    return;
  }
  NSString *identity = NSUUID.UUID.UUIDString;
  _tabs[identity] = tab;
  _owners[identity] = profileID;
  tab.delegate = self;
  NSString *openerID = [self identityForTab:opener];
  dispatch_async(dispatch_get_main_queue(), ^{
    if (!tab.closed && self->_onNewTab) {
      self->_onNewTab(identity, profileID, tab.url.length ? tab.url : @"about:blank",
                     openerID, ![disposition isEqualToString:@"background_tab"]);
    }
  });
}

- (NSView *)viewForTabID:(NSString *)tabID { return _tabs[tabID].view; }
- (void)activateTabID:(NSString *)tabID {
  ArdiaCoreTab *tab = _tabs[tabID];
  if (!tab || tab.closed) return;
  if (_findTabID && ![_findTabID isEqualToString:tabID]) [self stopFindingInTabID:_findTabID];
  if (_testing && ![_selectedTabID isEqualToString:tabID]) {
    [_tabs[_selectedTabID ?: @""] noteShownByHost:NO];
    [tab noteShownByHost:YES];
  }
  _selectedTabID = tabID;
  _browserWindow.activeProfile = tab.profile;
  [_browserWindow activateTab:tab];
}
- (void)clearActiveTab {
  if (_findTabID) [self stopFindingInTabID:_findTabID];
  if (_testing) [_tabs[_selectedTabID ?: @""] noteShownByHost:NO];
  _selectedTabID = nil;
  [self closeExtensionPopup];
}
- (void)closeTabID:(NSString *)tabID {
  ArdiaCoreTab *tab = _tabs[tabID];
  if (!tab || _closingBrowser) return;
  if (tab.closed) { [self tabWillClose:tab]; return; }
  [_pendingHostClosures addObject:tabID];
  [tab close];
}
- (void)focusTabID:(NSString *)tabID { [_tabs[tabID] focus]; }
- (void)discardTabID:(NSString *)tabID {
  // The model has already removed this tab or rejected its creation.
  ArdiaCoreTab *tab = _tabs[tabID];
  [_pendingHostClosures removeObject:tabID];
  if ([tabID isEqualToString:_findTabID]) [self stopFindingInTabID:tabID];
  [_tabs removeObjectForKey:tabID];
  [_owners removeObjectForKey:tabID];
  [tab closeNow];
}
- (void)activateProfileID:(NSString *)profileID {
  if (_profiles[profileID]) _browserWindow.activeProfile = _profiles[profileID];
}
- (void)goBackInTabID:(NSString *)tabID { [_tabs[tabID] goBack]; }
- (void)goForwardInTabID:(NSString *)tabID { [_tabs[tabID] goForward]; }
- (void)reloadTabID:(NSString *)tabID { [_tabs[tabID] reload]; }
- (BOOL)placeTabIDs:(NSArray<NSString *> *)tabIDs pinnedIDs:(NSArray<NSString *> *)pinnedIDs
         profileID:(NSString *)profileID {
  NSSet *identities = [NSSet setWithArray:tabIDs];
  NSSet *pins = [NSSet setWithArray:pinnedIDs];
  ArdiaCoreProfile *profile = _profiles[profileID];
  if (!profile || profile.destroyed || profile.offTheRecord || identities.count != tabIDs.count ||
      pins.count != pinnedIDs.count || ![pins isSubsetOfSet:identities]) return NO;
  BOOL seenUnpinned = NO;
  for (NSString *identity in tabIDs) {
    ArdiaCoreTab *tab = _tabs[identity];
    BOOL pinned = [pins containsObject:identity];
    if (!tab || tab.closed || tab.profile != profile || ![_owners[identity] isEqualToString:profileID] ||
        (pinned && seenUnpinned)) return NO;
    if (!pinned) seenUnpinned = YES;
  }
  // Set all pin states before the final ordering pass: Chromium constrains
  // pinned indices, so unpinning several tabs during one pass can shift earlier moves.
  for (int pass = 0; pass < 2; pass++) {
    [tabIDs enumerateObjectsUsingBlock:^(NSString *identity, NSUInteger index, BOOL *stop) {
      [self->_browserWindow placeTab:self->_tabs[identity] index:(int)index pinned:[pins containsObject:identity]];
    }];
  }
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
  if (!tab || tab.closed || !text.length || !ValidID(requestID) ||
      ![_selectedTabID isEqualToString:tabID] || ![_owners[tabID] isEqualToString:profileID]) return NO;
  if (_findTabID && ![_findTabID isEqualToString:tabID]) [self stopFindingInTabID:_findTabID];
  // A new query starts a new Chromium find session. Its helper rejects replies
  // from an aborted session; the native token also gates the SwiftUI state.
  if (![_findText isEqualToString:text]) {
    _findRequestID = nil;
    [tab find:@"" forward:YES];
  }
  _findTabID = tabID;
  _findRequestID = requestID;
  _findText = text;
  [tab find:text forward:forward];
  return YES;
}
- (void)stopFindingInTabID:(NSString *)tabID {
  if (![_findTabID isEqualToString:tabID]) return;
  _findTabID = nil;
  _findRequestID = nil;
  _findText = nil;
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
- (void)engineQuitCancelled { _closingBrowser = NO; }
- (void)engineWillShutDown { _closingBrowser = YES; }
- (BOOL)windowShouldClose:(ArdiaCoreWindow *)window { _closingBrowser = YES; return YES; }
- (void)windowDidCancelClose:(ArdiaCoreWindow *)window { _closingBrowser = NO; }

- (void)window:(ArdiaCoreWindow *)window didRemoveTab:(ArdiaCoreTab *)tab {
  NSString *identity = [self identityForTab:tab];
  if (window != _browserWindow || !identity || ![_pendingHostClosures containsObject:identity]) return;
  // The pinned API suppresses tabWillClose for host-initiated closes. Observe
  // removal, then confirm destruction after the tab-strip notification unwinds.
  // A canceled beforeunload or a live tab detached elsewhere is not a closure.
  dispatch_async(dispatch_get_main_queue(), ^{
    if (self->_closingBrowser || self->_tabs[identity] != tab ||
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
    [_selectedTabID isEqualToString:tabID] && [_tabs[tabID].url isEqualToString:request[@"sourceURL"]];
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
  BOOL current = [_selectedTabID isEqualToString:tabID] &&
    [_owners[tabID] isEqualToString:request[@"profileID"]] &&
    [_tabs[tabID].url isEqualToString:request[@"pageURL"]];
  [_engine resolvePermission:requestID result:accepted && current && supported ? @"accept" : @"deny" remember:NO];
}

- (BOOL)showPopupForExtension:(NSString *)extensionID tabID:(NSString *)tabID error:(NSError **)error {
  ArdiaCoreTab *owner = _tabs[tabID];
  if (!ValidExtensionID(extensionID) || !owner || owner.closed || ![_selectedTabID isEqualToString:tabID]) {
    if (error) *error = BridgeError(@"Extension actions require the selected tab in its owning profile.");
    return NO;
  }
  NSDictionary *state = [owner actionStatesForExtensions:@[extensionID]][extensionID];
  NSURL *url = [NSURL URLWithString:state[@"popup"] ?: @""];
  if (![[url scheme] isEqualToString:@"chrome-extension"] || ![url.host isEqualToString:extensionID] ||
      url.user || url.password || url.port) {
    if (error) *error = BridgeError(@"The extension has no valid popup for this tab and profile.");
    return NO;
  }
  if (_extensionPopup && [_popupOwnerTabID isEqualToString:tabID] && [_popupExtensionID isEqualToString:extensionID]) return YES;
  [self closeExtensionPopup];
  ArdiaCoreTab *popup = [_browserWindow openExtensionView:url.absoluteString profile:owner.profile kind:@"popup"];
  if (!popup || popup.profile != owner.profile) {
    [popup closeNow];
    if (error) *error = BridgeError(@"The extension popup could not be opened in its owning profile.");
    return NO;
  }
  _extensionPopup = popup;
  _popupID = NSUUID.UUID.UUIDString;
  _popupOwnerTabID = tabID;
  _popupExtensionID = extensionID;
  popup.delegate = self;
  if (_onExtensionPopup) _onExtensionPopup(@{
    @"id": _popupID, @"tabID": tabID, @"profileID": _owners[tabID], @"extensionID": extensionID
  });
  return YES;
}

- (BOOL)executeExtensionID:(NSString *)extensionID tabID:(NSString *)tabID error:(NSError **)error {
  ArdiaCoreTab *tab = _tabs[tabID];
  NSDictionary *state = ValidExtensionID(extensionID) && tab ? [tab actionStatesForExtensions:@[extensionID]][extensionID] : nil;
  if (!ValidExtensionID(extensionID) || !tab || tab.closed || ![_selectedTabID isEqualToString:tabID] ||
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
  return [_popupID isEqualToString:popupID] ? _extensionPopup.view : nil;
}

- (void)closeExtensionPopup {
  ArdiaCoreTab *tab = _extensionPopup;
  NSString *identity = _popupID;
  _extensionPopup = nil;
  _popupID = nil;
  _popupOwnerTabID = nil;
  _popupExtensionID = nil;
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
  if (!_testing || ![_popupID isEqualToString:popupID]) { completion(nil); return; }
  [self evaluateTab:_extensionPopup script:script completion:completion];
}
- (void)captureProbeTabID:(NSString *)tabID completion:(void (^)(NSData *))completion {
  [self captureProbeTab:_tabs[tabID] completion:completion];
}
- (void)clickProbePopupID:(NSString *)popupID buttonTitle:(NSString *)title completion:(void (^)(BOOL))completion {
  if (!_testing || ![_popupID isEqualToString:popupID] || !_extensionPopup || _extensionPopup.closed) {
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
  ArdiaCoreTab *popup = _extensionPopup;
  ClickProbeTarget(popup, expression, ^BOOL { return [self->_popupID isEqualToString:popupID]; }, completion);
}
- (void)clickProbeElementInTabID:(NSString *)tabID elementID:(NSString *)elementID completion:(void (^)(BOOL))completion {
  ArdiaCoreTab *tab = _tabs[tabID];
  if (!_testing || !tab || tab.closed || ![_selectedTabID isEqualToString:tabID] || elementID.length > 128) {
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
    return !tab.closed && self->_tabs[tabID] == tab && [self->_selectedTabID isEqualToString:tabID];
  }, completion);
}
- (void)captureProbePopupID:(NSString *)popupID completion:(void (^)(NSData *))completion {
  if (![_popupID isEqualToString:popupID]) { completion(nil); return; }
  [self captureProbeTab:_extensionPopup completion:completion];
}
- (int)nativeTabIDForID:(NSString *)tabID { return _tabs[tabID] ? _tabs[tabID].tabId : -1; }
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
- (void)tab:(ArdiaCoreTab *)tab didFindMatches:(int)count active:(int)active final:(BOOL)final {
  NSString *identity = [self identityForTab:tab];
  if (_findRequestID && [identity isEqualToString:_findTabID] &&
      [identity isEqualToString:_selectedTabID] && _onFindResult) {
    _onFindResult(identity, _findRequestID, count, active, final);
  }
}
- (void)tab:(ArdiaCoreTab *)tab didChangeMediaAccess:(NSDictionary<NSString *, NSNumber *> *)access {
  NSString *identity = [self identityForTab:tab];
  if (identity && _onMediaAccess) _onMediaAccess(identity, access);
}
- (void)tab:(ArdiaCoreTab *)tab preferredSizeDidChange:(NSSize)size {
  if (tab == _extensionPopup && _popupID && _onExtensionPopupSize) _onExtensionPopupSize(_popupID, size);
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
  if (tab == _extensionPopup) {
    NSString *identity = _popupID;
    _extensionPopup = nil;
    _popupID = nil;
    _popupOwnerTabID = nil;
    _popupExtensionID = nil;
    if (identity && _onExtensionPopupClosed) _onExtensionPopupClosed(identity);
    return;
  }
  NSString *identity = [self identityForTab:tab];
  if (!identity) return;
  [_pendingHostClosures removeObject:identity];
  if ([identity isEqualToString:_findTabID]) [self stopFindingInTabID:identity];
  [_tabs removeObjectForKey:identity];
  [_owners removeObjectForKey:identity];
  dispatch_async(dispatch_get_main_queue(), ^{
    if (self->_onTabClosed) self->_onTabClosed(identity);
  });
}
- (ArdiaCoreWindow *)engineWindowForNewBrowserOfProfile:(ArdiaCoreProfile *)profile type:(NSString *)type {
  return [_profiles allKeysForObject:profile].count ? _browserWindow : nil;
}
- (void)engine:(ArdiaCoreEngine *)engine permissionRequest:(NSDictionary *)request tab:(ArdiaCoreTab *)tab {
  NSString *identity = request[@"id"];
  NSString *tabID = [self identityForTab:tab];
  NSString *profileID = tabID ? _owners[tabID] : nil;
  if (!identity.length || !profileID || ![_selectedTabID isEqualToString:tabID] || !_onWebsiteMediaRequest ||
      _pendingMedia.count >= 10) {
    if (identity) [engine resolvePermission:identity result:@"deny" remember:NO];
    return;
  }
  NSMutableDictionary *bound = request.mutableCopy;
  bound[@"tabID"] = tabID;
  bound[@"profileID"] = profileID;
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
  if (!tabID && tab == _extensionPopup) tabID = _popupOwnerTabID;
  NSString *profileID = tabID ? _owners[tabID] : nil;
  NSString *directory = profileID ? _profiles[profileID].path.lastPathComponent : nil;
  if (!identity.length || !profileID || ![directory isEqualToString:prompt[@"profile"]] ||
      ![_selectedTabID isEqualToString:tabID] || !_onInstallRequest || _pendingInstalls.count >= 10) {
    if (identity) [_engineClass resolveExtensionInstallPrompt:identity accepted:NO];
    if (_onNotice) _onNotice(@"The extension request has no active profile context and was canceled.");
    return;
  }
  NSMutableDictionary *request = prompt.mutableCopy;
  request[@"profileID"] = profileID;
  request[@"tabID"] = tabID;
  request[@"sourceURL"] = _tabs[tabID].url ?: @"";
  _pendingInstalls[identity] = request;
  [self closeExtensionPopup];
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
