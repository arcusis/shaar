#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Exact modifier matching keeps extension shortcuts such as Command-Shift-L available.
FOUNDATION_EXPORT BOOL ARCReservedBrowserShortcut(NSString *key, NSEventModifierFlags modifiers);
/// Zoom that fits a page needing `requiredWidth` CSS pixels into `viewportWidth` points, clamped to 67%.
FOUNDATION_EXPORT double ARCWebStoreFitZoom(double viewportWidth, double requiredWidth);

/// Fixed extension-management operations; the bridge builds each script from a constant template.
typedef NS_ENUM(NSInteger, ARCExtensionManagementOperation) {
  ARCExtensionManagementOperationList,
  ARCExtensionManagementOperationSetEnabled,
  ARCExtensionManagementOperationUninstall,
  ARCExtensionManagementOperationDetails,
};

/// All methods and callbacks run on the main thread. The engine owns the AppKit run loop.
@interface ARCChromiumRuntime : NSObject
@property(copy, nullable) void (^onReady)(void);
@property(copy, nullable) void (NS_SWIFT_UI_ACTOR ^onWindowClosed)(NSString *windowID, BOOL quitting);
/// Synchronous: return a newly created window before Chromium attaches its browser.
@property(copy, nullable) NSString * _Nullable (NS_SWIFT_UI_ACTOR ^onWindowRequest)(NSString *profileID, NSString *type);
@property(copy, nullable) void (NS_SWIFT_UI_ACTOR ^onWindowShowRequest)(NSString *windowID, BOOL active);
@property(copy, nullable) void (^onNotice)(NSString *message);
@property(copy, nullable) void (^onInstallRequest)(NSDictionary<NSString *, id> *request);
@property(copy, nullable) void (^onExtensionPopup)(NSDictionary<NSString *, id> *popup);
@property(copy, nullable) void (^onExtensionPopupClosed)(NSString *popupID);
@property(copy, nullable) void (^onExtensionPopupSize)(NSString *popupID, NSSize size);
@property(copy, nullable) void (^onWebsiteMediaRequest)(NSDictionary<NSString *, id> *request);
@property(copy, nullable) void (^onWebsiteMediaDismissed)(NSString *requestID);
@property(copy, nullable) void (^onExternalAppRequest)(NSDictionary<NSString *, id> *request);
@property(copy, nullable) void (^onExternalAppDismissed)(NSString *requestID);
@property(copy, nullable) void (^onMediaAccess)(NSString *tabID, NSDictionary<NSString *, NSNumber *> *access);
@property(copy, nullable) void (^onFindResult)(NSString *tabID, NSString *requestID, int count, int active, BOOL final);
@property(copy, nullable) void (^onDownloadChanged)(NSString *profileID, NSDictionary<NSString *, id> *download);
@property(copy, nullable) void (^onDownloadRemoved)(NSString *profileID, NSString *downloadID);
@property(copy, nullable) void (^onDownloadsRestored)(NSString *profileID, NSArray<NSDictionary<NSString *, id> *> *downloads);
@property(copy, nullable) void (NS_SWIFT_UI_ACTOR ^onLibraryChanged)(NSString *profileID, NSString *section);
@property(copy, nullable) void (NS_SWIFT_UI_ACTOR ^onLibraryError)(NSString *profileID, NSString *section, NSString *message);
- (void)bookmarksForProfileID:(NSString *)profileID completion:(void (NS_SWIFT_UI_ACTOR ^)(NSDictionary * _Nullable, NSError * _Nullable))completion NS_SWIFT_UI_ACTOR;
- (void)applyBookmarkOperation:(NSDictionary *)operation profileID:(NSString *)profileID completion:(void (NS_SWIFT_UI_ACTOR ^)(NSError * _Nullable))completion NS_SWIFT_UI_ACTOR;
- (void)historyForProfileID:(NSString *)profileID limit:(NSInteger)limit completion:(void (NS_SWIFT_UI_ACTOR ^)(NSArray<NSDictionary *> * _Nullable, NSError * _Nullable))completion NS_SWIFT_UI_ACTOR;
- (void)deleteHistoryURL:(NSString *)url profileID:(NSString *)profileID completion:(void (NS_SWIFT_UI_ACTOR ^)(NSError * _Nullable))completion NS_SWIFT_UI_ACTOR;
@property(copy, nullable) void (^onTabChanged)(NSString *tabID, NSString *url, NSString *title,
                                             BOOL loading, BOOL canGoBack, BOOL canGoForward);
