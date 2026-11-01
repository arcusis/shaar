// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#import "ChromiumRuntimeInternal.h"
#import "ChromiumProbeRoot.h"
#import <dlfcn.h>
#include <string>
#include <vector>
#include <cmath>
#include <errno.h>
#include <sys/stat.h>
#include <unistd.h>

static NSBundle *ARCSelectedBridgeBundle;
static NSString *ARCBridgeLanguage = @"en";

NSString *ARCBridgeLocalizedString(NSString *key) {
  return [ARCSelectedBridgeBundle localizedStringForKey:key value:key table:@"Bridge"] ?: key;
}

NSError *ARCBridgeError(NSString *message) {
  NSString *localized = ARCBridgeLocalizedString(message);
  return [NSError errorWithDomain:@"com.arcusis.browser.chromium" code:1
                        userInfo:@{NSLocalizedDescriptionKey: localized}];
}

void ARCConfigureLocalization(NSURL *bundleURL, NSString *languageIdentifier) {
  NSString *language = [@[@"en", @"he"] containsObject:languageIdentifier] ? languageIdentifier : @"en";
  ARCBridgeLanguage = language;
  NSBundle *packageBundle = [NSBundle bundleWithURL:bundleURL];
  NSString *localizationPath = [packageBundle pathForResource:language ofType:@"lproj"];
  ARCSelectedBridgeBundle = localizationPath ? [NSBundle bundleWithPath:localizationPath] : packageBundle;
}

static NSString *ARCStringWithLocale(NSString *format, NSLocale *locale, ...) {
  va_list arguments;
  va_start(arguments, locale);
  NSString *result = [[NSString alloc] initWithFormat:format locale:locale arguments:arguments];
  va_end(arguments);
  return result;
}

static NSString *ARCBridgeActiveDownloadsMessage(int count) {
  if (!ARCSelectedBridgeBundle) {
    return count == 1 ? @"Closing the browser will cancel one active download."
      : [NSString stringWithFormat:@"Closing the browser will cancel %d active downloads.", count];
  }
  NSString *englishFallback = @"Closing the browser will cancel %d active downloads.";
  NSString *format = [ARCSelectedBridgeBundle localizedStringForKey:@"%d active downloads"
      value:englishFallback table:@"Bridge"];
  if ([format isEqualToString:englishFallback]) {
    return count == 1 ? @"Closing the browser will cancel one active download."
      : [NSString stringWithFormat:englishFallback, count];
  }
  return ARCStringWithLocale(format, [NSLocale localeWithLocaleIdentifier:ARCBridgeLanguage], count);
}

BOOL ARCIsCanonicalID(NSString *value) {
  return [[[[NSUUID alloc] initWithUUIDString:value] UUIDString] isEqualToString:value];
}

NSString *ARCValidatedProfileID(NSString *profileID) {
  if (![profileID isKindOfClass:NSString.class] ||
      ![profileID rangeOfString:@"^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$"
                       options:NSRegularExpressionSearch].length) return nil;
  NSUUID *identity = [[NSUUID alloc] initWithUUIDString:profileID];
  return identity.UUIDString;
}

BOOL ARCReservedBrowserShortcut(NSString *key, NSEventModifierFlags modifiers) {
  NSEventModifierFlags chord = modifiers & (NSEventModifierFlagCommand | NSEventModifierFlagControl |
    NSEventModifierFlagOption | NSEventModifierFlagShift | NSEventModifierFlagFunction);
  if (chord == NSEventModifierFlagCommand) {
    return [@[@"n", @"t", @"l", @"w", @"s", @"q", @"r", @"f", @"g", @"d", @"y", @","] containsObject:key.lowercaseString];
  }
  if (chord == (NSEventModifierFlagCommand | NSEventModifierFlagShift)) {
    return [@[@"w", @"g", @"j", @"t", @"r"] containsObject:key.lowercaseString];
  }
  return chord == (NSEventModifierFlagControl | NSEventModifierFlagOption) &&
    [@[@"[", @"]"] containsObject:key];
}

@implementation ARCNativeWindowState
@end

@implementation ARCChromiumRuntime

@synthesize languageIdentifier = _languageIdentifier;

- (void)setLanguageIdentifier:(NSString *)languageIdentifier {
  _languageIdentifier = [@[@"en", @"he"] containsObject:languageIdentifier] ? [languageIdentifier copy] : @"en";
}

