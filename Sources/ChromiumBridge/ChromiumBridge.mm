#import "include/ChromiumBridge.h"
#import "ChromiumDownloads.h"
#import "ChromiumLibrary.h"
#import "ChromiumWebStoreFit.h"
#import "../../ThirdParty/ArdiaCore/ArdiaCore.h"
#import <dlfcn.h>
#include <string>
#include <vector>
#include <cmath>
#include <errno.h>
#include <sys/stat.h>
#include <unistd.h>

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

static NSString *ProbeButtonExpression(NSString *literal, BOOL diagnostic) {
  return [NSString stringWithFormat:
    @"(()=>{const title=%@;const excluded=e=>{for(let n=e;n&&n.nodeType===1;n=n.parentElement){"
     "if(n.hidden||n.inert||n.getAttribute('aria-hidden')?.toLowerCase()==='true')return true;"
     "const s=getComputedStyle(n);if(s.display==='none'||s.visibility==='hidden'||s.visibility==='collapse'||s.opacity==='0')return true;}return false;};"
     "const text=e=>{const w=document.createTreeWalker(e,NodeFilter.SHOW_TEXT);let out='',n;"
     "while((n=w.nextNode()))if(!excluded(n.parentElement))out+=' '+n.nodeValue;return out.trim().replace(/\\s+/g,' ');};"
     "const label=e=>(e.getAttribute('aria-label')||text(e)).trim().replace(/\\s+/g,' ');"
     "const candidates=[...document.querySelectorAll('button,a,[role=button]')],exact=candidates.filter(e=>label(e)===title),"
     "visible=exact.filter(e=>!excluded(e)),sized=visible.filter(e=>{const r=e.getBoundingClientRect();return r.width>0&&r.height>0;}),"
     "eligible=sized.filter(e=>!e.disabled&&e.getAttribute('aria-disabled')?.toLowerCase()!=='true');const cap=n=>Math.min(n,999),viewportHasArea=innerWidth>0&&innerHeight>0;"
     "const hit=(e,x,y)=>{const top=document.elementFromPoint(x,y);return !!top&&(top===e||e.contains(top));};"
     "const point=e=>{const r=e.getBoundingClientRect();if(r.width<=0||r.height<=0)return null;const x=r.x+r.width/2,y=r.y+r.height/2;"
     "if(x>=0&&y>=0&&x<innerWidth&&y<innerHeight&&hit(e,x,y))return {x,y};const l=Math.max(0,r.left),t=Math.max(0,r.top),"
     "rr=Math.min(innerWidth,r.right),bb=Math.min(innerHeight,r.bottom);if(rr<=l||bb<=t)return null;"
     "for(const fx of [.1,.5,.9])for(const fy of [.1,.5,.9]){const px=l+(rr-l)*fx,py=t+(bb-t)*fy;if(hit(e,px,py))return {x:px,y:py};}return null;};"
     "let reason='none';if(!candidates.length)reason='no_candidate';else if(!exact.length)reason='no_exact_label';"
     "else if(!visible.length)reason='hidden';else if(!sized.length)reason='no_area';else if(!eligible.length)reason='disabled';"
     "else if(eligible.length!==1)reason='ambiguous';const button=eligible.length===1?eligible[0]:null;"
     "const r=button?.getBoundingClientRect(),cx=r?r.x+r.width/2:0,cy=r?r.y+r.height/2:0,"
     "centerHit=!!button&&cx>=0&&cy>=0&&cx<innerWidth&&cy<innerHeight&&hit(button,cx,cy),"
     "visiblePointHit=!!button&&!!point(button),scrollNeeded=!!button&&!centerHit&&!visiblePointHit;"
     "if(reason==='none'&&scrollNeeded)reason='scroll-needed';"
     "if(%@)return {candidateCount:cap(candidates.length),exactEligibleLabelCount:cap(eligible.length),"
     "uniqueEligibleMatch:eligible.length===1,matchIsNativeButton:!!button&&button.tagName==='BUTTON',viewportHasArea,"
     "centerHit,visiblePointHit,scrollNeeded,rejectionReason:reason};"
     "if(!button)return null;let visiblePoint=point(button);if(!visiblePoint){button.scrollIntoView({block:'nearest',inline:'nearest',behavior:'instant'});visiblePoint=point(button);}return visiblePoint;})()",
    literal, diagnostic ? @"true" : @"false"];
}

static BOOL ValidID(NSString *value) {
  return [[[[NSUUID alloc] initWithUUIDString:value] UUIDString] isEqualToString:value];
}

static BOOL ProbeViewIsVisibleInWindow(NSView *view, NSWindow *window) {
  if (!view || !window || view.window != window) return NO;
  for (NSView *ancestor = view; ancestor; ancestor = ancestor.superview) {
    if (ancestor.hidden) return NO;
  }
  return YES;
}