@property(copy, nullable) void (^onTabClosed)(NSString *tabID);
@property(copy, nullable) void (NS_SWIFT_UI_ACTOR ^onTabActivated)(NSString *tabID, NSString *profileID);
@property(copy, nullable) void (NS_SWIFT_UI_ACTOR ^onPrivateTabChanged)(NSString *contextID, NSString *windowID,
    NSString *tabID, NSString *url, NSString *title, BOOL loading, BOOL canGoBack, BOOL canGoForward);
@property(copy, nullable) void (NS_SWIFT_UI_ACTOR ^onPrivateTabSelected)(NSString *contextID, NSString *windowID,
    NSString *tabID);
@property(copy, nullable) void (NS_SWIFT_UI_ACTOR ^onPrivateTabClosed)(NSString *contextID, NSString *windowID,
    NSString *tabID);
@property(copy, nullable) void (NS_SWIFT_UI_ACTOR ^onPrivateWindowClosed)(NSString *contextID, NSString *windowID);
@property(copy, nullable) void (NS_SWIFT_UI_ACTOR ^onRendererGone)(NSString *tabID, NSString *profileID, NSString *status, int exitCode);
@property(copy, nullable) void (NS_SWIFT_UI_ACTOR ^onDocumentCommitted)(NSString *tabID, NSString *profileID);
@property(copy, nullable) void (^onNewTab)(NSString *tabID, NSString *profileID, NSString *url,
                                         NSString * _Nullable openerID, BOOL foreground);
@property(readonly, nullable) NSWindow *window;
@property(readonly, nullable) NSView *hostView;
@property(readonly) NSString *chromiumVersion;
@property(readonly) NSString *primaryWindowID;
@property(readonly, getter=isQuitting) BOOL quitting;
/// Windowless compatibility methods target the primary window. Live tabs cannot be implicitly reassigned.
- (BOOL)createWindowID:(NSString *)windowID error:(NSError **)error;
- (BOOL)closeWindowID:(NSString *)windowID;
- (nullable NSWindow *)windowForID:(NSString *)windowID;
- (nullable NSView *)hostViewForWindowID:(NSString *)windowID;
- (nullable NSString *)windowIDForTabID:(NSString *)tabID;
- (nullable NSImage *)faviconForTabID:(NSString *)tabID profileID:(NSString *)profileID windowID:(NSString *)windowID;
- (int)chromeWindowIDForProfileID:(NSString *)profileID windowID:(NSString *)windowID;
- (void)clearActiveTabInWindowID:(NSString *)windowID;
- (void)activateProfileID:(NSString *)profileID windowID:(NSString *)windowID;
- (BOOL)openTabID:(NSString *)tabID profileID:(NSString *)profileID windowID:(NSString *)windowID url:(NSString *)url error:(NSError **)error;
- (BOOL)navigateTabID:(NSString *)tabID profileID:(NSString *)profileID windowID:(NSString *)windowID url:(NSString *)url
  NS_SWIFT_NAME(navigateTabID(_:profileID:windowID:url:));
- (BOOL)placeTabIDs:(NSArray<NSString *> *)tabIDs pinnedIDs:(NSArray<NSString *> *)pinnedIDs profileID:(NSString *)profileID windowID:(NSString *)windowID;
- (void)closeExtensionPopupForWindowID:(NSString *)windowID;

- (nullable instancetype)initWithFrameworkURL:(NSURL *)url error:(NSError **)error;
- (int)runWithDataDirectory:(NSURL *)directory testing:(BOOL)testing;
- (void)loadProfileID:(NSString *)profileID completion:(void (^)(NSError * _Nullable))completion;
- (BOOL)openTabID:(NSString *)tabID profileID:(NSString *)profileID url:(NSString *)url
           error:(NSError **)error;
- (nullable NSView *)viewForTabID:(NSString *)tabID;
- (void)activateTabID:(NSString *)tabID;
- (void)focusTabID:(NSString *)tabID;
- (void)activateProfileID:(NSString *)profileID;
- (void)clearActiveTab;
- (void)closeTabID:(NSString *)tabID;
- (void)discardTabID:(NSString *)tabID;
- (void)goBackInTabID:(NSString *)tabID;
- (void)goForwardInTabID:(NSString *)tabID;
- (void)reloadTabID:(NSString *)tabID;
- (BOOL)reloadTabID:(NSString *)tabID profileID:(NSString *)profileID;
- (BOOL)findInTabID:(NSString *)tabID profileID:(NSString *)profileID requestID:(NSString *)requestID
              text:(NSString *)text forward:(BOOL)forward;
- (void)stopFindingInTabID:(NSString *)tabID;
- (void)downloadCommand:(NSString *)command downloadID:(NSString *)downloadID profileID:(NSString *)profileID
            completion:(void (^)(NSError * _Nullable))completion;