- (instancetype)initWithFrameworkURL:(NSURL *)url error:(NSError **)error {
  if (!(self = [super init])) return nil;
  _languageIdentifier = @"en";
  NSURL *binary = [url URLByAppendingPathComponent:@"Versions/Current/Chromium Framework"];
  _library = dlopen(binary.fileSystemRepresentation, RTLD_NOW | RTLD_GLOBAL);
  if (!_library) {
    NSString *reason = [NSString stringWithUTF8String:dlerror() ?: "unknown loader error"];
    NSString *format = ARCBridgeLocalizedString(@"Cannot load Chromium: %@");
    if (error) *error = ARCBridgeError([NSString stringWithFormat:format, reason]);
    return nil;
  }
  _engineClass = NSClassFromString(@"ArdiaCoreEngine");
  if (!_engineClass || !NSClassFromString(@"ArdiaCoreWindow")) {
    if (error) *error = ARCBridgeError(@"The framework does not expose the pinned ArdiaCore API.");
    return nil;
  }
  _profiles = [NSMutableDictionary dictionary];
  _primaryWindowID = NSUUID.UUID.UUIDString;
  _windows = [NSMutableDictionary dictionary];
  _tabWindows = [NSMutableDictionary dictionary];
  _windowCloseObservers = [NSMutableDictionary dictionary];
  _retiredWindowIDs = [NSMutableSet set];
  _tabs = [NSMutableDictionary dictionary];
  _extensionManagers = [NSMutableDictionary dictionary];
  _privateProbeContexts = [NSMutableDictionary dictionary];
  _privateProbeWindows = [NSMutableDictionary dictionary];
  _privateProbeTabs = [NSMutableDictionary dictionary];
  _privateQuitProbeTabs = [NSMutableDictionary dictionary];
  _privateProbeSourceLeases = [NSMutableDictionary dictionary];
  _privateProbePendingContexts = [NSMutableDictionary dictionary];
  _privateProbePendingWindows = [NSMutableSet set];
  _privateProbePendingTabs = [NSMutableSet set];
  _privateProbeCancelledCloses = [NSMutableSet set];
  _owners = [NSMutableDictionary dictionary];
  _profileWaiters = [NSMutableDictionary dictionary];
  _pendingInstalls = [NSMutableDictionary dictionary];
  _pendingMedia = [NSMutableDictionary dictionary];
  _pendingExternal = [NSMutableDictionary dictionary];
  _documentGenerations = [NSMutableDictionary dictionary];
  _pendingHostClosures = [NSMutableSet set];
  _detachedTabSelections = [NSMutableDictionary dictionary];
  _probeExtensions = [NSMutableDictionary dictionary];
  _probeDiagnostics = [NSMutableArray array];
  _mediaSessions = [[ARCMediaSessionTracker alloc] init];
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
    if (owner.onLibraryError) owner.onLibraryError(profile, section, ARCBridgeLocalizedString(message));
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
  if (!_languageIdentifier) _languageIdentifier = @"en";
  if (!ARCSelectedBridgeBundle && _languageIdentifier.length) {
    NSURL *resources = [NSBundle.mainBundle URLForResource:@"ArcusisBrowser_BrowserCore" withExtension:@"bundle"];
    if (resources) ARCConfigureLocalization(resources, _languageIdentifier);
  }
  NSAssert(NSThread.isMainThread, @"Chromium must start on the main thread");
  _testing = testing;
  if (testing) _probeRoot = directory.URLByDeletingLastPathComponent.URLByResolvingSymlinksInPath;
  __weak ARCChromiumRuntime *weakSelf = self;
  _webStoreFit = [[ARCWebStoreFit alloc] initWithTesting:testing
      evaluator:^(ArdiaCoreTab *tab, NSString *script, void (^completion)(NSString *)) {
    ARCChromiumRuntime *owner = weakSelf;
    if (owner) [owner evaluateTab:tab script:script completion:completion];
    else completion(nil);
  }];
  static NSString *const externalProbeSwitch = @"--ardia-test-external-protocol-no-launch";
  BOOL externalProbeRequested = [NSProcessInfo.processInfo.arguments containsObject:externalProbeSwitch];
  if (externalProbeRequested) {
    NSURL *root = directory.URLByDeletingLastPathComponent;
    if (!testing || !directory.isFileURL || ![directory.lastPathComponent isEqualToString:@"Chromium"] ||
        !ARCProbeRootIsOwned(root)) return 1;
    struct stat info;
    int result = lstat(directory.path.stringByStandardizingPath.fileSystemRepresentation, &info);
    if ((result == 0 && (!S_ISDIR(info.st_mode) || info.st_uid != getuid())) ||
        (result != 0 && errno != ENOENT)) return 1;
  }
  _externalAppProbeTesting = externalProbeRequested;
  // Never forward arbitrary launch flags into user profiles.
  std::vector<std::string> strings = {
    NSProcessInfo.processInfo.arguments.firstObject.UTF8String,
    "--user-data-dir=" + std::string(directory.fileSystemRepresentation),
    "--disable-stack-profiler",
    "--disable-features=MacAppCodeSignClone,DevToolsAcceptDebuggingConnections",
    "--profile-directory=Default"
  };
  strings.push_back("--lang=" + std::string(_languageIdentifier.UTF8String));
  NSString *acceptedLanguages = [_languageIdentifier isEqualToString:@"he"] ? @"he,en" : @"en";
  strings.push_back("--accept-lang=" + std::string(acceptedLanguages.UTF8String));
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
  if (_externalAppProbeTesting) strings.push_back(externalProbeSwitch.UTF8String);
  std::vector<const char *> arguments;
  for (const auto &value : strings) arguments.push_back(value.c_str());
  // Quit must end the process, so no extension may keep Chromium running in the background.
  ARCDisableBackgroundMode(directory);
  _shutdownGuard = [[ARCEngineShutdownGuard alloc] init];
  int result = [_engineClass runWithArgc:(int)arguments.size() argv:arguments.data() delegate:self];
  [_shutdownGuard engineReturned];
  return result;
}