static BOOL ValidExtensionID(NSString *value) {
  return value.length == 32 && [value rangeOfCharacterFromSet:
    [[NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnop"] invertedSet]].location == NSNotFound;
}

BOOL ARCReservedBrowserShortcut(NSString *key, NSEventModifierFlags modifiers) {
  NSEventModifierFlags chord = modifiers & (NSEventModifierFlagCommand | NSEventModifierFlagControl |
    NSEventModifierFlagOption | NSEventModifierFlagShift | NSEventModifierFlagFunction);
  if (chord == NSEventModifierFlagCommand) {
    return [@[@"n", @"t", @"l", @"w", @"s", @"q", @"r", @"f", @"g", @"d", @"y", @","] containsObject:key.lowercaseString];
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
- (BOOL)privateIdentityOccupied:(NSString *)identity;
- (BOOL)isPrivateIdentity:(NSString *)identity;
- (BOOL)privateURLIsAllowed:(NSString *)url;
- (BOOL)privateWindowContextOwned:(NSString *)contextID windowID:(NSString *)windowID;
- (BOOL)privateContextEnabled;
- (BOOL)privateOwnerForTabID:(NSString *)tabID windowID:(NSString *)windowID contextID:(NSString *)contextID
                         tab:(ArdiaCoreTab * _Nullable * _Nullable)tabOut window:(ArdiaCoreWindow * _Nullable * _Nullable)windowOut;
- (NSDictionary * _Nullable)privateEntryForTab:(ArdiaCoreTab *)tab identity:(NSString * _Nullable * _Nullable)identityOut;
- (ArdiaCoreTab *)probeVisibilityTargetForID:(NSString *)identity;
- (BOOL)ownedProbePopupID:(NSString *)popupID state:(ARCNativeWindowState * _Nullable * _Nullable)stateOut;
@end

static NSDictionary *ProbeButtonDiagnostic(id value, NSString *reasonOverride) {
  NSArray<NSString *> *booleans = @[
    @"uniqueEligibleMatch", @"matchIsNativeButton", @"viewportHasArea", @"centerHit",
    @"visiblePointHit", @"scrollNeeded",
  ];
  NSMutableDictionary *result = [NSMutableDictionary dictionary];
  NSDictionary *source = [value isKindOfClass:NSDictionary.class] ? value : @{};
  for (NSString *key in booleans) {
    id value = source[key];
    result[key] = [value isKindOfClass:NSNumber.class] &&
      CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID() ? @([value boolValue]) : @NO;
  }
  for (NSString *key in @[@"candidateCount", @"exactEligibleLabelCount"]) {
    NSNumber *number = [source[key] isKindOfClass:NSNumber.class] ? source[key] : @0;
    result[key] = @(MIN(999, MAX(0, number.integerValue)));
  }
  NSSet *reasons = [NSSet setWithArray:@[
    @"invalid_context", @"no_candidate", @"no_exact_label", @"hidden", @"no_area",
    @"disabled", @"ambiguous", @"scroll-needed", @"none",
  ]];
  NSString *reason = reasonOverride ?: ([source[@"rejectionReason"] isKindOfClass:NSString.class]
    ? source[@"rejectionReason"] : @"invalid_context");
  result[@"rejectionReason"] = [reasons containsObject:reason] ? reason : @"invalid_context";
  return result;
}

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
  NSMutableDictionary<NSString *, ArdiaCoreTab *> *_extensionManagers;
  NSMutableDictionary<NSString *, NSMutableDictionary *> *_privateProbeContexts;
  NSMutableDictionary<NSString *, NSMutableDictionary *> *_privateProbeWindows;
  NSMutableDictionary<NSString *, NSDictionary *> *_privateProbeTabs;
  NSMutableDictionary<NSString *, NSDictionary *> *_privateQuitProbeTabs;
  NSMutableDictionary<NSString *, NSMutableDictionary *> *_privateProbeSourceLeases;
  NSMutableDictionary<NSString *, NSString *> *_privateProbePendingContexts;
  NSMutableSet<NSString *> *_privateProbePendingWindows;
  NSMutableSet<NSString *> *_privateProbePendingTabs;
  NSMutableSet<NSString *> *_privateProbeCancelledCloses;
  NSMutableDictionary<NSString *, NSString *> *_owners;
  NSMutableDictionary<NSString *, NSMutableArray *> *_profileWaiters;
  NSString *_openingTabID;
  NSString *_openingProfileID;
  NSString *_openingWindowID;
  BOOL _testing;
  BOOL _externalAppProbeTesting;
  BOOL _probeTLS;
  NSURL *_probeRoot;
  NSMutableDictionary<NSString *, NSDictionary *> *_pendingInstalls;
  NSMutableDictionary<NSString *, NSDictionary *> *_pendingMedia;
  NSMutableDictionary<NSString *, NSDictionary *> *_pendingExternal;
  NSMutableDictionary<NSString *, NSNumber *> *_documentGenerations;
  NSMutableDictionary<NSString *, NSMutableArray<NSDictionary *> *> *_probeExtensions;
  NSMutableArray<NSDictionary *> *_probeDiagnostics;
  NSMutableSet<NSString *> *_pendingHostClosures;
  NSMutableDictionary<NSString *, NSMutableDictionary<NSString *, id> *> *_detachedTabSelections;
  NSMutableDictionary<NSString *, NSString *> *_probeVisibilityLeases;
  BOOL _closingBrowser;
  ARCDownloadService *_downloadService;
  ARCEngineServices *_services;
  ARCLibraryService *_libraryService;
  ARCWebStoreFit *_webStoreFit;
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
  if (_externalAppProbeTesting) strings.push_back(externalProbeSwitch.UTF8String);
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
- (NSImage *)faviconForTabID:(NSString *)tabID profileID:(NSString *)profileID windowID:(NSString *)windowID {
  if (!ValidID(tabID) || !ValidID(profileID) || !ValidID(windowID)) return nil;
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
  if (!_engine || _closingBrowser || !ValidID(identity) || [self privateIdentityOccupied:identity]) {
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
  if (!ValidID(profileID) || !_engine || [self isPrivateIdentity:profileID]) {
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

- (BOOL)privateProbeEnabled {
  return _testing && _probeRoot && ARCProbeRootIsOwned(_probeRoot) && !_closingBrowser;
}

- (BOOL)privateContextEnabled { return _engine != nil && !_closingBrowser; }

- (BOOL)privateIdentityOccupied:(NSString *)identity {
  return _profiles[identity] || _windows[identity] || _tabs[identity] ||
    _privateProbeContexts[identity] || _privateProbeWindows[identity] || _privateProbeTabs[identity] ||
    _privateProbePendingContexts[identity] || [_privateProbePendingWindows containsObject:identity] ||
    [_privateProbePendingTabs containsObject:identity] || _profileWaiters[identity] ||
    [_retiredWindowIDs containsObject:identity];
}

- (BOOL)isPrivateIdentity:(NSString *)identity {
  return _privateProbeContexts[identity] || _privateProbeWindows[identity] || _privateProbeTabs[identity] ||
    _privateProbePendingContexts[identity] || [_privateProbePendingWindows containsObject:identity] ||
    [_privateProbePendingTabs containsObject:identity];
}

- (BOOL)privateProbeIdentityIsAvailable:(NSString *)identity {
  return identity.length && ![self privateIdentityOccupied:identity];
}

- (BOOL)privateURLIsAllowed:(NSString *)url {
  if (!url.length || [url rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound)
    return NO;
  NSURLComponents *components = [NSURLComponents componentsWithString:url];
  BOOL validPort = !components.port || (components.port.integerValue > 0 && components.port.integerValue <= 65535);
  BOOL webURL = components.URL && validPort &&
    [@[@"http", @"https"] containsObject:components.scheme.lowercaseString] && components.host.length &&
    !components.user.length && !components.password.length;
  return webURL || [url isEqualToString:@"about:blank"];
}

- (BOOL)privateWindowContextOwned:(NSString *)contextID windowID:(NSString *)windowID {
  NSDictionary *context = _privateProbeContexts[contextID];
  NSDictionary *window = _privateProbeWindows[windowID];
  NSString *sourceID = context[@"sourceProfileID"];
  NSDictionary *lease = _privateProbeSourceLeases[sourceID];
  return [self privateContextEnabled] && context && window &&
    [window[@"contextID"] isEqualToString:contextID] && ![window[@"closing"] boolValue] &&
    _profiles[sourceID] == context[@"sourceProfile"] &&
    ![context[@"sourceProfile"] destroyed] && ![context[@"sourceProfile"] offTheRecord] &&
    ![context[@"profile"] destroyed] && [context[@"profile"] offTheRecord] &&
    lease[@"profile"] == context[@"profile"] && [lease[@"contextIDs"] containsObject:contextID];
}

- (void)createPrivateContextID:(NSString *)contextID sourceProfileID:(NSString *)sourceProfileID
                        completion:(void (^)(BOOL, NSError *))completion {
  NSAssert(NSThread.isMainThread, @"Private probe creation requires the UI thread");
  ArdiaCoreProfile *source = _profiles[sourceProfileID];
  if (![self privateContextEnabled] || !ValidID(contextID) || !ValidID(sourceProfileID) ||
      !source || source.destroyed || source.offTheRecord ||
      ![self privateProbeIdentityIsAvailable:contextID]) {
    completion(NO, BridgeError(@"Invalid private probe context or source profile."));
    return;
  }
  if (_privateProbePendingContexts[contextID]) {
    completion(NO, BridgeError(@"Private probe context identity is already pending."));
    return;
  }
  NSMutableDictionary *lease = _privateProbeSourceLeases[sourceProfileID];
  ArdiaCoreProfile *leasedProfile = NSClassFromString(@"ArdiaCoreProfile") &&
    [lease[@"profile"] isKindOfClass:NSClassFromString(@"ArdiaCoreProfile")]
    ? lease[@"profile"] : nil;
  if (lease && leasedProfile && !leasedProfile.destroyed) {
    [lease[@"contextIDs"] addObject:contextID];
    _privateProbeContexts[contextID] = [@{@"sourceProfileID": sourceProfileID,
      @"sourceProfile": source, @"profile": leasedProfile, @"windows": [NSMutableSet set],
      @"pendingWindows": [NSMutableSet set]} mutableCopy];
    completion(YES, nil);
    return;
  }
  BOOL startFactory = lease == nil;
  if (!lease) {
    lease = [@{@"sourceProfile": source, @"pending": [NSMutableDictionary dictionary],
      @"contextIDs": [NSMutableSet set], @"profile": NSNull.null} mutableCopy];
    _privateProbeSourceLeases[sourceProfileID] = lease;
  }
  lease[@"pending"][contextID] = [completion copy];
  _privateProbePendingContexts[contextID] = sourceProfileID;
  if (!startFactory) return;
  NSMutableDictionary *capturedLease = lease;
  dispatch_async(dispatch_get_main_queue(), ^{
    if (self->_privateProbeSourceLeases[sourceProfileID] != capturedLease ||
        ![self privateContextEnabled]) {
      if (self->_privateProbeSourceLeases[sourceProfileID] == capturedLease) {
        NSDictionary *pending = [capturedLease[@"pending"] copy];
        [capturedLease[@"pending"] removeAllObjects];
        [self->_privateProbeSourceLeases removeObjectForKey:sourceProfileID];
        for (NSString *pendingID in pending) {
          [self->_privateProbePendingContexts removeObjectForKey:pendingID];
          void (^waiter)(BOOL, NSError *) = pending[pendingID];
          waiter(NO, BridgeError(@"Off-the-record profile creation was cancelled."));
        }
      }
      return;
    }
    [self->_engine offTheRecordProfileFor:source completion:^(ArdiaCoreProfile *privateProfile, NSString *message) {
        NSMutableDictionary *current = self->_privateProbeSourceLeases[sourceProfileID];
        if (current != capturedLease) {
          // A stale callback cannot release ArdiaCore's shared primary OTR profile.
          return;
        }
        BOOL valid = self->_profiles[sourceProfileID] == source && !source.destroyed && !source.offTheRecord &&
          privateProfile && !privateProfile.destroyed && privateProfile.offTheRecord && privateProfile != source;
        if (valid) current[@"profile"] = privateProfile;
        NSDictionary *pending = [current[@"pending"] copy];
        [current[@"pending"] removeAllObjects];
        NSMutableSet<NSString *> *registered = [NSMutableSet set];
        for (NSString *pendingID in pending) {
          [self->_privateProbePendingContexts removeObjectForKey:pendingID];
          if (valid && [self privateContextEnabled] &&
              [self privateProbeIdentityIsAvailable:pendingID]) {
            [current[@"contextIDs"] addObject:pendingID];
            self->_privateProbeContexts[pendingID] = [@{@"sourceProfileID": sourceProfileID,
              @"sourceProfile": source, @"profile": privateProfile,
              @"windows": [NSMutableSet set], @"pendingWindows": [NSMutableSet set]} mutableCopy];
            [registered addObject:pendingID];
          }
        }
        for (NSString *pendingID in pending) {
          void (^waiter)(BOOL, NSError *) = pending[pendingID];
          NSMutableDictionary *context = self->_privateProbeContexts[pendingID];
          BOOL stillOwned = [registered containsObject:pendingID] &&
            self->_privateProbeSourceLeases[sourceProfileID] == capturedLease &&
            [current[@"contextIDs"] containsObject:pendingID] &&
            context[@"sourceProfile"] == source && context[@"profile"] == privateProfile &&
            self->_profiles[sourceProfileID] == source && !source.destroyed &&
            !privateProfile.destroyed && privateProfile.offTheRecord &&
            [self privateContextEnabled];
          if (stillOwned) {
            waiter(YES, nil);
          } else {
            if (context && [registered containsObject:pendingID]) {
              [self->_privateProbeContexts removeObjectForKey:pendingID];
              [current[@"contextIDs"] removeObject:pendingID];
            }
            waiter(NO, BridgeError(message.length ? message : @"Off-the-record profile creation was rejected."));
          }
        }
        if (self->_privateProbeSourceLeases[sourceProfileID] == capturedLease &&
            [(NSSet *)current[@"contextIDs"] count] == 0 &&
            [(NSDictionary *)current[@"pending"] count] == 0) {
          [self->_privateProbeSourceLeases removeObjectForKey:sourceProfileID];
          if (valid && !privateProfile.destroyed) [self->_engine releaseProfile:privateProfile];
        }
    }];
  });
}

- (void)beginPrivateProbeContextID:(NSString *)contextID sourceProfileID:(NSString *)sourceProfileID
                        completion:(void (^)(BOOL, NSError *))completion {
  if (![self privateProbeEnabled]) {
    completion(NO, BridgeError(@"Private probe context requires an owned testing root."));
    return;
  }
  [self createPrivateContextID:contextID sourceProfileID:sourceProfileID completion:completion];
}

- (BOOL)openPrivateProbeWindowID:(NSString *)windowID contextID:(NSString *)contextID
                            tabID:(NSString *)tabID url:(NSString *)url error:(NSError **)error {
  NSURLComponents *components = [NSURLComponents componentsWithString:url ?: @""];
  if (![self privateProbeEnabled] || ![components.scheme.lowercaseString isEqualToString:@"http"] ||
      ![@[@"127.0.0.1", @"::1", @"localhost"] containsObject:components.host.lowercaseString] ||
      !components.port) {
    if (error) *error = BridgeError(@"Private probe navigation requires the owned loopback fixture.");
    return NO;
  }
  return [self createPrivateWindowID:windowID contextID:contextID tabID:tabID url:url error:error];
}

- (BOOL)createPrivateWindowID:(NSString *)windowID contextID:(NSString *)contextID
                         tabID:(NSString *)tabID url:(NSString *)url error:(NSError **)error {
  NSAssert(NSThread.isMainThread, @"Private windows require the UI thread");
  NSMutableDictionary *context = _privateProbeContexts[contextID];
  ArdiaCoreProfile *profile = context[@"profile"];
  if (![self privateContextEnabled] || !ValidID(windowID) || !ValidID(tabID) ||
      [windowID isEqualToString:contextID] || [tabID isEqualToString:contextID] ||
      [tabID isEqualToString:windowID] || !context ||
      ![self privateProbeIdentityIsAvailable:windowID] ||
      ![self privateProbeIdentityIsAvailable:tabID] ||
      !profile || profile.destroyed || !profile.offTheRecord || ![self privateURLIsAllowed:url]) {
    if (error) *error = BridgeError(@"Invalid, unknown, closed, or unsupported private navigation.");
    return NO;
  }
  [context[@"pendingWindows"] addObject:windowID];
  [_privateProbePendingWindows addObject:windowID];
  [_privateProbePendingTabs addObject:tabID];
  context[@"pendingReleaseRejected"] = @(![self releasePrivateContextID:contextID]);
  NSMutableDictionary *capturedContext = context;
  NSMutableDictionary *capturedLease = _privateProbeSourceLeases[context[@"sourceProfileID"]];
  ArdiaCoreProfile *source = context[@"sourceProfile"];
  BOOL (^creationCurrent)(void) = ^BOOL{
    return [self privateContextEnabled] && self->_privateProbeContexts[contextID] == capturedContext &&
      self->_privateProbeSourceLeases[capturedContext[@"sourceProfileID"]] == capturedLease &&
      self->_profiles[capturedContext[@"sourceProfileID"]] == source && !source.destroyed &&
      capturedContext[@"profile"] == profile && !profile.destroyed && profile.offTheRecord &&
      [capturedContext[@"pendingWindows"] containsObject:windowID] &&
      [self->_privateProbePendingWindows containsObject:windowID] &&
      [self->_privateProbePendingTabs containsObject:tabID];
  };
  ArdiaCoreWindow *native = [[NSClassFromString(@"ArdiaCoreWindow") alloc]
    initWithContentRect:NSMakeRect(0, 0, 640, 480)];
  if (!native || !native.window || !creationCurrent()) {
    [native close];
    [context[@"pendingWindows"] removeObject:windowID];
    [_privateProbePendingWindows removeObject:windowID];
    [_privateProbePendingTabs removeObject:tabID];
    if (error) *error = BridgeError(@"Chromium could not create the private window.");
    return NO;
  }
  [native prepareProfile:profile];
  if (!creationCurrent()) {
    [native close];
    [context[@"pendingWindows"] removeObject:windowID];
    [_privateProbePendingWindows removeObject:windowID];
    [_privateProbePendingTabs removeObject:tabID];
    if (error) *error = BridgeError(@"Private context retired during window preparation.");
    return NO;
  }
  native.activeProfile = profile;
  ArdiaCoreTab *tab = [native openTab:url profile:profile foreground:YES];
  if (!tab || !native.hostView || !tab.view || !creationCurrent()) {
    [tab closeNow];
    [native close];
    [context[@"pendingWindows"] removeObject:windowID];
    [_privateProbePendingWindows removeObject:windowID];
    [_privateProbePendingTabs removeObject:tabID];
    if (error) *error = BridgeError(@"Chromium could not create the private tab.");
    return NO;
  }
  tab.view.frame = native.hostView.bounds;
  tab.view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  [native.hostView addSubview:tab.view];
  [tab loadURL:url];
  tab.delegate = self;
  if (!creationCurrent()) {
    [tab closeNow];
    [native close];
    [context[@"pendingWindows"] removeObject:windowID];
    [_privateProbePendingWindows removeObject:windowID];
    [_privateProbePendingTabs removeObject:tabID];
    if (error) *error = BridgeError(@"Private context retired during navigation start.");
    return NO;
  }
  [native activateTab:tab];
  if (!creationCurrent()) {
    [tab closeNow];
    [native close];
    [context[@"pendingWindows"] removeObject:windowID];
    [_privateProbePendingWindows removeObject:windowID];
    [_privateProbePendingTabs removeObject:tabID];
    if (error) *error = BridgeError(@"Private context retired during tab activation.");
    return NO;
  }
  __weak ARCChromiumRuntime *weakSelf = self;
  id observer = [NSNotificationCenter.defaultCenter addObserverForName:NSWindowWillCloseNotification
    object:native.window queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *) {
      [weakSelf privateProbeWindowDidCloseID:windowID];
    }];
  _privateProbeWindows[windowID] = [@{@"contextID": contextID, @"native": native,
    @"tabIDs": [NSMutableSet setWithObject:tabID], @"observer": observer,
    @"closing": @NO, @"selectedTabID": tabID} mutableCopy];
  _privateProbeTabs[tabID] = [@{@"contextID": contextID, @"windowID": windowID, @"tab": tab,
    @"closing": @NO} mutableCopy];
  tab.view.hidden = NO;
  [context[@"pendingWindows"] removeObject:windowID];
  [_privateProbePendingWindows removeObject:windowID];
  [_privateProbePendingTabs removeObject:tabID];
  [context[@"windows"] addObject:windowID];
  native.delegate = self;
  [self publish:tab];
  if (self.onPrivateTabSelected) self.onPrivateTabSelected(contextID, windowID, tabID);
  return YES;
}

- (BOOL)privateOwnerForTabID:(NSString *)tabID windowID:(NSString *)windowID contextID:(NSString *)contextID
                         tab:(ArdiaCoreTab **)tabOut window:(ArdiaCoreWindow **)windowOut {
  NSDictionary *tabEntry = _privateProbeTabs[tabID];
  NSDictionary *windowEntry = _privateProbeWindows[windowID];
  NSDictionary *context = _privateProbeContexts[contextID];
  ArdiaCoreTab *tab = tabEntry[@"tab"];
  ArdiaCoreWindow *window = windowEntry[@"native"];
  BOOL valid = [self privateContextEnabled] && tabEntry && windowEntry && context && tab && !tab.closed &&
    window && [self privateWindowContextOwned:contextID windowID:windowID] &&
    [tabEntry[@"contextID"] isEqualToString:contextID] &&
    [tabEntry[@"windowID"] isEqualToString:windowID] &&
    [windowEntry[@"contextID"] isEqualToString:contextID] &&
    [windowEntry[@"tabIDs"] containsObject:tabID] && context[@"profile"] == tab.profile &&
    _profiles[context[@"sourceProfileID"]] == context[@"sourceProfile"] &&
    _privateProbeSourceLeases[context[@"sourceProfileID"]][@"profile"] == context[@"profile"] &&
    [_privateProbeSourceLeases[context[@"sourceProfileID"]][@"contextIDs"] containsObject:contextID] &&
    tab.profile.offTheRecord && !tab.profile.destroyed;
  if (valid) {
    if (tabOut) *tabOut = tab;
    if (windowOut) *windowOut = window;
  }
  return valid;
}

- (BOOL)openPrivateTabID:(NSString *)tabID windowID:(NSString *)windowID contextID:(NSString *)contextID
                     url:(NSString *)url error:(NSError **)error {
  NSAssert(NSThread.isMainThread, @"Private tabs require the UI thread");
  NSDictionary *context = _privateProbeContexts[contextID];
  NSMutableDictionary *windowEntry = _privateProbeWindows[windowID];
  ArdiaCoreWindow *native = windowEntry[@"native"];
  ArdiaCoreProfile *profile = context[@"profile"];
  if (![self privateContextEnabled] || !ValidID(tabID) || !windowEntry || !context ||
      ![windowEntry[@"contextID"] isEqualToString:contextID] ||
      [windowEntry[@"closing"] boolValue] || !native || ![self privateProbeIdentityIsAvailable:tabID] ||
      !profile || profile.destroyed || !profile.offTheRecord || ![self privateURLIsAllowed:url]) {
    if (error) *error = BridgeError(@"Invalid private tab owner or unsupported navigation.");
    return NO;
  }
  NSMutableDictionary *lease = _privateProbeSourceLeases[context[@"sourceProfileID"]];
  ArdiaCoreProfile *source = context[@"sourceProfile"];
  if (!lease || !source || source.destroyed || _profiles[context[@"sourceProfileID"]] != source) {
    if (error) *error = BridgeError(@"The private source lease is unavailable.");
    return NO;
  }
  NSMutableDictionary *capturedContext = _privateProbeContexts[contextID];
  NSMutableDictionary *capturedWindow = windowEntry;
  BOOL (^current)(void) = ^BOOL{
    return [self privateContextEnabled] && self->_privateProbeContexts[contextID] == capturedContext &&
      self->_privateProbeWindows[windowID] == capturedWindow &&
      self->_privateProbeSourceLeases[capturedContext[@"sourceProfileID"]] == lease &&
      self->_profiles[capturedContext[@"sourceProfileID"]] == source && !source.destroyed &&
      capturedContext[@"profile"] == profile && !profile.destroyed && profile.offTheRecord &&
      ![capturedWindow[@"closing"] boolValue] && ![capturedWindow[@"closed"] boolValue] &&
      ![self privateProbeIdentityIsAvailable:tabID];
  };
  if (windowEntry[@"pendingTabs"] == nil) windowEntry[@"pendingTabs"] = [NSMutableSet set];
  if ([windowEntry[@"pendingTabs"] containsObject:tabID]) return NO;
  [windowEntry[@"pendingTabs"] addObject:tabID];
  [_privateProbePendingTabs addObject:tabID];
  ArdiaCoreTab *tab = [native openTab:url profile:profile foreground:NO];
  if (!tab || tab.closed || tab.profile != profile || !tab.view || !native.hostView || !current()) {
    [tab closeNow];
    [windowEntry[@"pendingTabs"] removeObject:tabID];
    [_privateProbePendingTabs removeObject:tabID];
    if (error) *error = BridgeError(@"Chromium could not create the private tab.");
    return NO;
  }
  NSMutableDictionary *entry = [@{@"contextID": contextID, @"windowID": windowID, @"tab": tab,
    @"closing": @NO} mutableCopy];
  _privateProbeTabs[tabID] = entry;
  [windowEntry[@"tabIDs"] addObject:tabID];
  [windowEntry[@"pendingTabs"] removeObject:tabID];
  [_privateProbePendingTabs removeObject:tabID];
  tab.view.frame = native.hostView.bounds;
  tab.view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  [native.hostView addSubview:tab.view];
  tab.delegate = self;
  tab.view.hidden = YES;
  if (!current() || _privateProbeTabs[tabID] != entry) {
    [tab closeNow];
    if (error) *error = BridgeError(@"Private tab owner changed during creation.");
    return NO;
  }
  [tab loadURL:url];
  if (!current() || _privateProbeTabs[tabID] != entry) {
    [tab closeNow];
    if (error) *error = BridgeError(@"Private tab owner changed during navigation start.");
    return NO;
  }
  [self publish:tab];
  return YES;
}

- (BOOL)selectPrivateTabID:(NSString *)tabID windowID:(NSString *)windowID contextID:(NSString *)contextID {
  ArdiaCoreTab *tab = nil;
  ArdiaCoreWindow *window = nil;
  if (![self privateOwnerForTabID:tabID windowID:windowID contextID:contextID tab:&tab window:&window]) return NO;
  window.activeProfile = tab.profile;
  ((NSMutableDictionary *)_privateProbeWindows[windowID])[@"selectedTabID"] = tabID;
  for (NSString *identity in _privateProbeWindows[windowID][@"tabIDs"]) {
    ArdiaCoreTab *ownedTab = _privateProbeTabs[identity][@"tab"];
    ownedTab.view.hidden = ![identity isEqualToString:tabID];
  }
  [window activateTab:tab];
  if (self.onPrivateTabSelected) self.onPrivateTabSelected(contextID, windowID, tabID);
  return YES;
}

- (void)closePrivateTabID:(NSString *)tabID windowID:(NSString *)windowID contextID:(NSString *)contextID
               completion:(void (^)(BOOL))completion {
  ArdiaCoreTab *tab = nil;
  if (![self privateOwnerForTabID:tabID windowID:windowID contextID:contextID tab:&tab window:nil]) {
    completion(NO);
    return;
  }
  NSMutableDictionary *entry = (NSMutableDictionary *)_privateProbeTabs[tabID];
  if ([entry[@"closing"] boolValue] || entry[@"closeCompletion"]) {
    completion(NO);
    return;
  }
  entry[@"closing"] = @YES;
  entry[@"closeCompletion"] = [completion copy];
  [tab close];
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
    if (self->_privateProbeTabs[tabID] != entry) return;
    void (^pending)(BOOL) = entry[@"closeCompletion"];
    entry[@"closeCompletion"] = nil;
    entry[@"closing"] = @NO;
    if (pending) pending(NO);
  });
}

- (BOOL)navigatePrivateTabID:(NSString *)tabID windowID:(NSString *)windowID contextID:(NSString *)contextID url:(NSString *)url {
  ArdiaCoreTab *tab = nil;
  if (![self privateOwnerForTabID:tabID windowID:windowID contextID:contextID tab:&tab window:nil]) return NO;
  if (![self privateURLIsAllowed:url]) return NO;
  [tab loadURL:url];
  return [self privateOwnerForTabID:tabID windowID:windowID contextID:contextID tab:nil window:nil];
}
- (BOOL)focusPrivateTabID:(NSString *)tabID windowID:(NSString *)windowID contextID:(NSString *)contextID {
  ArdiaCoreTab *tab = nil;
  if (![self privateOwnerForTabID:tabID windowID:windowID contextID:contextID tab:&tab window:nil]) return NO;
  [tab focus];
  return [self privateOwnerForTabID:tabID windowID:windowID contextID:contextID tab:nil window:nil];
}
- (BOOL)reloadPrivateTabID:(NSString *)tabID windowID:(NSString *)windowID contextID:(NSString *)contextID {
  ArdiaCoreTab *tab = nil;
  if (![self privateOwnerForTabID:tabID windowID:windowID contextID:contextID tab:&tab window:nil]) return NO;
  [tab reload];
  return YES;
}
- (BOOL)goBackPrivateTabID:(NSString *)tabID windowID:(NSString *)windowID contextID:(NSString *)contextID {
  ArdiaCoreTab *tab = nil;
  if (![self privateOwnerForTabID:tabID windowID:windowID contextID:contextID tab:&tab window:nil] || !tab.canGoBack) return NO;
  [tab goBack];
  return YES;
}
- (BOOL)goForwardPrivateTabID:(NSString *)tabID windowID:(NSString *)windowID contextID:(NSString *)contextID {
  ArdiaCoreTab *tab = nil;
  if (![self privateOwnerForTabID:tabID windowID:windowID contextID:contextID tab:&tab window:nil] || !tab.canGoForward) return NO;
  [tab goForward];
  return YES;
}
- (NSWindow *)windowForPrivateWindowID:(NSString *)windowID contextID:(NSString *)contextID {
  NSDictionary *entry = _privateProbeWindows[windowID];
  return [self privateWindowContextOwned:contextID windowID:windowID] ? [entry[@"native"] window] : nil;
}
- (NSView *)hostViewForPrivateWindowID:(NSString *)windowID contextID:(NSString *)contextID {
  NSDictionary *entry = _privateProbeWindows[windowID];
  return [self privateWindowContextOwned:contextID windowID:windowID] ? [entry[@"native"] hostView] : nil;
}
- (NSView *)viewForPrivateTabID:(NSString *)tabID windowID:(NSString *)windowID contextID:(NSString *)contextID {
  ArdiaCoreTab *tab = nil;
  return [self privateOwnerForTabID:tabID windowID:windowID contextID:contextID tab:&tab window:nil]
    ? tab.view : nil;
}

- (void)evaluatePrivateProbeTabID:(NSString *)tabID script:(NSString *)script
                       completion:(void (^)(NSString *))completion {
  NSDictionary *entry = _privateProbeTabs[tabID];
  ArdiaCoreTab *tab = entry[@"tab"];
  NSMutableDictionary *context = _privateProbeContexts[entry[@"contextID"]];
  if (![self privateProbeEnabled] || !tab || tab.closed || !context ||
      !tab.profile.offTheRecord || tab.profile != context[@"profile"]) {
    if (context) context[@"privateEvaluationRejected"] = @YES;
    completion(nil);
    return;
  }
  NSMutableDictionary *capturedContext = context;
  NSMutableDictionary *lease = _privateProbeSourceLeases[context[@"sourceProfileID"]];
  ArdiaCoreProfile *source = context[@"sourceProfile"];
  [self evaluateTab:tab script:script completion:^(NSString *json) {
    NSDictionary *current = self->_privateProbeTabs[tabID];
    BOOL currentOwner = current == entry && self->_privateProbeContexts[entry[@"contextID"]] == capturedContext &&
      self->_privateProbeSourceLeases[capturedContext[@"sourceProfileID"]] == lease &&
      self->_profiles[capturedContext[@"sourceProfileID"]] == source && !source.destroyed &&
      capturedContext[@"profile"] == tab.profile && !tab.closed;
    if (!currentOwner) capturedContext[@"privateEvaluationStale"] = @YES;
    else if (json) capturedContext[@"privateEvaluationSucceeded"] = @YES;
    else capturedContext[@"privateEvaluationTimedOut"] = @YES;
    completion(currentOwner ? json : nil);
  }];
}

- (void)privateProbeWindowDidCloseID:(NSString *)windowID {
  NSMutableDictionary *entry = _privateProbeWindows[windowID];
  if (!entry || [entry[@"closed"] boolValue]) return;
  entry[@"closed"] = @YES;
  NSString *contextID = entry[@"contextID"];
  NSMutableDictionary *context = _privateProbeContexts[contextID];
  NSArray<NSString *> *tabIDs = [entry[@"tabIDs"] allObjects];
  NSMutableArray<NSDictionary *> *tabClosures = [NSMutableArray array];
  NSMutableArray<NSString *> *retiredTabIDs = [NSMutableArray array];
  for (NSString *tabID in tabIDs) {
    NSDictionary *tabEntry = _privateProbeTabs[tabID];
    if (tabEntry) [retiredTabIDs addObject:tabID];
    if (tabEntry[@"closeCompletion"])
      [tabClosures addObject:@{@"entry": tabEntry, @"completion": tabEntry[@"closeCompletion"]}];
    [_privateProbeTabs removeObjectForKey:tabID];
    [_privateProbePendingTabs removeObject:tabID];
  }
  id observer = entry[@"observer"];
  if (observer) [NSNotificationCenter.defaultCenter removeObserver:observer];
  [_privateProbeWindows removeObjectForKey:windowID];
  [context[@"windows"] removeObject:windowID];
  if (_closingBrowser && [(NSSet *)context[@"windows"] count] == 0 &&
      [(NSSet *)context[@"pendingWindows"] count] == 0) {
    context[@"finalCloseConfirmedWhileQuitting"] = @YES;
  }
  for (NSString *tabID in retiredTabIDs) {
    if (self.onPrivateTabClosed) self.onPrivateTabClosed(contextID, windowID, tabID);
  }
  for (NSDictionary *closure in tabClosures) {
    void (^closeCompletion)(BOOL) = closure[@"completion"];
    if (closeCompletion) closeCompletion(YES);
  }
  if (self.onPrivateWindowClosed) self.onPrivateWindowClosed(contextID, windowID);
  void (^completion)(BOOL) = entry[@"closeCompletion"];
  if (completion) completion(YES);
}

- (void)closePrivateProbeWindowID:(NSString *)windowID completion:(void (^)(BOOL))completion {
  NSDictionary *entry = _privateProbeWindows[windowID];
  NSString *contextID = entry[@"contextID"];
  if (![self privateProbeEnabled]) { completion(NO); return; }
  [self closePrivateWindowID:windowID contextID:contextID completion:completion];
}

- (void)closePrivateWindowID:(NSString *)windowID contextID:(NSString *)contextID
                  completion:(void (^)(BOOL))completion {
  NSMutableDictionary *entry = _privateProbeWindows[windowID];
  NSMutableDictionary *context = _privateProbeContexts[contextID];
  BOOL ownedQuitClose = _closingBrowser && _testing && _probeRoot &&
      ARCProbeRootIsOwned(_probeRoot) && _engine && entry && context &&
      [entry[@"contextID"] isEqualToString:contextID] &&
      [context[@"windows"] containsObject:windowID];
  if ((!_engine || (_closingBrowser && !ownedQuitClose)) || !entry ||
      ![entry[@"contextID"] isEqualToString:contextID] || entry[@"closeCompletion"]) {
    completion(NO);
    return;
  }
  ArdiaCoreWindow *native = entry[@"native"];
  if (!native || !context || ![context[@"windows"] containsObject:windowID]) {
    completion(NO);
    return;
  }
  if ([entry[@"closing"] boolValue]) {
    if (!ownedQuitClose) { completion(NO); return; }
    entry[@"ownerCloseRequestedWhileQuitting"] = @YES;
    entry[@"closeCompletion"] = [completion copy];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
      NSMutableDictionary *current = self->_privateProbeWindows[windowID];
      if (current != entry) return;
      void (^pending)(BOOL) = current[@"closeCompletion"];
      current[@"closeCompletion"] = nil;
      if (pending) pending(NO);
    });
    return;
  }
  entry[@"closing"] = @YES;
  entry[@"ownerCloseRequestedWhileQuitting"] = @(_closingBrowser);
  entry[@"closeCompletion"] = [completion copy];
  [native.window performClose:nil];
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
    NSMutableDictionary *current = self->_privateProbeWindows[windowID];
    if (current != entry) return;
    void (^pending)(BOOL) = current[@"closeCompletion"];
    current[@"closeCompletion"] = nil;
    if (pending) pending(NO);
  });
}

- (BOOL)attemptCancelledPrivateProbeCloseID:(NSString *)windowID {
  NSMutableDictionary *entry = _privateProbeWindows[windowID];
  if (![self privateProbeEnabled] || !entry || [entry[@"closing"] boolValue]) return NO;
  [_privateProbeCancelledCloses addObject:windowID];
  [((ArdiaCoreWindow *)entry[@"native"]).window performClose:nil];
  NSString *tabID = [entry[@"tabIDs"] anyObject];
  NSDictionary *tabEntry = _privateProbeTabs[tabID];
  return _privateProbeWindows[windowID] == entry && ![entry[@"closing"] boolValue] &&
    tabEntry && ![tabEntry[@"tab"] closed];
}

- (NSDictionary *)privateProbeAuditForContextID:(NSString *)contextID {
  NSMutableDictionary *context = _privateProbeContexts[contextID];
  ArdiaCoreProfile *source = context[@"sourceProfile"];
  ArdiaCoreProfile *profile = context[@"profile"];
  BOOL ownedTestingRoot = _testing && _probeRoot && ARCProbeRootIsOwned(_probeRoot) && _engine;
  if (!ownedTestingRoot || !context || !source || !profile) return nil;
  NSUInteger tabCount = 0;
  BOOL allHidden = YES;
  BOOL allWindowsNativeWindowsAlive = YES;
  BOOL allTabsLoaded = YES;
  BOOL allTabsAuthoredLoopbackURL = YES;
  BOOL anyTabLoading = NO;
  BOOL allTabsInNativeProfileBrowser = YES;
  BOOL allTabsAttachedToHostView = YES;
  BOOL allWindowsUsePrivateActiveProfile = YES;
  BOOL allWindowsDisplayOwnedWebContents = YES;
  NSUInteger visibleNativeViewportCount = 0;
  for (NSString *windowID in context[@"windows"]) {
    NSMutableDictionary *window = _privateProbeWindows[windowID];
    ArdiaCoreWindow *nativeWindowObject = window[@"native"];
    NSUInteger visiblePrivateViews = 0;
    if (nativeWindowObject.activeProfile != profile) allWindowsUsePrivateActiveProfile = NO;
    for (NSString *tabID in window[@"tabIDs"]) {
      ArdiaCoreTab *tab = _privateProbeTabs[tabID][@"tab"];
      NSURL *tabURL = [NSURL URLWithString:tab.url ?: @""];
      tabCount++;
      if (!tab || ![[nativeWindowObject tabsForProfile:profile] containsObject:tab])
        allTabsInNativeProfileBrowser = NO;
      if (!tab.view || tab.view.superview != nativeWindowObject.hostView)
        allTabsAttachedToHostView = NO;
      BOOL selected = [window[@"selectedTabID"] isEqualToString:tabID];
      if (tab.view && !tab.view.hidden && tab.view.window == nativeWindowObject.window) visiblePrivateViews++;
      if (selected && (!tab.view || tab.view.hidden || tab.view.window != nativeWindowObject.window))
        allWindowsDisplayOwnedWebContents = NO;
      BOOL loopback = [tabURL.host isEqualToString:@"127.0.0.1"];
      if (!tab || tab.closed || tab.loading || !loopback) allTabsLoaded = NO;
      if (!loopback) allTabsAuthoredLoopbackURL = NO;
      if (tab.loading) anyTabLoading = YES;
    }
    visibleNativeViewportCount += visiblePrivateViews;
    NSWindow *nativeWindow = [window[@"native"] window];
    if (!nativeWindow) allWindowsNativeWindowsAlive = NO;
    if (visiblePrivateViews != 1) allWindowsDisplayOwnedWebContents = NO;
    if (!nativeWindow || nativeWindow.isVisible) allHidden = NO;
  }
  NSString *sourceProfileID = context[@"sourceProfileID"];
  NSDictionary *lease = _privateProbeSourceLeases[sourceProfileID];
  return @{@"sourceIsRegular": @(!source.destroyed && !source.offTheRecord),
           @"contextIsPrivate": @(!profile.destroyed && profile.offTheRecord),
           @"contextDistinct": @(profile != source),
           @"windowCount": @([context[@"windows"] count]), @"tabCount": @(tabCount),
           @"allWindowsNativeWindowsAlive": @(allWindowsNativeWindowsAlive),
           @"allWindowsHidden": @(allHidden), @"allTabsLoaded": @(allTabsLoaded),
           @"allTabsAuthoredLoopbackURL": @(allTabsAuthoredLoopbackURL),
           @"anyTabLoading": @(anyTabLoading),
           @"allTabsInNativeProfileBrowser": @(allTabsInNativeProfileBrowser),
           @"allTabsAttachedToHostView": @(allTabsAttachedToHostView),
           @"allWindowsUsePrivateActiveProfile": @(allWindowsUsePrivateActiveProfile),
           @"allWindowsDisplayOwnedWebContents": @(allWindowsDisplayOwnedWebContents),
           @"visibleNativeViewportCount": @(visibleNativeViewportCount),
           @"pendingWindowCount": @([(NSSet *)context[@"pendingWindows"] count]),
           @"pendingReleaseRejected": context[@"pendingReleaseRejected"] ?: @NO,
           @"sourceLeaseOwnsContext": @([lease[@"contextIDs"] containsObject:contextID]),
           @"privateEvaluationRejected": context[@"privateEvaluationRejected"] ?: @NO,
           @"privateEvaluationStale": context[@"privateEvaluationStale"] ?: @NO,
           @"privateEvaluationSucceeded": context[@"privateEvaluationSucceeded"] ?: @NO,
           @"privateEvaluationTimedOut": context[@"privateEvaluationTimedOut"] ?: @NO,
           @"privateQuitDialogCancelResult": context[@"privateQuitDialogCancelResult"] ?: @"not-attempted",
           @"profileToken": [NSString stringWithFormat:@"%p", profile],
           @"profileAlive": @(!profile.destroyed),
           @"noPendingFactory": @([(NSDictionary *)lease[@"pending"] count] == 0)};
}

- (void)capturePrivateProbeTabID:(NSString *)tabID windowID:(NSString *)windowID
                       contextID:(NSString *)contextID
                      completion:(void (^)(NSData *, NSString *))completion {
  ArdiaCoreTab *tab = nil;
  ArdiaCoreWindow *nativeWindow = nil;
  NSMutableDictionary *window = _privateProbeWindows[windowID];
  BOOL valid = [self privateProbeEnabled] &&
      [self privateOwnerForTabID:tabID windowID:windowID contextID:contextID tab:&tab window:&nativeWindow] &&
      [window[@"selectedTabID"] isEqualToString:tabID] && ![window[@"closing"] boolValue] &&
      !tab.loading && tab.profile.offTheRecord && tab.view &&
      (tab.view == nativeWindow.hostView || [tab.view isDescendantOf:nativeWindow.hostView]) &&
      ProbeViewIsVisibleInWindow(tab.view, nativeWindow.window);
  NSURL *url = [NSURL URLWithString:tab.url ?: @""];
  valid = valid && [url.scheme isEqualToString:@"http"] &&
      [@[@"127.0.0.1", @"localhost"] containsObject:url.host.lowercaseString ?: @""];
  if (!valid) { completion(nil, @"private-owner-rejected"); return; }
  NSDictionary *capturedEntry = _privateProbeTabs[tabID];
  [self captureProbeTab:tab diagnosticCompletion:^(NSData *data, NSString *error) {
    BOOL current = self->_privateProbeTabs[tabID] == capturedEntry &&
        [self privateOwnerForTabID:tabID windowID:windowID contextID:contextID tab:nil window:nil] &&
        [window[@"selectedTabID"] isEqualToString:tabID] && !tab.closed && !tab.loading;
    completion(current ? data : nil, !current ? @"private-owner-stale" : error);
  }];
}

- (NSDictionary *)normalProbeSelectionAuditForTabID:(NSString *)tabID {
  if (![self privateProbeEnabled]) return @{};
  ArdiaCoreTab *tab = _tabs[tabID];
  ARCNativeWindowState *state = [self stateForTabID:tabID];
  NSView *view = tab.view;
  NSWindow *window = state.native.window;
  __block NSUInteger visibleTabViewCount = 0;
  [_tabs enumerateKeysAndObjectsUsingBlock:^(NSString *identity, ArdiaCoreTab *ownedTab, BOOL *stop) {
    if (ownedTab.view && ProbeViewIsVisibleInWindow(ownedTab.view, window)) visibleTabViewCount++;
  }];
  BOOL primaryWindow = state && [state.identity isEqualToString:_primaryWindowID];
  BOOL selectedID = state && [state.selectedTabID isEqualToString:tabID];
  BOOL activeProfile = state && tab && state.native.activeProfile == tab.profile;
  BOOL liveTab = tab && !tab.closed;
  BOOL nativeProfileOwnsTab = state && tab &&
    [[state.native tabsForProfile:tab.profile] containsObject:tab];
  BOOL selected = primaryWindow && selectedID && activeProfile && liveTab && nativeProfileOwnsTab &&
    !state.closed && !state.closing && !_closingBrowser;
  BOOL attached = selected && view && state.native.hostView &&
    (view == state.native.hostView || [view isDescendantOf:state.native.hostView]);
  BOOL visible = selected && ProbeViewIsVisibleInWindow(view, window);
  BOOL displayed = visible && attached && visibleTabViewCount == 1;
  return @{@"selectedNativeTab": @(selected), @"displayedNativeWebContents": @(displayed),
           @"primaryWindow": @(primaryWindow), @"selectedID": @(selectedID),
           @"activeProfile": @(activeProfile), @"liveTab": @(liveTab),
           @"nativeProfileOwnsTab": @(nativeProfileOwnsTab),
           @"selectedViewAttached": @(attached), @"selectedViewVisible": @(visible),
           @"visibleNativeViewCount": @(visibleTabViewCount),
           @"nativeTabToken": tab ? [NSString stringWithFormat:@"%p", tab] : @"missing"};
}

- (BOOL)releasePrivateProbeContextID:(NSString *)contextID {
  if (![self privateProbeEnabled]) return NO;
  return [self releasePrivateContextID:contextID];
}

- (NSDictionary *)privateQuitCDPHoldAuditForTabID:(NSString *)tabID {
  if (!_testing || !_probeRoot || !ARCProbeRootIsOwned(_probeRoot)) return nil;
  NSMutableDictionary *owner = (NSMutableDictionary *)_privateQuitProbeTabs[tabID];
  ArdiaCoreTab *tab = _tabs[tabID];
  ARCNativeWindowState *state = [self stateForTabID:tabID];
  if (!owner || !tab || owner[@"tab"] != tab || tab.closed ||
      ![owner[@"windowID"] isEqualToString:_primaryWindowID] ||
      ![state.identity isEqualToString:_primaryWindowID]) return nil;
  return @{@"holdCommandPending": owner[@"holdCommandPending"] ?: @NO,
           @"holdConfirmedPending": owner[@"holdConfirmedPending"] ?: @NO,
           @"selectedNormalTab": @([state.selectedTabID isEqualToString:tabID])};
}

- (void)preparePrivateQuitCancellationProbeTabID:(NSString *)tabID
                                      completion:(void (^)(BOOL))completion {
  ArdiaCoreTab *tab = _tabs[tabID];
  ARCNativeWindowState *state = [self stateForTabID:tabID];
  NSURLComponents *url = [NSURLComponents componentsWithString:tab.url ?: @""];
  NSString *host = url.host.lowercaseString ?: @"";
  BOOL ownedLoopback = _testing && _probeRoot && ARCProbeRootIsOwned(_probeRoot) &&
      [url.scheme.lowercaseString isEqualToString:@"http"] &&
      [@[@"127.0.0.1", @"localhost"] containsObject:host];
  BOOL valid = ownedLoopback && !_closingBrowser && _engine && tab && !tab.closed &&
      !tab.profile.offTheRecord && state && [state.identity isEqualToString:_primaryWindowID] &&
      [state.selectedTabID isEqualToString:tabID] && _privateProbeContexts.count > 0;
  if (!valid) { completion(NO); return; }
  NSString *event = [@"arcusis-private-quit-cdp-" stringByAppendingString:NSUUID.UUID.UUIDString];
  NSMutableDictionary *owner = [@{@"tab": tab, @"windowID": state.identity, @"event": event,
                                  @"holdCommandPending": @YES,
                                  @"holdConfirmedPending": @NO,
                                  @"releaseStarted": @NO} mutableCopy];
  _privateQuitProbeTabs[tabID] = owner;
  NSString *expression = [NSString stringWithFormat:
    @"(()=>{const key='%@';const holds=window.__arcusisPrivateQuitCDPHolds||(window.__arcusisPrivateQuitCDPHolds=Object.create(null));"
     "holds[key]={started:true,timedOut:false};return new Promise(resolve=>{const timer=setTimeout(()=>{holds[key].timedOut=true;resolve(true)},30000);"
     "addEventListener(key,()=>{clearTimeout(timer);delete holds[key];resolve(true)},{once:true});});})()", event];
  [tab devToolsCall:@"Runtime.evaluate"
             params:@{@"expression": expression, @"awaitPromise": @YES}
            timeout:35 completion:^(NSDictionary *holdResult, NSString *holdError) {
    NSMutableDictionary *currentOwner = (NSMutableDictionary *)self->_privateQuitProbeTabs[tabID];
    if (currentOwner == owner) currentOwner[@"holdCommandPending"] = @NO;
    if (currentOwner == owner) {
      if (holdError || self->_tabs[tabID] != tab || tab.closed)
        currentOwner[@"holdConfirmedPending"] = @NO;
      [self endPrivateQuitCDPHoldForTabID:tabID tab:tab completion:^(BOOL ended) {}];
    }
  }];
  [tab devToolsCall:@"Page.enable" params:@{} timeout:5
         completion:^(NSDictionary *result, NSString *error) {
    BOOL current = self->_privateQuitProbeTabs[tabID] == owner &&
        self->_tabs[tabID] == tab && !tab.closed;
    if (error || !current) {
      if (self->_privateQuitProbeTabs[tabID] == owner)
        [self endPrivateQuitCDPHoldForTabID:tabID tab:tab completion:^(BOOL ended) {}];
      completion(NO);
    } else {
      NSString *verify = [NSString stringWithFormat:
        @"(()=>{const holds=window.__arcusisPrivateQuitCDPHolds;return holds&&holds['%@']||null})()", event];
      [tab devToolsCall:@"Runtime.evaluate"
                 params:@{@"expression": verify, @"returnByValue": @YES}
                timeout:5 completion:^(NSDictionary *verifyResult, NSString *verifyError) {
        NSMutableDictionary *verifiedOwner = (NSMutableDictionary *)self->_privateQuitProbeTabs[tabID];
        id holdState = verifyResult[@"result"][@"value"];
        BOOL pending = !verifyError && verifiedOwner == owner &&
            self->_tabs[tabID] == tab && !tab.closed &&
            [holdState isKindOfClass:NSDictionary.class] &&
            [holdState[@"started"] boolValue] && ![holdState[@"timedOut"] boolValue] &&
            [verifiedOwner[@"holdCommandPending"] boolValue];
        verifiedOwner[@"holdConfirmedPending"] = @(pending);
        if (!pending && verifiedOwner == owner)
          [self endPrivateQuitCDPHoldForTabID:tabID tab:tab completion:^(BOOL ended) {}];
        completion(pending);
      }];
    }
  }];
}

- (void)endPrivateQuitCDPHoldForTabID:(NSString *)tabID
                                  tab:(ArdiaCoreTab *)tab
                           completion:(void (^)(BOOL))completion {
  NSDictionary *owner = _privateQuitProbeTabs[tabID];
  NSString *event = owner[@"event"];
  if (!owner || owner[@"tab"] != tab || !event || _tabs[tabID] != tab || tab.closed) {
    completion(NO);
    return;
  }
  if ([owner[@"releaseStarted"] boolValue]) { completion(NO); return; }
  ((NSMutableDictionary *)owner)[@"releaseStarted"] = @YES;
  NSString *expression = [NSString stringWithFormat:@"dispatchEvent(new Event('%@'))", event];
  [tab devToolsCall:@"Runtime.evaluate" params:@{@"expression": expression}
           timeout:5 completion:^(NSDictionary *result, NSString *error) {
    BOOL current = self->_privateQuitProbeTabs[tabID] == owner &&
        self->_tabs[tabID] == tab && !tab.closed;
    if (!current) { completion(NO); return; }
    [tab devToolsCall:@"Page.disable" params:@{} timeout:5
           completion:^(NSDictionary *ignored, NSString *disableError) {
      BOOL stillCurrent = self->_privateQuitProbeTabs[tabID] == owner &&
          self->_tabs[tabID] == tab && !tab.closed;
      if (stillCurrent) [self->_privateQuitProbeTabs removeObjectForKey:tabID];
      completion(error == nil && disableError == nil && stillCurrent);
    }];
  }];
}

- (void)cancelPrivateQuitDialogForProbeTabID:(NSString *)tabID
                                  completion:(void (^)(BOOL))completion {
  NSDictionary *owner = _privateQuitProbeTabs[tabID];
  ArdiaCoreTab *tab = owner[@"tab"];
  ARCNativeWindowState *state = [self stateForTabID:tabID];
  NSString *invalidReason = nil;
  if (!_testing || !_probeRoot || !ARCProbeRootIsOwned(_probeRoot)) invalidReason = @"probe-root";
  else if (!_closingBrowser) invalidReason = @"not-quitting";
  else if (!_engine) invalidReason = @"engine-missing";
  else if (!owner || !tab) invalidReason = @"probe-tab-missing";
  else if (_tabs[tabID] != tab || tab.closed) invalidReason = @"tab-retired";
  else if (tab.profile.offTheRecord) invalidReason = @"tab-profile-private";
  else if (!state) invalidReason = @"window-state-missing";
  else if (![state.identity isEqualToString:owner[@"windowID"]]) invalidReason = @"owner-window-mismatch";
  else if (![state.identity isEqualToString:_primaryWindowID]) invalidReason = @"not-primary-window";
  if (invalidReason) {
    for (NSMutableDictionary *context in self->_privateProbeContexts.allValues) {
      context[@"privateQuitDialogCancelResult"] =
          [@"rejected-" stringByAppendingString:invalidReason];
    }
    completion(NO);
    return;
  }
  [tab devToolsCall:@"Page.handleJavaScriptDialog"
             params:@{@"accept": @NO}
            timeout:1
         completion:^(NSDictionary *result, NSString *error) {
    BOOL current = self->_privateQuitProbeTabs[tabID][@"tab"] == tab &&
        self->_tabs[tabID] == tab && !tab.closed;
    NSString *lowerError = error.lowercaseString ?: @"";
    for (NSMutableDictionary *context in self->_privateProbeContexts.allValues) {
      context[@"privateQuitDialogCancelResult"] = !current ? @"owner-stale" : error ?
          ([lowerError containsString:@"dialog"] && [lowerError containsString:@"no"] ?
            @"no-dialog" : @"devtools-error") : @"cancelled";
    }
    if (!current) { completion(NO); return; }
    [self endPrivateQuitCDPHoldForTabID:tabID tab:tab completion:^(BOOL ended) {
      completion(error == nil && ended);
    }];
  }];
}

- (BOOL)releasePrivateContextID:(NSString *)contextID {
  NSMutableDictionary *context = _privateProbeContexts[contextID];
  BOOL confirmedQuitClose = [context[@"finalCloseConfirmedWhileQuitting"] boolValue];
  if (!_engine || (_closingBrowser && !confirmedQuitClose) || !context ||
      [context[@"windows"] count] != 0) return NO;
  ArdiaCoreProfile *profile = context[@"profile"];
  if (!profile || !profile.offTheRecord ||
      [(NSSet *)context[@"pendingWindows"] count] != 0) return NO;
  NSString *sourceProfileID = context[@"sourceProfileID"];
  ArdiaCoreProfile *source = context[@"sourceProfile"];
  if (!source || source.destroyed || source.offTheRecord || _profiles[sourceProfileID] != source) return NO;
  NSMutableDictionary *lease = _privateProbeSourceLeases[sourceProfileID];
  if (!lease || ![lease[@"contextIDs"] containsObject:contextID]) return NO;
  [_privateProbeContexts removeObjectForKey:contextID];
  [lease[@"contextIDs"] removeObject:contextID];
  if (![lease[@"contextIDs"] count] && ![lease[@"pending"] count]) {
    [_privateProbeSourceLeases removeObjectForKey:sourceProfileID];
    if (!profile.destroyed) [_engine releaseProfile:profile];
  }
  return YES;
}

- (BOOL)openTabID:(NSString *)tabID profileID:(NSString *)profileID url:(NSString *)url
           error:(NSError **)error {
  return [self openTabID:tabID profileID:profileID windowID:_primaryWindowID url:url error:error];
}
- (BOOL)navigateTabID:(NSString *)tabID profileID:(NSString *)profileID windowID:(NSString *)windowID
                  url:(NSString *)url {
  NSAssert(NSThread.isMainThread, @"Tab navigation must run on the main thread");
  if (!ValidID(tabID) || !ValidID(profileID) || !ValidID(windowID) || !url.length ||
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
    if (error) *error = BridgeError(@"Private identities cannot enter regular tab ownership.");
    return NO;
  }
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
  _documentGenerations[tabID] = @0;
  tab.delegate = self;
  [self publish:tab];
  return YES;
}

- (NSString *)identityForTab:(ArdiaCoreTab *)tab {
  if (!tab) return nil;
  return [_tabs allKeysForObject:tab].firstObject;
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
  ArdiaCoreTab *tab = _tabs[tabID];
  if (!tab || tab.closed || ![self isSelectedTabID:tabID] ||
      ![_owners[tabID] isEqualToString:profileID]) return NO;
  [self advanceDocumentGenerationForTabID:tabID];
  [self invalidateExternalRequestsForTabID:tabID windowID:nil];
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
- (NSDictionary *)probeExternalAppLaunchAuditForURL:(NSString *)url {
  if (!_externalAppProbeTesting || !_testing || !_engineClass || !_probeRoot ||
      !ARCProbeRootIsOwned(_probeRoot)) return nil;
  NSArray *launches = [_engineClass testExternalLaunches];
  return ARCProbeExternalAppLaunchAuditForTesting(url, launches, _probeRoot, YES);
}
- (void)evaluateTab:(ArdiaCoreTab *)tab script:(NSString *)script completion:(void (^)(NSString *))completion {
  [self evaluateTab:tab script:script userGesture:NO completion:completion];
}
- (void)evaluateProbeUserGestureInTabID:(NSString *)tabID script:(NSString *)script completion:(void (^)(NSString *))completion {
  if (!_testing) { completion(nil); return; }
  [self evaluateTab:_tabs[tabID] script:script userGesture:YES completion:completion];
}
- (ArdiaCoreTab *)probeVisibilityTargetForID:(NSString *)identity {
  if (!_testing || !_probeTLS) return nil;
  ArdiaCoreTab *tab = _tabs[identity];
  ARCNativeWindowState *state = [self stateForPopupID:identity];
  BOOL popup = !tab && state && !state.closed && !state.closing &&
    [state.popupExtensionID isEqualToString:@"nngceckbapebfimnlniiiahkandclblb"] &&
    state.popupOwnerTabID.length > 0 &&
    [self isSelectedTabID:state.popupOwnerTabID];
  if (popup) tab = state.popup;
  if (!tab || tab.closed || (!popup && ![self isSelectedTabID:identity])) return nil;
  NSURL *url = [NSURL URLWithString:tab.url];
  if (url.user || url.password || url.port) return nil;
  BOOL allowed = popup
    ? [url.scheme isEqualToString:@"chrome-extension"] && [url.host isEqualToString:state.popupExtensionID] &&
      tab.profile == state.native.activeProfile
    : [url.scheme isEqualToString:@"https"] && [url.host isEqualToString:@"chromewebstore.google.com"] &&
      [url.path hasPrefix:@"/detail/"];
  return allowed ? tab : nil;
}
- (void)beginProbeVisibilityControlForID:(NSString *)tabID completion:(void (^)(BOOL))completion {
  ArdiaCoreTab *tab = [self probeVisibilityTargetForID:tabID];
  if (!tab) {
    completion(NO);
    return;
  }
  if (_probeVisibilityLeases[tabID]) { completion(YES); return; }
  if (!_probeVisibilityLeases) _probeVisibilityLeases = [NSMutableDictionary dictionary];
  NSString *event = [@"arcusis-probe-visibility-" stringByAppendingString:NSUUID.UUID.UUIDString];
  _probeVisibilityLeases[tabID] = event;
  // The pinned engine detaches idle CDP clients. Keep this control's client alive
  // with a bounded, cancelable promise; no vendor DOM, routes or storage are changed.
  NSString *expression = [NSString stringWithFormat:
    @"new Promise(resolve=>{const end=()=>{clearTimeout(timer);removeEventListener('%@',end);resolve(true);};"
     "const timer=setTimeout(end,90000);addEventListener('%@',end,{once:true});})", event, event];
  __weak ARCChromiumRuntime *weakSelf = self;
  [tab devToolsCall:@"Runtime.evaluate" params:@{@"expression": expression, @"awaitPromise": @YES}
           timeout:95 completion:^(NSDictionary *result, NSString *error) {
    ARCChromiumRuntime *owner = weakSelf;
    if (owner && [owner->_probeVisibilityLeases[tabID] isEqualToString:event]) {
      [owner endProbeVisibilityControlForID:tabID];
    }
  }];
  [tab devToolsCall:@"Emulation.setFocusEmulationEnabled" params:@{@"enabled": @YES}
           timeout:5 completion:^(NSDictionary *result, NSString *error) {
    ARCChromiumRuntime *owner = weakSelf;
    BOOL current = owner && [owner probeVisibilityTargetForID:tabID] == tab &&
      [owner->_probeVisibilityLeases[tabID] isEqualToString:event];
    if (error || !current) {
      if (owner && [owner->_probeVisibilityLeases[tabID] isEqualToString:event]) {
        [owner endProbeVisibilityControlForID:tabID];
      }
      completion(NO);
    } else {
      completion(YES);
    }
  }];
}
- (void)endProbeVisibilityControlForID:(NSString *)tabID {
  if (!_testing) return;
  NSString *event = _probeVisibilityLeases[tabID];
  if (!event) return;
  [_probeVisibilityLeases removeObjectForKey:tabID];
  ArdiaCoreTab *tab = _tabs[tabID] ?: [self stateForPopupID:tabID].popup;
  if (!tab || tab.closed) return;
  [tab devToolsCall:@"Emulation.setFocusEmulationEnabled" params:@{@"enabled": @NO}
           timeout:5 completion:^(NSDictionary *result, NSString *error) {
    [tab devToolsCall:@"Runtime.evaluate"
              params:@{@"expression": [NSString stringWithFormat:@"dispatchEvent(new Event('%@'))", event]}
             timeout:5 completion:^(NSDictionary *result, NSString *error) {}];
  }];
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

static NSString *const ARCExtensionManagerID = @"bphhlegomeaogfihjcipdbcfbgkcfafp";

/// Shaar's bundled manager extension holds the management APIs. Its page opens as an extension
/// view, not a tab, so it never joins the tab strip or the session model.
- (ArdiaCoreTab *)extensionManagerForProfileID:(NSString *)profileID {
  ArdiaCoreProfile *profile = _profiles[profileID];
  ARCNativeWindowState *window = _windows[_primaryWindowID];
  if (!profile || profile.destroyed || profile.offTheRecord || !window || window.closed) return nil;
  ArdiaCoreTab *manager = _extensionManagers[profileID];
  if (manager && !manager.closed && manager.profile == profile) return manager;
  NSString *path = [NSBundle.mainBundle pathForResource:@"ExtensionManager" ofType:nil];
  NSString *identity = path ? [profile loadComponentExtension:path] : nil;
  if (![identity isEqualToString:ARCExtensionManagerID]) return nil;
  NSString *url = [NSString stringWithFormat:@"chrome-extension://%@/manager.html", identity];
  manager = [window.native openExtensionView:url profile:profile kind:@"popup"];
  if (!manager || manager.profile != profile) {
    [manager closeNow];
    return nil;
  }
  _extensionManagers[profileID] = manager;
  return manager;
}

- (void)manageExtensionsForProfileID:(NSString *)profileID expression:(NSString *)expression
                          completion:(void (^)(NSString *))completion {
  [self manageExtensionsForProfileID:profileID expression:expression attempts:50 completion:completion];
}

- (void)manageExtensionsForProfileID:(NSString *)profileID expression:(NSString *)expression
                            attempts:(int)attempts completion:(void (^)(NSString *))completion {
  ArdiaCoreTab *manager = [self extensionManagerForProfileID:profileID];
  if (!manager) { completion(nil); return; }
  if (manager.loading) {
    // A result posted before the manager page commits would be lost with the old document.
    if (attempts <= 0) { completion(nil); return; }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
      [self manageExtensionsForProfileID:profileID expression:expression attempts:attempts - 1 completion:completion];
    });
    return;
  }
  __block BOOL answered = NO;
  void (^reply)(NSString *) = ^(NSString *json) {
    if (answered) return;
    answered = YES;
    completion(json);
  };
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
    reply(nil);
  });
  // The page binds its APIs while loading, so wait for them before running the expression.
  NSString *script = [NSString stringWithFormat:
    @"(async()=>{for(let i=0;i<80&&!(window.chrome&&chrome.management);i++)"
     "await new Promise(r=>setTimeout(r,100));"
     "try{post('result',JSON.stringify(await (%@)));}catch(e){post('result',JSON.stringify({error:String(e&&e.message||e)}));}})();",
    expression];
  // Enabling and removing extensions require a user gesture; these calls come from user actions.
  [manager evaluate:script userGesture:YES completion:reply];
}