- (void)refreshDownloadsForProfileID:(NSString *)profileID;
- (BOOL)placeTabIDs:(NSArray<NSString *> *)tabIDs pinnedIDs:(NSArray<NSString *> *)pinnedIDs
         profileID:(NSString *)profileID;
/// Product private browsing API. Contexts bind to an already-loaded regular Profile.
- (void)createPrivateContextID:(NSString *)contextID sourceProfileID:(NSString *)sourceProfileID
                    completion:(void (NS_SWIFT_UI_ACTOR ^)(BOOL, NSError * _Nullable))completion NS_SWIFT_UI_ACTOR;
- (BOOL)createPrivateWindowID:(NSString *)windowID contextID:(NSString *)contextID tabID:(NSString *)tabID
                          url:(NSString *)url error:(NSError **)error;
- (BOOL)openPrivateTabID:(NSString *)tabID windowID:(NSString *)windowID contextID:(NSString *)contextID
                     url:(NSString *)url error:(NSError **)error;
- (BOOL)selectPrivateTabID:(NSString *)tabID windowID:(NSString *)windowID contextID:(NSString *)contextID;
- (BOOL)focusPrivateTabID:(NSString *)tabID windowID:(NSString *)windowID contextID:(NSString *)contextID;
- (void)closePrivateTabID:(NSString *)tabID windowID:(NSString *)windowID contextID:(NSString *)contextID
               completion:(void (NS_SWIFT_UI_ACTOR ^)(BOOL))completion NS_SWIFT_UI_ACTOR;
- (BOOL)navigatePrivateTabID:(NSString *)tabID windowID:(NSString *)windowID contextID:(NSString *)contextID url:(NSString *)url;
- (BOOL)reloadPrivateTabID:(NSString *)tabID windowID:(NSString *)windowID contextID:(NSString *)contextID;
- (BOOL)goBackPrivateTabID:(NSString *)tabID windowID:(NSString *)windowID contextID:(NSString *)contextID;
- (BOOL)goForwardPrivateTabID:(NSString *)tabID windowID:(NSString *)windowID contextID:(NSString *)contextID;
- (nullable NSWindow *)windowForPrivateWindowID:(NSString *)windowID contextID:(NSString *)contextID;
- (nullable NSView *)hostViewForPrivateWindowID:(NSString *)windowID contextID:(NSString *)contextID;
- (nullable NSView *)viewForPrivateTabID:(NSString *)tabID windowID:(NSString *)windowID contextID:(NSString *)contextID;
- (void)closePrivateWindowID:(NSString *)windowID contextID:(NSString *)contextID
                  completion:(void (NS_SWIFT_UI_ACTOR ^)(BOOL))completion NS_SWIFT_UI_ACTOR;
- (BOOL)releasePrivateContextID:(NSString *)contextID;
/// Evaluates a constant JavaScript script and returns its JSON value through ArdiaCore's post callback.
/// Callers must serialize all dynamic values as JSON literals before constructing the script.
- (void)evaluateInTabID:(NSString *)tabID script:(NSString *)script
            completion:(void (^)(NSString * _Nullable))completion;
- (NSArray<NSDictionary<NSString *, id> *> *)extensionsForProfileID:(NSString *)profileID;
- (void)resolveInstallRequestID:(NSString *)requestID accepted:(BOOL)accepted;
- (void)resolveWebsiteMediaRequestID:(NSString *)requestID accepted:(BOOL)accepted;
- (void)resolveExternalAppRequestID:(NSString *)requestID accepted:(BOOL)accepted;
- (BOOL)executeExtensionID:(NSString *)extensionID tabID:(NSString *)tabID error:(NSError **)error;
/// Runs one fixed extension-management operation against a validated extension ID and profile.
- (void)manageExtensionsForProfileID:(NSString *)profileID
                           operation:(ARCExtensionManagementOperation)operation
                         extensionID:(nullable NSString *)extensionID
                             enabled:(BOOL)enabled
                          completion:(void (^)(NSString * _Nullable json))completion;
/// Canonical browser-managed download directory for a regular profile.
- (nullable NSURL *)downloadsDirectoryForProfileID:(NSString *)profileID;
/// The profile's installed-extensions folder, for reading extension manifests and icons.
- (nullable NSURL *)extensionsDirectoryForProfileID:(NSString *)profileID;
- (nullable NSView *)viewForExtensionPopupID:(NSString *)popupID;
- (void)closeExtensionPopup;
- (int)nativeTabIDForID:(NSString *)tabID;
- (void)quit;
@end

NS_ASSUME_NONNULL_END
