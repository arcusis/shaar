// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

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

/// Media Session actions sent to the frame that reports a tab's playback.
typedef NS_ENUM(NSInteger, ARCMediaSessionAction) {
  ARCMediaSessionActionPlay,
  ARCMediaSessionActionPause,
  ARCMediaSessionActionPreviousTrack,
  ARCMediaSessionActionNextTrack,
  ARCMediaSessionActionSeekBackward,
  ARCMediaSessionActionSeekForward,
  ARCMediaSessionActionSeekTo,
};

/// Commands for the video in Chromium's picture-in-picture window.
typedef NS_ENUM(NSInteger, ARCPictureInPictureCommand) {
  ARCPictureInPictureCommandPlay,
  ARCPictureInPictureCommandPause,
  /// Seeks by `seconds`, negative to go back; ignored for live video.
  ARCPictureInPictureCommandSkip,
};

/// How the selected page reloads.
typedef NS_ENUM(NSInteger, ARCPageReloadMode) {
  ARCPageReloadModeNormal,
  /// Revalidates every resource with its server instead of using cached copies.
  ARCPageReloadModeBypassingCache,
  /// Releases the page's renderer process, then loads the page again in a new one.
  ARCPageReloadModeNewRenderer,
};

/// Installs the package localization bundle before engine startup. English literals remain fallback.
FOUNDATION_EXPORT void ARCConfigureLocalization(NSURL *bundleURL, NSString *languageIdentifier);
FOUNDATION_EXPORT NSString *ARCBridgeLocalizedString(NSString *message);

/// All methods and callbacks run on the main thread. The engine owns the AppKit run loop.
@interface ARCChromiumRuntime : NSObject
/// Set before `runWithDataDirectory:testing:`; configures Chromium UI locale and Accept-Language.
@property(nonatomic, copy) NSString *languageIdentifier;
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
/// A tab's validated Media Session state changed; `state` is nil when the tab has no media.
@property(copy, nullable) void (NS_SWIFT_UI_ACTOR ^onMediaSessionChanged)(NSString *tabID,
    NSDictionary<NSString *, id> * _Nullable state);
/// Chromium's picture-in-picture window opened or closed for a tab's page.
@property(copy, nullable) void (NS_SWIFT_UI_ACTOR ^onPictureInPictureChanged)(NSString *tabID, BOOL active);
/// The engine asks to show a tab, for example from the picture-in-picture window's Back to Tab
/// button (`reason` is "pictureInPicture") or a page focusing itself ("page" or "window").
@property(copy, nullable) void (NS_SWIFT_UI_ACTOR ^onTabActivationRequest)(NSString *tabID, NSString *reason);
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
- (BOOL)reloadTabID:(NSString *)tabID profileID:(NSString *)profileID mode:(ARCPageReloadMode)mode;
- (BOOL)findInTabID:(NSString *)tabID profileID:(NSString *)profileID requestID:(NSString *)requestID
              text:(NSString *)text forward:(BOOL)forward;
- (void)stopFindingInTabID:(NSString *)tabID;
- (void)downloadCommand:(NSString *)command downloadID:(NSString *)downloadID profileID:(NSString *)profileID
            completion:(void (^)(NSError * _Nullable))completion;
- (void)refreshDownloadsForProfileID:(NSString *)profileID;
- (BOOL)placeTabIDs:(NSArray<NSString *> *)tabIDs pinnedIDs:(NSArray<NSString *> *)pinnedIDs
         profileID:(NSString *)profileID;
/// Evaluates a constant JavaScript script and returns its JSON value through ArdiaCore's post callback.
/// Callers must serialize all dynamic values as JSON literals before constructing the script.
- (void)evaluateInTabID:(NSString *)tabID script:(NSString *)script
            completion:(void (^)(NSString * _Nullable))completion;
- (void)resolveInstallRequestID:(NSString *)requestID accepted:(BOOL)accepted;
- (void)resolveWebsiteMediaRequestID:(NSString *)requestID accepted:(BOOL)accepted;
- (void)resolveExternalAppRequestID:(NSString *)requestID accepted:(BOOL)accepted;
/// Canonical browser-managed download directory for a regular profile.
- (nullable NSURL *)downloadsDirectoryForProfileID:(NSString *)profileID;
- (int)nativeTabIDForID:(NSString *)tabID;
- (void)quit;
@end

@interface ARCChromiumRuntime (Extensions)
- (NSArray<NSDictionary<NSString *, id> *> *)extensionsForProfileID:(NSString *)profileID;
/// The current action title for an extension in the selected tab's owning profile.
- (nullable NSString *)extensionActionTitleForID:(NSString *)extensionID tabID:(NSString *)tabID;
- (BOOL)executeExtensionID:(NSString *)extensionID tabID:(NSString *)tabID error:(NSError **)error;
/// Runs one fixed extension-management operation against a validated extension ID and profile.
- (void)manageExtensionsForProfileID:(NSString *)profileID
                           operation:(ARCExtensionManagementOperation)operation
                         extensionID:(nullable NSString *)extensionID
                             enabled:(BOOL)enabled
                          completion:(void (^)(NSString * _Nullable json))completion;
/// The profile's installed-extensions folder, for reading extension manifests and icons.
- (nullable NSURL *)extensionsDirectoryForProfileID:(NSString *)profileID;
- (nullable NSView *)viewForExtensionPopupID:(NSString *)popupID;
- (void)closeExtensionPopup;
- (void)closeExtensionPopupForWindowID:(NSString *)windowID;
@end