- (NSURL *)extensionsDirectoryForProfileID:(NSString *)profileID {
  ArdiaCoreProfile *profile = _profiles[profileID];
  if (!profile || profile.destroyed || profile.offTheRecord || !profile.path.length) return nil;
  return [[NSURL fileURLWithPath:profile.path isDirectory:YES] URLByAppendingPathComponent:@"Extensions" isDirectory:YES];
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
  if (identity) [self endProbeVisibilityControlForID:identity];
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

- (BOOL)ownedProbePopupID:(NSString *)popupID state:(ARCNativeWindowState **)stateOut {
  ARCNativeWindowState *state = [self stateForPopupID:popupID];
  ArdiaCoreTab *popup = state.popup;
  NSString *ownerTabID = state.popupOwnerTabID;
  ArdiaCoreTab *owner = ownerTabID ? _tabs[ownerTabID] : nil;
  NSURL *url = [NSURL URLWithString:popup.url ?: @""];
  BOOL valid = _testing && state && !state.closed && !state.closing && !_closingBrowser &&
    popup && !popup.closed && [state.popupID isEqualToString:popupID] &&
    [state.popupExtensionID isEqualToString:@"nngceckbapebfimnlniiiahkandclblb"] &&
    [url.scheme isEqualToString:@"chrome-extension"] && [url.host isEqualToString:state.popupExtensionID] &&
    !url.user && !url.password && !url.port && ownerTabID.length > 0 && owner && !owner.closed &&
    [self stateForTabID:ownerTabID] == state && [self isSelectedTabID:ownerTabID] &&
    popup.profile == owner.profile && popup.profile == state.native.activeProfile;
  if (valid && stateOut) *stateOut = state;
  return valid;
}

- (void)captureProbeTabID:(NSString *)tabID completion:(void (^)(NSData *))completion {
  [self captureProbeTab:_tabs[tabID] completion:completion];
}
- (void)clickProbePopupID:(NSString *)popupID buttonTitle:(NSString *)title completion:(void (^)(BOOL))completion {
  ARCNativeWindowState *state = nil;
  if (![self ownedProbePopupID:popupID state:&state] || ![title isKindOfClass:NSString.class] ||
      title.length == 0 || title.length > 256) {
    completion(NO); return;
  }
  NSData *encoded = [NSJSONSerialization dataWithJSONObject:title options:NSJSONWritingFragmentsAllowed error:nil];
  NSString *literal = encoded ? [[NSString alloc] initWithData:encoded encoding:NSUTF8StringEncoding] : nil;
  if (!literal) { completion(NO); return; }
  NSString *expression = ProbeButtonExpression(literal, NO);
  ArdiaCoreTab *popup = state.popup;
  ClickProbeTarget(popup, expression, ^BOOL {
    return [self ownedProbePopupID:popupID state:nil] && state.popup == popup;
  }, completion);
}
- (void)diagnoseProbePopupID:(NSString *)popupID buttonTitle:(NSString *)title
                  completion:(void (^)(NSDictionary *))completion {
  ARCNativeWindowState *state = nil;
  if (![self ownedProbePopupID:popupID state:&state] || ![title isKindOfClass:NSString.class] ||
      title.length == 0 || title.length > 256) {
    completion(ProbeButtonDiagnostic(nil, @"invalid_context")); return;
  }
  NSData *encoded = [NSJSONSerialization dataWithJSONObject:title options:NSJSONWritingFragmentsAllowed error:nil];
  NSString *literal = encoded ? [[NSString alloc] initWithData:encoded encoding:NSUTF8StringEncoding] : nil;
  if (!literal) { completion(ProbeButtonDiagnostic(nil, @"invalid_context")); return; }
  ArdiaCoreTab *popup = state.popup;
  [popup devToolsCall:@"Runtime.evaluate" params:@{
    @"expression": ProbeButtonExpression(literal, YES), @"returnByValue": @YES,
  } timeout:5 completion:^(NSDictionary *response, NSString *error) {
    if (error || ![self ownedProbePopupID:popupID state:nil] || state.popup != popup) {
      completion(ProbeButtonDiagnostic(nil, @"invalid_context")); return;
    }
    completion(ProbeButtonDiagnostic(response[@"result"][@"value"], nil));
  }];
}
- (void)clickProbePopupID:(NSString *)popupID elementTestID:(NSString *)elementTestID
               completion:(void (^)(BOOL))completion {
  ARCNativeWindowState *state = [self stateForPopupID:popupID];
  NSString *ownerTabID = state ? state.popupOwnerTabID : nil;
  ArdiaCoreTab *owner = ownerTabID ? _tabs[ownerTabID] : nil;
  ArdiaCoreTab *popup = state.popup;
  NSURL *popupURL = [NSURL URLWithString:popup.url ?: @""];
  BOOL validPopup = _testing && state && !state.closed && !state.closing && !_closingBrowser &&
    popup && !popup.closed && [state.popupID isEqualToString:popupID] &&
    [state.popupExtensionID isEqualToString:@"nngceckbapebfimnlniiiahkandclblb"] &&
    [popupURL.scheme isEqualToString:@"chrome-extension"] &&
    [popupURL.host isEqualToString:state.popupExtensionID] && !popupURL.user && !popupURL.password && !popupURL.port &&
    ownerTabID.length > 0 && owner && !owner.closed && [self stateForTabID:ownerTabID] == state &&
    [self isSelectedTabID:ownerTabID] && popup.profile == owner.profile &&
    popup.profile == state.native.activeProfile && elementTestID.length > 0 && elementTestID.length <= 128;
  if (!validPopup) {
    completion(NO);
    return;
  }
  NSData *encoded = [NSJSONSerialization dataWithJSONObject:elementTestID
                                                   options:NSJSONWritingFragmentsAllowed error:nil];
  NSString *literal = encoded ? [[NSString alloc] initWithData:encoded encoding:NSUTF8StringEncoding] : nil;
  if (!literal) { completion(NO); return; }
  NSString *expression = [NSString stringWithFormat:
    @"(()=>{const id=%@;const matches=[...document.querySelectorAll('[data-testid]')].filter(e=>e.getAttribute('data-testid')===id);"
     "if(matches.length!==1)return null;const button=matches[0];if(button.tagName!=='BUTTON'||button.disabled||"
     "button.getAttribute('aria-disabled')?.toLowerCase()==='true')return null;"
     "for(let n=button;n&&n.nodeType===1;n=n.parentElement){if(n.hidden||n.inert||n.getAttribute('aria-hidden')?.toLowerCase()==='true')return null;"
     "const s=getComputedStyle(n);if(s.display==='none'||s.visibility==='hidden'||s.visibility==='collapse'||s.opacity==='0')return null;}"
     "const r=button.getBoundingClientRect(),x=r.x+r.width/2,y=r.y+r.height/2;"
     "if(r.width<=0||r.height<=0||x<0||y<0||x>=innerWidth||y>=innerHeight)return null;return {x,y};})()", literal];
  ClickProbeTarget(popup, expression, ^BOOL {
    NSURL *currentPopupURL = [NSURL URLWithString:popup.url ?: @""];
    return !self->_closingBrowser && !state.closed && !state.closing && !popup.closed &&
      state.popup == popup && [state.popupID isEqualToString:popupID] &&
      [state.popupOwnerTabID isEqualToString:ownerTabID] &&
      [state.popupExtensionID isEqualToString:@"nngceckbapebfimnlniiiahkandclblb"] &&
      [currentPopupURL.scheme isEqualToString:@"chrome-extension"] &&
      [currentPopupURL.host isEqualToString:state.popupExtensionID] &&
      !currentPopupURL.user && !currentPopupURL.password && !currentPopupURL.port &&
      self->_tabs[ownerTabID] == owner && [self stateForTabID:ownerTabID] == state &&
      [self isSelectedTabID:ownerTabID] && popup.profile == owner.profile &&
      popup.profile == state.native.activeProfile;
  }, completion);
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
                       @"commandTimedOut": @([loadError isEqualToString:@"timed out"]),
                       @"attachmentRejected": @([loadError isEqualToString:@"can't attach to the tab"]),
                       @"targetClosed": @([loadError isEqualToString:@"the tab is gone"] ||
                                           [loadError isEqualToString:@"the tab's DevTools target closed"]),
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
  [self captureProbeTab:tab diagnosticCompletion:^(NSData *data, NSString *error) {
    completion(data);
  }];
}
- (void)captureProbeTab:(ArdiaCoreTab *)tab diagnosticCompletion:(void (^)(NSData *, NSString *))completion {
  if (!_testing || !tab || tab.closed) { completion(nil, @"probe-tab-unavailable"); return; }
  [tab devToolsCall:@"Page.captureScreenshot"
             params:@{@"format": @"png", @"captureBeyondViewport": @YES}
            timeout:5
         completion:^(NSDictionary *result, NSString *error) {
    NSString *base64 = result[@"data"];
    NSData *data = [base64 isKindOfClass:NSString.class]
        ? [[NSData alloc] initWithBase64EncodedString:base64 options:0] : nil;
    completion(data, error ?: (data ? nil : @"screenshot-data-missing-or-invalid-base64"));
  }];
}
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
    if (_onNotice) _onNotice(@"The extension stopped working. Open it again to retry.");
    return;
  }
  NSString *identity = [self identityForTab:tab];
  NSString *profile = identity ? _owners[identity] : nil;
  if (!identity || !profile || tab.closed) return;
  [self invalidateExternalRequestsForTabID:identity windowID:nil];
  [self stopFindingInTabID:identity];
  if (_onRendererGone) _onRendererGone(identity, profile, status, code);
}
- (void)tabDidCommitDocument:(ArdiaCoreTab *)tab {
  NSString *identity = [self identityForTab:tab];
  NSString *profile = identity ? _owners[identity] : nil;
  if (identity) {
    [self advanceDocumentGenerationForTabID:identity];
    [self invalidateExternalRequestsForTabID:identity windowID:nil];
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