- (void)engineDidStart {
  _engine = [_engineClass sharedEngine];
  [_services start];
  NSMutableArray<NSString *> *pageScripts = [NSMutableArray arrayWithObject:ARCMediaSessionPageScript()];
  if (_testing) {
    // Diagnostics only for the empty Bitwarden store-probe profile. No credential entry occurs.
    [pageScripts addObject:@"(function(post){"
      "if(location.protocol==='chrome-extension:' && location.host==='nngceckbapebfimnlniiiahkandclblb'){"
      "const report=(kind,value)=>post('arcusisProbeDiagnostic',JSON.stringify({kind,message:String(value).slice(0,8192),url:location.href}));"
      "addEventListener('error',e=>report('error',e.message+' '+(e.error?.stack||'')));"
      "addEventListener('unhandledrejection',e=>report('rejection',e.reason?.stack||e.reason));"
      "const original=console.error;console.error=(...args)=>{report('console',args.map(String).join(' '));return original.apply(console,args);};"
      "}return function(){};})"];
  }
  _engine.pageScript = ARCComposedPageScript(pageScripts);
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
- (NSImage *)faviconForTabID:(NSString *)tabID profileID:(NSString *)profileID windowID:(NSString *)windowID {
  if (!ARCIsCanonicalID(tabID) || !ARCIsCanonicalID(profileID) || !ARCIsCanonicalID(windowID)) return nil;
  ArdiaCoreTab *tab = _tabs[tabID];
  ArdiaCoreProfile *profile = _profiles[profileID];
  ARCNativeWindowState *state = _windows[windowID];
  if (!tab || !profile || !state || state.closed || state.closing || _closingBrowser || tab.closed ||
      tab.profile != profile || !state.native ||
      ![_owners[tabID] isEqualToString:profileID] ||
      ![_tabWindows[tabID] isEqualToString:windowID]) return nil;
  return tab.favicon;
}
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
  if (!_engine || _closingBrowser || !ARCIsCanonicalID(identity) || [self privateIdentityOccupied:identity]) {
    if (error) *error = ARCBridgeError(@"Invalid or reused native window identity.");
    return NO;
  }
  ARCNativeWindowState *state = [[ARCNativeWindowState alloc] init];
  state.tabOrders = [NSMutableDictionary dictionary];
  state.tabPins = [NSMutableDictionary dictionary];
  state.identity = identity;
  state.native = [[NSClassFromString(@"ArdiaCoreWindow") alloc] initWithContentRect:NSMakeRect(0, 0, 1200, 780)];
  if (!state.native || !state.native.window) {
    if (error) *error = ARCBridgeError(@"Chromium could not create the native window.");
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
  [self invalidateExternalRequestsForTabID:nil windowID:identity];
  BOOL quitting = _closingBrowser;
  dispatch_async(dispatch_get_main_queue(), ^{
    for (NSString *requestID in [self->_pendingInstalls.allKeys copy]) {
      if ([self->_pendingInstalls[requestID][@"windowID"] isEqualToString:identity]) [self resolveInstallRequestID:requestID accepted:NO];
    }
    for (NSString *requestID in [self->_pendingMedia.allKeys copy]) {
      if ([self->_pendingMedia[requestID][@"windowID"] isEqualToString:identity]) [self resolveWebsiteMediaRequestID:requestID accepted:NO];
    }
    [self closeExtensionPopupForWindowID:identity];
    for (NSString *tabID in [self->_detachedTabSelections.allKeys copy]) {
      NSDictionary *transfer = self->_detachedTabSelections[tabID];
      if ([transfer[@"sourceWindowID"] isEqualToString:identity] ||
          [transfer[@"destinationWindowID"] isEqualToString:identity]) {
        [self->_detachedTabSelections removeObjectForKey:tabID];
      }
    }
    for (NSString *tabID in [self->_tabWindows.allKeys copy]) {
      if (![self->_tabWindows[tabID] isEqualToString:identity]) continue;
      [self->_pendingHostClosures removeObject:tabID];
      [self->_tabs removeObjectForKey:tabID];
      [self->_owners removeObjectForKey:tabID];
      [self->_tabWindows removeObjectForKey:tabID];
      [self->_documentGenerations removeObjectForKey:tabID];
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
  for (NSDictionary *entry in _privateProbeWindows.allValues) {
    id observer = entry[@"observer"];
    if (observer) [NSNotificationCenter.defaultCenter removeObserver:observer];
  }
}
- (NSString *)chromiumVersion { return _engine.chromiumVersion ?: @"unavailable"; }

- (BOOL)isCanonicalExternalRequestID:(id)value {
  if (![value isKindOfClass:NSString.class]) return NO;
  NSData *bytes = [value dataUsingEncoding:NSASCIIStringEncoding];
  const unsigned char *digits = (const unsigned char *)bytes.bytes;
  if (bytes.length < 2 || bytes.length > 11 || digits[0] != 'x' || digits[1] < '1' || digits[1] > '9') return NO;
  unsigned long long number = 0;
  for (NSUInteger index = 1; index < bytes.length; index++) {
    if (digits[index] < '0' || digits[index] > '9') return NO;
    number = number * 10 + (digits[index] - '0');
    if (number > INT32_MAX) return NO;
  }
  return YES;
}

- (NSUInteger)advanceDocumentGenerationForTabID:(NSString *)tabID {
  NSUInteger next = _documentGenerations[tabID].unsignedIntegerValue + 1;
  _documentGenerations[tabID] = @(next);
  return next;
}

- (void)invalidateExternalRequestsForTabID:(NSString *)tabID windowID:(NSString *)windowID {
  for (NSString *requestID in [_pendingExternal.allKeys copy]) {
    NSDictionary *request = _pendingExternal[requestID];
    if ((tabID && ![request[@"tabID"] isEqualToString:tabID]) ||
        (windowID && ![request[@"windowID"] isEqualToString:windowID])) continue;
    [_pendingExternal removeObjectForKey:requestID];
    [_engineClass resolveExternalApp:requestID open:NO remember:NO];
    if (_onExternalAppDismissed) _onExternalAppDismissed(requestID);
  }
}

- (BOOL)respondsToSelector:(SEL)selector {
  if (selector == @selector(tab:externalAppRequest:)) {
    BOOL supported = self.onExternalAppRequest != nil &&
      [_engineClass respondsToSelector:@selector(resolveExternalApp:open:remember:)];
    if (_testing && _externalAppProbeTesting && ARCProbeRootIsOwned(_probeRoot))
      fprintf(stderr, "External-app probe delegate supported=%d\n", supported);
    return supported;
  }
  return [super respondsToSelector:selector];
}

- (void)loadProfileID:(NSString *)profileID completion:(void (^)(NSError *))completion {
  NSAssert(NSThread.isMainThread, @"Profile loading must run on the main thread");
  if (!ARCIsCanonicalID(profileID) || !_engine || [self isPrivateIdentity:profileID]) {
    completion(ARCBridgeError(@"Invalid profile identity or engine not ready."));
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
      error = error ?: ARCBridgeError(@"Chromium could not load the requested persistent profile.");
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
- (BOOL)navigateTabID:(NSString *)tabID profileID:(NSString *)profileID windowID:(NSString *)windowID
                  url:(NSString *)url {
  NSAssert(NSThread.isMainThread, @"Tab navigation must run on the main thread");
  if (!ARCIsCanonicalID(tabID) || !ARCIsCanonicalID(profileID) || !ARCIsCanonicalID(windowID) || !url.length ||
      ![url isEqualToString:[url stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]] ||
      [url rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound) return NO;
  NSURLComponents *components = [NSURLComponents componentsWithString:url];
  NSString *scheme = components.scheme.lowercaseString;
  BOOL blank = [url isEqualToString:@"about:blank"];
  BOOL validPort = !components.port || components.port.integerValue <= 65535;
  BOOL web = components.URL && scheme.length &&
    [@[@"http", @"https"] containsObject:scheme] && components.host.length > 0 && validPort;
  if (!blank && !web) return NO;

  ArdiaCoreTab *tab = _tabs[tabID];
  if (_privateProbeTabs[tabID] || [_privateProbePendingTabs containsObject:tabID]) return NO;
  ArdiaCoreProfile *profile = _profiles[profileID];
  ARCNativeWindowState *state = _windows[windowID];
  if (!tab || !profile || !state || state.closed || state.closing || _closingBrowser ||
      !state.native || !state.native.window || profile.destroyed || profile.offTheRecord ||
      tab.closed || [_pendingHostClosures containsObject:tabID] || tab.profile != profile ||
      ![_owners[tabID] isEqualToString:profileID] ||
      ![_tabWindows[tabID] isEqualToString:windowID] ||
      ![[state.native tabsForProfile:profile] containsObject:tab]) return NO;

  [self advanceDocumentGenerationForTabID:tabID];
  [self invalidateExternalRequestsForTabID:tabID windowID:nil];
  [tab loadURL:url userInitiated:YES];
  return YES;
}
- (BOOL)openTabID:(NSString *)tabID profileID:(NSString *)profileID windowID:(NSString *)windowID url:(NSString *)url
           error:(NSError **)error {
  NSAssert(NSThread.isMainThread, @"Tab creation must run on the main thread");
  ARCNativeWindowState *state = _windows[windowID];
  if ([self isPrivateIdentity:tabID] || [self isPrivateIdentity:profileID]) {
    if (error) *error = ARCBridgeError(@"Private identities cannot enter regular tab ownership.");
    return NO;
  }
  if (!state || state.closed || state.closing || _closingBrowser) {
    if (error) *error = ARCBridgeError(@"The tab has no open native window.");
    return NO;
  }
  if (_tabs[tabID]) {
    BOOL matches = [_owners[tabID] isEqualToString:profileID] && [_tabWindows[tabID] isEqualToString:windowID];
    if (!matches && error) *error = ARCBridgeError(@"A live tab cannot silently change its profile or native window.");
    return matches;
  }
  if (!ARCIsCanonicalID(tabID) || !_profiles[profileID]) {
    if (error) *error = ARCBridgeError(@"The tab has no loaded profile; refusing a default-profile fallback.");
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
    if (error) *error = ARCBridgeError(@"Chromium could not create the tab.");
    return NO;
  }
  _tabs[tabID] = tab;
  _owners[tabID] = profileID;
  _tabWindows[tabID] = windowID;
  _documentGenerations[tabID] = @0;
  tab.delegate = self;
  [self publish:tab];
  return YES;
}

- (NSString *)identityForTab:(ArdiaCoreTab *)tab {
  if (!tab) return nil;
  return [_tabs allKeysForObject:tab].firstObject;
}

- (ArdiaCoreTab *)liveTabForID:(NSString *)tabID {
  ArdiaCoreTab *tab = _tabs[tabID];
  ARCNativeWindowState *state = [self stateForTabID:tabID];
  if (!tab || tab.closed || !state || state.closing || state.closed || _closingBrowser) return nil;
  return tab;
}

- (NSDictionary *)privateEntryForTab:(ArdiaCoreTab *)tab identity:(NSString **)identityOut {
  for (NSString *identity in _privateProbeTabs) {
    NSDictionary *entry = _privateProbeTabs[identity];
    if (entry[@"tab"] == tab) {
      if (identityOut) *identityOut = identity;
      return entry;
    }
  }
  return nil;
}

- (void)publish:(ArdiaCoreTab *)tab {
  NSString *privateTabID = nil;
  NSDictionary *privateEntry = [self privateEntryForTab:tab identity:&privateTabID];
  if (privateEntry) {
    NSString *contextID = privateEntry[@"contextID"];
    NSString *windowID = privateEntry[@"windowID"];
    NSDictionary *context = _privateProbeContexts[contextID];
    NSDictionary *window = _privateProbeWindows[windowID];
    if (context && window && [self privateOwnerForTabID:privateTabID windowID:windowID
        contextID:contextID tab:nil window:nil] && ![window[@"closing"] boolValue] && !tab.closed &&
        context[@"profile"] == tab.profile && self.onPrivateTabChanged) {
      if (privateTabID) self.onPrivateTabChanged(contextID, windowID, privateTabID, tab.url ?: @"", tab.title ?: @"",
                                          tab.loading, tab.canGoBack, tab.canGoForward);
    }
    return;
  }
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
  if (!state) {
    for (NSString *privateWindowID in _privateProbeWindows) {
      NSDictionary *privateWindow = _privateProbeWindows[privateWindowID];
      if (privateWindow[@"native"] != window) continue;
      for (NSString *tabID in privateWindow[@"tabIDs"]) {
        if (_privateProbeTabs[tabID][@"tab"] == tab) return;
      }
      NSDictionary *capturedWindow = privateWindow;
      NSString *contextID = privateWindow[@"contextID"];
      // Host-created tabs are registered after the synchronous insertion unwinds.
      // Only that exact, still-owned native tab may survive the deferred rejection.
      dispatch_async(dispatch_get_main_queue(), ^{
        NSString *registeredID = nil;
        NSDictionary *registered = [self privateEntryForTab:tab identity:&registeredID];
        ArdiaCoreTab *ownedTab = nil;
        if (registered && [registered[@"windowID"] isEqualToString:privateWindowID] &&
            self->_privateProbeWindows[privateWindowID] == capturedWindow &&
            [self privateOwnerForTabID:registeredID windowID:privateWindowID contextID:contextID
                                  tab:&ownedTab window:nil] && ownedTab == tab) return;
        [tab closeNow];
      });
      return;
    }
  }
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
    NSMutableDictionary *transfer = _detachedTabSelections[existingID];
    if (transfer && [transfer[@"sourceWindowID"] isEqualToString:original.identity]) {
      transfer[@"destinationWindowID"] = state.identity;
    } else {
      transfer = nil;
    }
    // An extension can request windows.create({tabId}) or tabs.move. Existing
    // live identities cannot acquire a second owner. Return the same document
    // after this notification, then restore its application's ordering/selection.
    dispatch_async(dispatch_get_main_queue(), ^{
      if (tab.closed || self->_closingBrowser) {
        if (transfer && self->_detachedTabSelections[existingID] == transfer) {
          [self->_detachedTabSelections removeObjectForKey:existingID];
        }
        return;
      }
      if (!original || original.closed || original.closing) {
        [tab closeNow];
        if (transfer && self->_detachedTabSelections[existingID] == transfer) {
          [self->_detachedTabSelections removeObjectForKey:existingID];
        }
        return;
      }
      BOOL restoreSelection = transfer && self->_detachedTabSelections[existingID] == transfer;
      original.hostSelectionDepth++;
      state.hostSelectionDepth++;
      [original.native adoptTab:tab];
      NSString *profileID = self->_owners[existingID];
      NSArray *order = original.tabOrders[profileID];
      if (order) [self placeTabIDs:order pinnedIDs:original.tabPins[profileID] ?: @[]
                        profileID:profileID windowID:original.identity];
      if (restoreSelection) {
        NSString *selectionID = transfer[@"selectedTabID"];
        NSString *fallbackID = transfer[@"fallbackTabID"];
        if (![transfer[@"fallbackSuperseded"] boolValue] &&
            ([original.selectedTabID isEqualToString:existingID] ||
             (fallbackID && [original.selectedTabID isEqualToString:fallbackID]))) {
          original.selectedTabID = selectionID;
        }
      }
      if (original.selectedTabID) [self activateTabID:original.selectedTabID];
      if (state.selectedTabID) [self activateTabID:state.selectedTabID];
      state.hostSelectionDepth--;
      original.hostSelectionDepth--;
      if (newBrowser && !state.closed && !state.closing) [self closeWindowID:state.identity];
      if (transfer && self->_detachedTabSelections[existingID] == transfer) {
        [self->_detachedTabSelections removeObjectForKey:existingID];
      }
      if (self->_onNotice) self->_onNotice(ARCBridgeLocalizedString(@"Moving live tabs between windows is not supported."));
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
        if (self->_onNotice) self->_onNotice(ARCBridgeLocalizedString(@"The requested page could not be adopted into its window."));
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
  _documentGenerations[identity] = @0;
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
  if (state.selectedTabID && ![state.selectedTabID isEqualToString:tabID])
    [self invalidateExternalRequestsForTabID:state.selectedTabID windowID:state.identity];
  if (!state.hostSelectionDepth) {
    for (NSMutableDictionary *transfer in _detachedTabSelections.allValues) {
      if ([transfer[@"sourceWindowID"] isEqualToString:state.identity] &&
          ![transfer[@"selectedTabID"] isEqualToString:tabID]) {
        transfer[@"fallbackSuperseded"] = @YES;
      }
    }
  }
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
  if (!state) {
    NSString *privateTabID = nil;
    NSDictionary *entry = [self privateEntryForTab:tab identity:&privateTabID];
    NSMutableDictionary *privateWindow = _privateProbeWindows[entry[@"windowID"]];
    if (entry && privateWindow && entry[@"contextID"] && entry[@"windowID"] && !tab.closed &&
        [self privateOwnerForTabID:privateTabID windowID:entry[@"windowID"]
          contextID:entry[@"contextID"] tab:nil window:nil]) {
      privateWindow[@"selectedTabID"] = privateTabID;
      for (NSString *identity in privateWindow[@"tabIDs"]) {
        ArdiaCoreTab *ownedTab = _privateProbeTabs[identity][@"tab"];
        ownedTab.view.hidden = ownedTab != tab;
      }
    }
    if (entry && entry[@"contextID"] && entry[@"windowID"] && !tab.closed && self.onPrivateTabSelected)
      self.onPrivateTabSelected(entry[@"contextID"], entry[@"windowID"], privateTabID);
    return;
  }
  NSString *identity = [self identityForTab:tab];
  NSString *profileID = identity ? _owners[identity] : nil;
  // Each profile has its own native tab strip. Initial/background-profile and
  // host-selected changes must not replace the visible application's selection.
  if (!state || state.closed || state.closing || _closingBrowser || state.hostSelectionDepth ||
      [_openingWindowID isEqualToString:state.identity] || !identity || !profileID || tab.closed ||
      ![_tabWindows[identity] isEqualToString:state.identity] ||
      state.native.activeProfile != tab.profile) return;
  NSString *previousID = state.selectedTabID;
  ArdiaCoreTab *previous = previousID ? _tabs[previousID] : nil;
  if (previous && !previous.closed && ![_pendingHostClosures containsObject:previousID] &&
      ![[state.native tabsForProfile:previous.profile] containsObject:previous] &&
      !_detachedTabSelections[previousID]) {
    _detachedTabSelections[previousID] = [@{
      @"sourceWindowID": state.identity,
      @"selectedTabID": previousID,
    } mutableCopy];
  }
  if ([state.selectedTabID isEqualToString:identity]) {
    for (NSMutableDictionary *transfer in _detachedTabSelections.allValues) {
      if ([transfer[@"sourceWindowID"] isEqualToString:state.identity] &&
          [transfer[@"fallbackTabID"] isEqualToString:identity]) {
        transfer[@"fallbackSuperseded"] = @YES;
      }
    }
    return;
  }
  BOOL transientFallback = NO;
  for (NSString *tabID in _detachedTabSelections.allKeys) {
    NSMutableDictionary *transfer = _detachedTabSelections[tabID];
    if (![transfer[@"sourceWindowID"] isEqualToString:state.identity]) continue;
    if ([state.selectedTabID isEqualToString:tabID] &&
        (!transfer[@"fallbackTabID"] || [transfer[@"fallbackTabID"] isEqualToString:identity]) &&
        ![transfer[@"fallbackSuperseded"] boolValue]) {
      transfer[@"fallbackTabID"] = identity;
      transientFallback = YES;
    } else {
      transfer[@"fallbackSuperseded"] = @YES;
    }
  }
  if (transientFallback) return;
  if (state.selectedTabID) [self invalidateExternalRequestsForTabID:state.selectedTabID windowID:state.identity];
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
  [self invalidateExternalRequestsForTabID:state.selectedTabID windowID:identity];
  if (state.findTabID) [self stopFindingInTabID:state.findTabID];
  if (_testing) [_tabs[state.selectedTabID ?: @""] noteShownByHost:NO];
  state.selectedTabID = nil;
  [self closeExtensionPopupForWindowID:identity];
}
- (void)closeTabID:(NSString *)tabID {
  ArdiaCoreTab *tab = _tabs[tabID];
  ARCNativeWindowState *state = [self stateForTabID:tabID];
  if (!tab || _closingBrowser || state.closed || state.closing) return;
  [self invalidateExternalRequestsForTabID:tabID windowID:nil];
  if (tab.closed) { [self tabWillClose:tab]; return; }
  [_pendingHostClosures addObject:tabID];
  [tab close];
}
- (void)focusTabID:(NSString *)tabID { [_tabs[tabID] focus]; }
- (void)discardTabID:(NSString *)tabID {
  // The model has already removed this tab or rejected its creation.
  ArdiaCoreTab *tab = _tabs[tabID];
  [self invalidateExternalRequestsForTabID:tabID windowID:nil];
  [_pendingHostClosures removeObject:tabID];
  [self stopFindingInTabID:tabID];
  [_tabs removeObjectForKey:tabID];
  [_owners removeObjectForKey:tabID];
  [_tabWindows removeObjectForKey:tabID];
  [_documentGenerations removeObjectForKey:tabID];
  [self resetMediaSessionForTabID:tabID notify:NO];
  [tab closeNow];
}
- (void)activateProfileID:(NSString *)profileID {
  [self activateProfileID:profileID windowID:_primaryWindowID];
}
- (void)activateProfileID:(NSString *)profileID windowID:(NSString *)identity {
  ARCNativeWindowState *state = _windows[identity];
  if (_profiles[profileID] && state && !state.closed && !state.closing && !_closingBrowser) {
    if (state.native.activeProfile != _profiles[profileID])
      [self invalidateExternalRequestsForTabID:nil windowID:identity];
    state.hostSelectionDepth++;
    state.native.activeProfile = _profiles[profileID];
    state.hostSelectionDepth--;
  }
}
- (void)goBackInTabID:(NSString *)tabID {
  if (_tabs[tabID]) { [self advanceDocumentGenerationForTabID:tabID]; [self invalidateExternalRequestsForTabID:tabID windowID:nil]; [_tabs[tabID] goBack]; }
}
- (void)goForwardInTabID:(NSString *)tabID {
  if (_tabs[tabID]) { [self advanceDocumentGenerationForTabID:tabID]; [self invalidateExternalRequestsForTabID:tabID windowID:nil]; [_tabs[tabID] goForward]; }
}
- (void)reloadTabID:(NSString *)tabID {
  if (_tabs[tabID]) { [self advanceDocumentGenerationForTabID:tabID]; [self invalidateExternalRequestsForTabID:tabID windowID:nil]; [_tabs[tabID] reload]; }
}
- (BOOL)reloadTabID:(NSString *)tabID profileID:(NSString *)profileID {
  return [self reloadTabID:tabID profileID:profileID mode:ARCPageReloadModeNormal];
}
- (BOOL)reloadTabID:(NSString *)tabID profileID:(NSString *)profileID mode:(ARCPageReloadMode)mode {
  ArdiaCoreTab *tab = _tabs[tabID];
  if (!tab || tab.closed || ![self isSelectedTabID:tabID] ||
      ![_owners[tabID] isEqualToString:profileID]) return NO;
  // Chromium discards in place: the tab keeps its WebContents and history but loses its renderer.
  if (mode == ARCPageReloadModeNewRenderer && !tab.discarded && ![tab discard]) return NO;
  [self advanceDocumentGenerationForTabID:tabID];
  [self invalidateExternalRequestsForTabID:tabID windowID:nil];
  if (mode == ARCPageReloadModeBypassingCache) {
    [tab reloadIgnoringCache];
  } else {
    [tab reload];
  }
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
    completion(ARCBridgeError(@"Unknown download profile."));
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
  if (!tab || tab.closed || !text.length || !ARCIsCanonicalID(requestID) ||
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
- (void)quit {
  _closingBrowser = YES;
  [self invalidateExternalRequestsForTabID:nil windowID:nil];
  [_engine quit];
}
- (void)engineQuitCancelled {
  _closingBrowser = NO;
  [_detachedTabSelections removeAllObjects];
  for (ARCNativeWindowState *state in _windows.allValues) if (!state.closed) state.closing = NO;
}
- (void)engineWillShutDown {
  _closingBrowser = YES;
  [self invalidateExternalRequestsForTabID:nil windowID:nil];
  [_detachedTabSelections removeAllObjects];
}
- (BOOL)windowShouldClose:(ArdiaCoreWindow *)window {
  ARCNativeWindowState *state = [self stateForWindow:window];
  if (!state) {
    for (NSString *identity in _privateProbeWindows) {
      NSMutableDictionary *entry = _privateProbeWindows[identity];
      if (entry[@"native"] != window) continue;
      if ([_privateProbeCancelledCloses containsObject:identity]) {
        [_privateProbeCancelledCloses removeObject:identity];
        entry[@"closing"] = @NO;
        return NO;
      }
      entry[@"closing"] = @YES;
      return YES;
    }
    return NO;
  }
  if (state.closed) return NO;
  state.closing = YES;
  [self invalidateExternalRequestsForTabID:nil windowID:state.identity];
  return YES;
}
- (void)windowDidCancelClose:(ArdiaCoreWindow *)window {
  ARCNativeWindowState *state = [self stateForWindow:window];
  if (!state) {
    for (NSMutableDictionary *entry in _privateProbeWindows.allValues) {
      if (entry[@"native"] != window) continue;
      entry[@"closing"] = @NO;
      void (^completion)(BOOL) = entry[@"closeCompletion"];
      entry[@"closeCompletion"] = nil;
      if (completion) completion(NO);
      return;
    }
    return;
  }
  if (!state.closed) state.closing = NO;
}

- (void)window:(ArdiaCoreWindow *)window didRemoveTab:(ArdiaCoreTab *)tab {
  NSString *privateTabID = nil;
  NSDictionary *privateEntry = [self privateEntryForTab:tab identity:&privateTabID];
  if (privateEntry) {
    if (tab.closed) [self tabWillClose:tab];
    else dispatch_async(dispatch_get_main_queue(), ^{
      if (self->_privateProbeTabs[privateTabID] == privateEntry && tab.closed)
        [self tabWillClose:tab];
    });
    return;
  }
  NSString *identity = [self identityForTab:tab];
  ARCNativeWindowState *state = [self stateForWindow:window];
  if (!state || !identity || ![_tabWindows[identity] isEqualToString:state.identity]) return;
  [self invalidateExternalRequestsForTabID:identity windowID:state.identity];
  if (!state.closing && !state.closed && !_closingBrowser && !tab.closed &&
      ![_pendingHostClosures containsObject:identity] &&
      [state.selectedTabID isEqualToString:identity] && !_detachedTabSelections[identity]) {
    _detachedTabSelections[identity] = [@{
      @"sourceWindowID": state.identity,
      @"selectedTabID": identity,
    } mutableCopy];
  }
  if (![_pendingHostClosures containsObject:identity]) return;
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
  // Matches WebsitePermissionKind; any other kind the engine forwards stays denied.
  NSArray *known = @[@"camera", @"microphone", @"location", @"notifications", @"clipboard", @"midi",
                     @"multipleDownloads", @"windowManagement", @"localFonts", @"storageAccess"];
  BOOL supported = [kinds isKindOfClass:NSArray.class] && kinds.count > 0 && kinds.count <= known.count;
  if (supported) {
    for (NSString *kind in kinds) supported &= [known containsObject:kind];
  }
  BOOL current = [self isSelectedTabID:tabID] &&
    [_tabWindows[tabID] isEqualToString:request[@"windowID"]] &&
    [_owners[tabID] isEqualToString:request[@"profileID"]] &&
    [_tabs[tabID].url isEqualToString:request[@"pageURL"]];
  [_engine resolvePermission:requestID result:accepted && current && supported ? @"accept" : @"deny" remember:NO];
}

- (NSURL *)downloadsDirectoryForProfileID:(NSString *)profileID {
  NSString *validatedProfileID = ARCValidatedProfileID(profileID);
  ArdiaCoreProfile *profile = validatedProfileID ? _profiles[validatedProfileID] : nil;
  if (!profile || profile.destroyed || profile.offTheRecord || !profile.path.length) return nil;
  return [[NSURL fileURLWithPath:profile.path isDirectory:YES]
      URLByAppendingPathComponent:@"Downloads" isDirectory:YES];
}

- (int)nativeTabIDForID:(NSString *)tabID { return _tabs[tabID] ? _tabs[tabID].tabId : -1; }
- (void)tabDidChangeTitle:(ArdiaCoreTab *)tab { [self publish:tab]; }
- (void)tabDidChangeURL:(ArdiaCoreTab *)tab {
  NSString *identity = [self identityForTab:tab];
  if (identity) [self invalidateExternalRequestsForTabID:identity windowID:nil];
  [_webStoreFit tabDidNavigate:tab];
  [self publish:tab];
}
- (void)tabDidChangeLoading:(ArdiaCoreTab *)tab {
  NSString *identity = [self identityForTab:tab];
  if (identity && tab.loading) {
    [self advanceDocumentGenerationForTabID:identity];
    [self invalidateExternalRequestsForTabID:identity windowID:nil];
  }
  [_webStoreFit tabDidChangeLoading:tab];
  [self publish:tab];
}
- (void)tabDidChangeNavigationState:(ArdiaCoreTab *)tab { [self publish:tab]; }
- (void)tabDidChangeFavicon:(ArdiaCoreTab *)tab { [self publish:tab]; }
- (void)tab:(ArdiaCoreTab *)tab rendererGone:(NSString *)status code:(int)code {
  ARCNativeWindowState *popupState = [self stateForPopupTab:tab];
  if (popupState) {
    [self closeExtensionPopupForWindowID:popupState.identity];
    if (_onNotice) _onNotice(ARCBridgeLocalizedString(@"The extension stopped working. Open it again to retry."));
    return;
  }
  NSString *identity = [self identityForTab:tab];
  NSString *profile = identity ? _owners[identity] : nil;
  if (!identity || !profile || tab.closed) return;
  [self invalidateExternalRequestsForTabID:identity windowID:nil];
  [self stopFindingInTabID:identity];
  [self resetMediaSessionForTabID:identity notify:YES];
  if (_onRendererGone) _onRendererGone(identity, profile, status, code);
}
- (void)tabDidCommitDocument:(ArdiaCoreTab *)tab {
  NSString *identity = [self identityForTab:tab];
  NSString *profile = identity ? _owners[identity] : nil;
  if (identity) {
    [self advanceDocumentGenerationForTabID:identity];
    [self invalidateExternalRequestsForTabID:identity windowID:nil];
    [self resetMediaSessionForTabID:identity notify:YES];
  }
  [self hideWebStoreBrowserPromptInTab:tab];
  [_webStoreFit tabDidNavigate:tab];
  if (identity && profile && !tab.closed && _onDocumentCommitted) _onDocumentCommitted(identity, profile);
}
/// The Chrome Web Store asks every non-Chrome browser to switch. Hide only that dialog, on that host.
- (void)hideWebStoreBrowserPromptInTab:(ArdiaCoreTab *)tab {
  NSURLComponents *components = [NSURLComponents componentsWithString:tab.url ?: @""];
  if (tab.closed || ![components.host.lowercaseString isEqualToString:@"chromewebstore.google.com"]) return;
  NSString *script =
    @"(()=>{const hide=()=>{for(const e of document.querySelectorAll('dialog,[role=dialog]')){"
     "if((e.innerText||'').includes('Switch to Chrome?'))e.style.setProperty('display','none','important');}};"
     "hide();new MutationObserver(hide).observe(document.documentElement,{childList:true,subtree:true});})()";
  [self evaluateTab:tab script:script completion:^(NSString *ignored) {}];
}
- (void)tabDidChangeZoom:(ArdiaCoreTab *)tab { [_webStoreFit tabDidChangeZoom:tab]; }
- (void)tab:(ArdiaCoreTab *)tab didChangePictureInPicture:(NSDictionary<NSString *, id> *)state {
  NSString *identity = [self identityForTab:tab];
  BOOL active = [state[@"active"] isKindOfClass:NSNumber.class] && [state[@"active"] boolValue];
  [self notePictureInPictureVideoTabID:identity active:active kind:state[@"kind"]];
  if (identity && [self liveTabForID:identity] && self.onPictureInPictureChanged) {
    self.onPictureInPictureChanged(identity, active);
  }
}
/// Implementing this replaces the engine's default activation, so private tabs keep their
/// own selection path and other tabs go to the application, which can switch Space.
- (void)tab:(ArdiaCoreTab *)tab requestsActivation:(NSString *)reason {
  NSString *privateTabID = nil;
  NSDictionary *privateEntry = [self privateEntryForTab:tab identity:&privateTabID];
  if (privateEntry) {
    [self selectPrivateTabID:privateTabID windowID:privateEntry[@"windowID"] contextID:privateEntry[@"contextID"]];
    return;
  }
  NSString *identity = [self identityForTab:tab];
  if (identity && [self liveTabForID:identity] && self.onTabActivationRequest) {
    self.onTabActivationRequest(identity, reason.length ? reason : @"page");
  }
}
- (void)tabDidChangeAudio:(ArdiaCoreTab *)tab {
  NSString *identity = [self identityForTab:tab];
  if (identity && [self mediaSessionStateForTabID:identity]) [self publishMediaSessionForTabID:identity];
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
- (void)tab:(ArdiaCoreTab *)tab didReceivePageMessage:(NSString *)kind json:(NSString *)json
         frame:(NSString *)frameID main:(BOOL)main {
  if ([kind isEqualToString:ARCMediaSessionMessage]) {
    [self receiveMediaSessionJSON:json frameID:frameID tab:tab];
    return;
  }
  if (!main || !_testing || ![kind isEqualToString:@"arcusisProbeDiagnostic"] || _probeDiagnostics.count >= 100 ||
      ![tab.url hasPrefix:@"chrome-extension://nngceckbapebfimnlniiiahkandclblb/"]) return;
  NSData *data = [json dataUsingEncoding:NSUTF8StringEncoding];
  id event = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
  if (![event isKindOfClass:NSDictionary.class]) return;
  [_probeDiagnostics addObject:event];
  NSData *report = [NSJSONSerialization dataWithJSONObject:_probeDiagnostics options:NSJSONWritingPrettyPrinted error:nil];
  [report writeToURL:[_probeRoot URLByAppendingPathComponent:@"bitwarden-renderer-errors.json"] atomically:YES];
}
- (void)tabWillClose:(ArdiaCoreTab *)tab {
  [_webStoreFit tabWillClose:tab];
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
  NSString *privateTabID = nil;
  NSDictionary *privateEntry = [self privateEntryForTab:tab identity:&privateTabID];
  if (privateEntry) {
    NSString *contextID = privateEntry[@"contextID"];
    NSString *windowID = privateEntry[@"windowID"];
    NSMutableDictionary *window = _privateProbeWindows[windowID];
    void (^closeCompletion)(BOOL) = privateEntry[@"closeCompletion"];
    NSMutableDictionary *mutableEntry = (NSMutableDictionary *)privateEntry;
    mutableEntry[@"closeCompletion"] = nil;
    [_privateProbeTabs removeObjectForKey:privateTabID];
    [window[@"tabIDs"] removeObject:privateTabID];
    [_privateProbePendingTabs removeObject:privateTabID];
    [window[@"pendingTabs"] removeObject:privateTabID];
    if (self.onPrivateTabClosed) self.onPrivateTabClosed(contextID, windowID, privateTabID);
    if (closeCompletion) closeCompletion(YES);
    if ([window[@"tabIDs"] count] == 0 && ![window[@"closing"] boolValue])
      dispatch_async(dispatch_get_main_queue(), ^{
        [self closePrivateWindowID:windowID contextID:contextID completion:^(BOOL closed) {}];
      });
    return;
  }
  NSString *identity = [self identityForTab:tab];
  if (!identity) return;
  [self invalidateExternalRequestsForTabID:identity windowID:nil];
  [_detachedTabSelections removeObjectForKey:identity];
  ARCNativeWindowState *state = [self stateForTabID:identity];
  BOOL notify = !_closingBrowser && !state.closing && !state.closed;
  [_pendingHostClosures removeObject:identity];
  [self stopFindingInTabID:identity];
  if ([state.selectedTabID isEqualToString:identity]) state.selectedTabID = nil;
  [_tabs removeObjectForKey:identity];
  [_owners removeObjectForKey:identity];
  [_tabWindows removeObjectForKey:identity];
  [_documentGenerations removeObjectForKey:identity];
  [self resetMediaSessionForTabID:identity notify:NO];
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
      if (self->_onNotice) self->_onNotice(ARCBridgeLocalizedString(@"This browser window type or profile is unavailable."));
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

- (void)tab:(ArdiaCoreTab *)tab externalAppRequest:(NSDictionary<NSString *, id> *)request {
  if (_testing && _externalAppProbeTesting && ARCProbeRootIsOwned(_probeRoot))
    fprintf(stderr, "External-app probe callback received\n");
  id rawRequestID = [request isKindOfClass:NSDictionary.class] ? request[@"id"] : nil;
  if (![self isCanonicalExternalRequestID:rawRequestID]) {
    if ([rawRequestID isKindOfClass:NSString.class] && [rawRequestID length] > 0)
      [_engineClass resolveExternalApp:rawRequestID open:NO remember:NO];
    return;
  }
  NSString *requestID = rawRequestID;
  if (_pendingExternal[requestID]) return;
  NSString *tabID = [self identityForTab:tab];
  NSString *profileID = tabID ? _owners[tabID] : nil;
  ARCNativeWindowState *state = tabID ? [self stateForTabID:tabID] : nil;
  NSString *windowID = tabID ? _tabWindows[tabID] : nil;
  NSString *pageURL = tab.url;
  if (_testing && _externalAppProbeTesting && ARCProbeRootIsOwned(_probeRoot))
    fprintf(stderr, "External-app probe scope mapped=%d profile=%d selected=%d window=%d\n",
      tabID != nil, profileID && _profiles[profileID] == tab.profile,
      tabID && [self isSelectedTabID:tabID], state && !state.closed && !state.closing);
  if (!_engineClass || ![_engineClass respondsToSelector:@selector(resolveExternalApp:open:remember:)] ||
      !tabID || !profileID || !_profiles[profileID] || _profiles[profileID] != tab.profile ||
      !state || state.closed || state.closing || state.native == nil || state.native.window == nil ||
      ![windowID isEqualToString:state.identity] || tab.closed ||
      ![self isSelectedTabID:tabID] || ![pageURL isKindOfClass:NSString.class] || pageURL.length == 0 ||
      !_onExternalAppRequest || _pendingExternal.count >= 10) {
    [_engineClass resolveExternalApp:requestID open:NO remember:NO];
    return;
  }
  id origin = [request[@"origin"] isKindOfClass:NSString.class] ? [request[@"origin"] copy] : NSNull.null;
  id scheme = [request[@"scheme"] isKindOfClass:NSString.class] ? [request[@"scheme"] copy] : NSNull.null;
  id app = [request[@"app"] isKindOfClass:NSString.class] ? [request[@"app"] copy] : NSNull.null;
  NSDictionary *context = @{
    @"id": [requestID copy], @"profileID": [profileID copy], @"tabID": [tabID copy],
    @"windowID": [windowID copy], @"pageURL": [pageURL copy], @"origin": origin,
    @"scheme": scheme, @"app": app,
    @"documentGeneration": _documentGenerations[tabID] ?: @0,
  };
  _pendingExternal[requestID] = context;
  _onExternalAppRequest(@{
    @"id": context[@"id"], @"profileID": context[@"profileID"], @"tabID": context[@"tabID"],
    @"windowID": context[@"windowID"], @"pageURL": context[@"pageURL"],
    @"origin": context[@"origin"], @"scheme": context[@"scheme"], @"app": context[@"app"],
  });
}

- (void)resolveExternalAppRequestID:(NSString *)requestID accepted:(BOOL)accepted {
  NSDictionary *request = _pendingExternal[requestID];
  if (!request) return;
  [_pendingExternal removeObjectForKey:requestID];
  NSString *tabID = request[@"tabID"];
  NSString *applicationName = [request[@"app"] isKindOfClass:NSString.class] ? request[@"app"] : nil;
  BOOL canOpenApplication = applicationName.length > 0 &&
    [applicationName stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].length > 0;
  ARCNativeWindowState *state = [self stateForTabID:tabID];
  BOOL contextMatches = _tabs[tabID] && !_tabs[tabID].closed && state && !state.closed && !state.closing &&
    state.native != nil && state.native.window != nil && [_tabWindows[tabID] isEqualToString:request[@"windowID"]] &&
    [state.identity isEqualToString:request[@"windowID"]] &&
    [_owners[tabID] isEqualToString:request[@"profileID"]] &&
    _tabs[tabID].profile == _profiles[request[@"profileID"]] &&
    [[state.native tabsForProfile:_tabs[tabID].profile] containsObject:_tabs[tabID]] &&
    [self isSelectedTabID:tabID] && [_tabs[tabID].url isEqualToString:request[@"pageURL"]] &&
    _documentGenerations[tabID].unsignedIntegerValue == [request[@"documentGeneration"] unsignedIntegerValue];
  [_engineClass resolveExternalApp:requestID open:accepted && contextMatches && canOpenApplication remember:NO];
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
    if (_onNotice) _onNotice(ARCBridgeLocalizedString(@"The extension request has no active profile context and was canceled."));
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
  alert.messageText = ARCBridgeLocalizedString(@"Downloads are still running");
  alert.informativeText = ARCBridgeActiveDownloadsMessage(count);
  [alert addButtonWithTitle:ARCBridgeLocalizedString(@"Keep Browser Open")];
  NSButton *quit = [alert addButtonWithTitle:ARCBridgeLocalizedString(@"Close and Cancel Downloads")];
  quit.hasDestructiveAction = YES;
  [alert beginSheetModalForWindow:window.window completionHandler:^(NSModalResponse response) {
    completion(response == NSAlertSecondButtonReturn);
  }];
}
- (BOOL)engineIsReservedKey:(NSString *)key unshiftedKey:(NSString *)unshiftedKey modifiers:(NSEventModifierFlags)modifiers {
  return ARCReservedBrowserShortcut(unshiftedKey.length ? unshiftedKey : key, modifiers);
}
@end