/// Chromium's own inspector, hosted alongside its inspected page inside the page card.
@interface ARCChromiumRuntime (DevTools)
- (BOOL)showDevToolsForTabID:(NSString *)tabID;
- (BOOL)closeDevToolsForTabID:(NSString *)tabID;
- (nullable NSView *)devToolsViewForTabID:(NSString *)tabID;
@end

/// Media Session state reported by a tab's pages, and actions sent back to them.
@interface ARCChromiumRuntime (MediaSession)
/// Keys: playbackState (none, paused, playing), title, artist, album, artwork (http or https URL
/// or empty), actions (supported Media Session action names), hasVideo, canSeek and muted (the
/// tab's native audio mute), and volume (0...1, or null without a media element).
- (nullable NSDictionary<NSString *, id> *)mediaSessionStateForTabID:(NSString *)tabID;
/// `seconds` is the offset for seeking backward or forward and the position for seeking to.
/// Returns NO when the tab has no media state or does not support the action.
- (BOOL)sendMediaSessionAction:(ARCMediaSessionAction)action seconds:(double)seconds
                         tabID:(NSString *)tabID
  NS_SWIFT_NAME(sendMediaSessionAction(_:seconds:tabID:));
/// Mutes the tab's audio output in the engine, independently of the page's own volume.
- (BOOL)setMuted:(BOOL)muted tabID:(NSString *)tabID;
/// Sets the reporting frame's active media volume in [0, 1]. Positive volume also unmutes.
/// Returns NO for invalid values or when the tab has no controllable media element.
- (BOOL)setMediaVolume:(double)volume tabID:(NSString *)tabID;
@end

/// Chromium's built-in video picture-in-picture, driven for automatic picture-in-picture and
/// Shaar's own window controls.
@interface ARCChromiumRuntime (PictureInPicture)
/// Asks the page to open Chromium's picture-in-picture window for its largest playing video.
/// `requested` is NO when the page has no playing video that allows picture-in-picture; the
/// window itself is confirmed by `onPictureInPictureChanged`.
- (void)enterPictureInPictureInTabID:(NSString *)tabID completion:(void (^)(BOOL requested))completion;
- (void)exitPictureInPictureInTabID:(NSString *)tabID;
/// YES when Chromium's own automatic picture-in-picture will open a window as the tab hides:
/// the page registered `enterpictureinpicture` and the content setting allows it.
- (BOOL)engineHandlesAutoPictureInPictureForTabID:(NSString *)tabID;
/// Allows or withholds the page's `enterpictureinpicture` handler from Chromium, which keeps
/// Chromium's automatic picture-in-picture off for a site the user turned it off for.
- (void)setAutoPictureInPictureAllowed:(BOOL)allowed tabID:(NSString *)tabID;
/// Chromium's video picture-in-picture window while it shows this tab's video, once shown.
/// Chromium shows one such window at a time.
- (nullable NSWindow *)pictureInPictureVideoWindowForTabID:(NSString *)tabID;
/// Sends a command to the frame whose video is in picture-in-picture. Returns NO for a tab
/// without a video in picture-in-picture.
- (BOOL)sendPictureInPictureCommand:(ARCPictureInPictureCommand)command seconds:(double)seconds
                              tabID:(NSString *)tabID
  NS_SWIFT_NAME(sendPictureInPictureCommand(_:seconds:tabID:));
@end

/// Site controls for the selected tab of a regular profile. Origins are http(s) origins; settings
/// and site data are Chromium's own per-profile content settings and storage.
@interface ARCChromiumRuntime (SiteControls)
/// Chromium's security summary for the selected tab: `level`, `origin` and, for HTTPS pages, a
/// `certificate` summary with the leaf's `sha256` fingerprint.
- (nullable NSDictionary<NSString *, id> *)securityInfoForTabID:(NSString *)tabID profileID:(NSString *)profileID;
/// Each content setting keyed by its engine name, with `value` (allow, block or ask) and `isDefault`.
- (void)siteSettingsForOrigin:(NSString *)origin profileID:(NSString *)profileID
                   completion:(void (NS_SWIFT_UI_ACTOR ^)(NSDictionary<NSString *, NSDictionary *> * _Nullable,
                                                          NSError * _Nullable))completion NS_SWIFT_UI_ACTOR;
/// `value` is allow, block, ask or default; default removes the site's exception.
- (void)setSiteSetting:(NSString *)type value:(NSString *)value origin:(NSString *)origin
             profileID:(NSString *)profileID
            completion:(void (NS_SWIFT_UI_ACTOR ^)(NSError * _Nullable))completion NS_SWIFT_UI_ACTOR;
/// Deletes cookies and stored data for the origin's whole site in this profile.
- (void)clearSiteDataForOrigin:(NSString *)origin profileID:(NSString *)profileID
                    completion:(void (NS_SWIFT_UI_ACTOR ^)(NSError * _Nullable))completion NS_SWIFT_UI_ACTOR;
/// Empties this profile's HTTP cache, as Chromium's Empty Cache and Hard Reload does.
- (void)clearCacheForProfileID:(NSString *)profileID
                    completion:(void (NS_SWIFT_UI_ACTOR ^)(NSError * _Nullable))completion NS_SWIFT_UI_ACTOR;
/// Deletes every cookie the selected tab's page would send, including partitioned ones.
- (void)clearCookiesForTabID:(NSString *)tabID profileID:(NSString *)profileID
                  completion:(void (NS_SWIFT_UI_ACTOR ^)(NSError * _Nullable))completion NS_SWIFT_UI_ACTOR;
@end

/// Product private browsing API. Contexts bind to an already-loaded regular Profile.
@interface ARCChromiumRuntime (PrivateBrowsing)
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
@end

NS_ASSUME_NONNULL_END
