#import "include/ChromiumBridge.h"
#import "../../ThirdParty/ArdiaCore/ArdiaCore.h"
#import <dlfcn.h>
#include <string>
#include <vector>

static NSError *BridgeError(NSString *message) {
  return [NSError errorWithDomain:@"com.arcusis.browser.chromium" code:1
                        userInfo:@{NSLocalizedDescriptionKey: message}];
}

static BOOL ValidID(NSString *value) {
  return [[[[NSUUID alloc] initWithUUIDString:value] UUIDString] isEqualToString:value];
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
  return self;
}

- (int)runWithDataDirectory:(NSURL *)directory testing:(BOOL)testing {
  NSAssert(NSThread.isMainThread, @"Chromium must start on the main thread");
  _testing = testing;
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
  }
  std::vector<const char *> arguments;
  for (const auto &value : strings) arguments.push_back(value.c_str());
  return [_engineClass runWithArgc:(int)arguments.size() argv:arguments.data() delegate:self];
}

- (void)engineDidStart {
  _engine = [_engineClass sharedEngine];
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
    if (profile && !profile.offTheRecord && !profile.destroyed) {
      self->_profiles[profileID] = profile;
      [self->_browserWindow prepareProfile:profile];
    } else {
      error = BridgeError(@"Chromium could not load the requested persistent profile.");
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
  _browserWindow.activeProfile = tab.profile;
  [_browserWindow activateTab:tab];
}
- (void)closeTabID:(NSString *)tabID { [_tabs[tabID] close]; }
- (void)focusTabID:(NSString *)tabID { [_tabs[tabID] focus]; }
- (void)discardTabID:(NSString *)tabID { [_tabs[tabID] closeNow]; }
- (void)activateProfileID:(NSString *)profileID {
  if (_profiles[profileID]) _browserWindow.activeProfile = _profiles[profileID];
}
- (void)goBackInTabID:(NSString *)tabID { [_tabs[tabID] goBack]; }
- (void)goForwardInTabID:(NSString *)tabID { [_tabs[tabID] goForward]; }
- (void)reloadTabID:(NSString *)tabID { [_tabs[tabID] reload]; }
- (void)evaluateInTabID:(NSString *)tabID script:(NSString *)script
            completion:(void (^)(NSString *))completion {
  ArdiaCoreTab *tab = _tabs[tabID];
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
      completion:reply];
}
- (void)quit { [_engine quit]; }
- (void)captureProbeTabID:(NSString *)tabID completion:(void (^)(NSData *))completion {
  ArdiaCoreTab *tab = _tabs[tabID];
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
- (void)tabWillClose:(ArdiaCoreTab *)tab {
  NSString *identity = [self identityForTab:tab];
  if (!identity) return;
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
  // Permission UI is a later milestone. No silent camera/microphone/location grants.
  NSString *identity = request[@"id"];
  if (identity) [engine resolvePermission:identity result:@"deny" remember:NO];
  if (_onNotice) _onNotice(@"Website permissions are not available in this development build.");
}
- (void)engine:(ArdiaCoreEngine *)engine extensionInstallPrompt:(NSDictionary *)prompt tab:(ArdiaCoreTab *)tab {
  NSString *identity = prompt[@"requestId"];
  if (identity) [_engineClass resolveExtensionInstallPrompt:identity accepted:NO];
  if (_onNotice) _onNotice(@"Extension installation is not available in this development build.");
}
- (BOOL)engineIsReservedKeyEvent:(NSEvent *)event {
  return (event.modifierFlags & NSEventModifierFlagCommand) &&
    [@[@"t", @"l", @"w", @"s", @"q"] containsObject:event.charactersIgnoringModifiers.lowercaseString];
}
@end
