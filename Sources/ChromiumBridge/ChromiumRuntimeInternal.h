// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Shared by the runtime's implementation files; not part of the module's public interface.

#import "include/ChromiumBridgeVerification.h"
#import "ChromiumDownloads.h"
#import "ChromiumLibrary.h"
#import "ChromiumMediaSession.h"
#import "ChromiumWebStoreFit.h"
#import "../../ThirdParty/ArdiaCore/ArdiaCore.h"

NSError *ARCBridgeError(NSString *message);
BOOL ARCIsCanonicalID(NSString *value);
/// The canonical uppercase form of a profile UUID, or nil when `profileID` is not a UUID.
NSString *ARCValidatedProfileID(NSString *profileID);

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

@interface ARCChromiumRuntime () <ArdiaCoreEngineDelegate, ArdiaCoreWindowDelegate,
                                ArdiaCoreTabDelegate> {
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
  NSURL *_probeRoot;
  NSMutableDictionary<NSString *, NSDictionary *> *_pendingInstalls;
  NSMutableDictionary<NSString *, NSDictionary *> *_pendingMedia;
  NSMutableDictionary<NSString *, NSDictionary *> *_pendingExternal;
  NSMutableDictionary<NSString *, NSNumber *> *_documentGenerations;
  NSMutableDictionary<NSString *, NSMutableArray<NSDictionary *> *> *_probeExtensions;
  NSMutableArray<NSDictionary *> *_probeDiagnostics;
  NSMutableSet<NSString *> *_pendingHostClosures;
  NSMutableDictionary<NSString *, NSMutableDictionary<NSString *, id> *> *_detachedTabSelections;
  BOOL _closingBrowser;
  ARCDownloadService *_downloadService;
  ARCEngineServices *_services;
  ARCLibraryService *_libraryService;
  ARCWebStoreFit *_webStoreFit;
  ARCMediaSessionTracker *_mediaSessions;
}
- (void)closedWindowID:(NSString *)identity;
- (ARCNativeWindowState *)stateForTabID:(NSString *)identity;
- (ARCNativeWindowState *)stateForPopupID:(NSString *)identity;
- (BOOL)isSelectedTabID:(NSString *)identity;
- (void)publish:(ArdiaCoreTab *)tab;
- (NSString *)identityForTab:(ArdiaCoreTab *)tab;
/// An open tab this runtime owns in an open window, or nil.
- (ArdiaCoreTab *)liveTabForID:(NSString *)tabID;
- (void)evaluateTab:(ArdiaCoreTab *)tab script:(NSString *)script completion:(void (^)(NSString *))completion;
- (void)evaluateTab:(ArdiaCoreTab *)tab script:(NSString *)script userGesture:(BOOL)userGesture
         completion:(void (^)(NSString *))completion;
@end

@interface ARCChromiumRuntime (PrivateBrowsingSupport)
- (BOOL)privateIdentityOccupied:(NSString *)identity;
- (BOOL)isPrivateIdentity:(NSString *)identity;
- (BOOL)privateURLIsAllowed:(NSString *)url;
- (BOOL)privateWindowContextOwned:(NSString *)contextID windowID:(NSString *)windowID;
- (BOOL)privateContextEnabled;
- (BOOL)privateOwnerForTabID:(NSString *)tabID windowID:(NSString *)windowID contextID:(NSString *)contextID
                         tab:(ArdiaCoreTab **)tabOut window:(ArdiaCoreWindow **)windowOut;
- (NSDictionary *)privateEntryForTab:(ArdiaCoreTab *)tab identity:(NSString **)identityOut;
@end

@interface ARCChromiumRuntime (MediaSessionSupport)
- (void)receiveMediaSessionJSON:(NSString *)json frameID:(NSString *)frameID tab:(ArdiaCoreTab *)tab;
- (void)publishMediaSessionForTabID:(NSString *)tabID;
/// Drops the tab's frame reports, after a new document or a renderer exit.
- (void)resetMediaSessionForTabID:(NSString *)tabID notify:(BOOL)notify;
@end

@interface ARCChromiumRuntime (ExtensionSupport)
- (BOOL)showPopupForExtension:(NSString *)extensionID tabID:(NSString *)tabID error:(NSError **)error;
@end

@interface ARCChromiumRuntime (VerificationSupport)
- (BOOL)ownedProbePopupID:(NSString *)popupID state:(ARCNativeWindowState **)stateOut;
@end
