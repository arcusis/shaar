#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Exact modifier matching keeps extension shortcuts such as Command-Shift-L available.
FOUNDATION_EXPORT BOOL ARCReservedBrowserShortcut(NSString *key, NSEventModifierFlags modifiers);

/// All methods and callbacks run on the main thread. The engine owns the AppKit run loop.
@interface ARCChromiumRuntime : NSObject
@property(copy, nullable) void (^onReady)(void);
@property(copy, nullable) void (^onNotice)(NSString *message);
@property(copy, nullable) void (^onInstallRequest)(NSDictionary<NSString *, id> *request);
@property(copy, nullable) void (^onExtensionPopup)(NSDictionary<NSString *, id> *popup);
@property(copy, nullable) void (^onExtensionPopupClosed)(NSString *popupID);
@property(copy, nullable) void (^onExtensionPopupSize)(NSString *popupID, NSSize size);
@property(copy, nullable) void (^onWebsiteMediaRequest)(NSDictionary<NSString *, id> *request);
@property(copy, nullable) void (^onWebsiteMediaDismissed)(NSString *requestID);
@property(copy, nullable) void (^onMediaAccess)(NSString *tabID, NSDictionary<NSString *, NSNumber *> *access);
@property(copy, nullable) void (^onFindResult)(NSString *tabID, NSString *requestID, int count, int active, BOOL final);
@property(copy, nullable) void (^onDownloadChanged)(NSString *profileID, NSDictionary<NSString *, id> *download);
@property(copy, nullable) void (^onDownloadRemoved)(NSString *profileID, NSString *downloadID);
@property(copy, nullable) void (^onDownloadsRestored)(NSString *profileID, NSArray<NSDictionary<NSString *, id> *> *downloads);
@property(copy, nullable) void (^onTabChanged)(NSString *tabID, NSString *url, NSString *title,
                                             BOOL loading, BOOL canGoBack, BOOL canGoForward);
@property(copy, nullable) void (^onTabClosed)(NSString *tabID);
@property(copy, nullable) void (^onNewTab)(NSString *tabID, NSString *profileID, NSString *url,
                                         NSString * _Nullable openerID, BOOL foreground);
@property(readonly, nullable) NSWindow *window;
@property(readonly, nullable) NSView *hostView;
@property(readonly) NSString *chromiumVersion;

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
- (BOOL)findInTabID:(NSString *)tabID profileID:(NSString *)profileID requestID:(NSString *)requestID
              text:(NSString *)text forward:(BOOL)forward;
- (void)stopFindingInTabID:(NSString *)tabID;
- (void)downloadCommand:(NSString *)command downloadID:(NSString *)downloadID profileID:(NSString *)profileID
            completion:(void (^)(NSError * _Nullable))completion;
- (void)refreshDownloadsForProfileID:(NSString *)profileID;
- (BOOL)placeTabIDs:(NSArray<NSString *> *)tabIDs pinnedIDs:(NSArray<NSString *> *)pinnedIDs
         profileID:(NSString *)profileID;
/// Evaluates a JavaScript expression and returns its JSON value through ArdiaCore's post callback.
- (void)evaluateInTabID:(NSString *)tabID script:(NSString *)script
            completion:(void (^)(NSString * _Nullable))completion;
/// Captures only the disposable probe's own tab, without a remote debugging socket.
- (void)captureProbeTabID:(NSString *)tabID completion:(void (^)(NSData * _Nullable))completion;
- (NSArray<NSDictionary<NSString *, id> *> *)extensionsForProfileID:(NSString *)profileID;
- (void)resolveInstallRequestID:(NSString *)requestID accepted:(BOOL)accepted;
- (void)resolveWebsiteMediaRequestID:(NSString *)requestID accepted:(BOOL)accepted;
- (BOOL)executeExtensionID:(NSString *)extensionID tabID:(NSString *)tabID error:(NSError **)error;
- (nullable NSView *)viewForExtensionPopupID:(NSString *)popupID;
- (void)closeExtensionPopup;
/// Test-only component loader. Requires a path below the marked disposable probe root.
- (nullable NSString *)loadProbeExtensionAtURL:(NSURL *)url profileID:(NSString *)profileID error:(NSError **)error;
- (void)evaluateProbePopupID:(NSString *)popupID script:(NSString *)script
                 completion:(void (^)(NSString * _Nullable))completion;
- (int)nativeTabIDForID:(NSString *)tabID;
- (void)captureProbePopupID:(NSString *)popupID completion:(void (^)(NSData * _Nullable))completion;
- (void)evaluateProbeUserGestureInTabID:(NSString *)tabID script:(NSString *)script
                           completion:(void (^)(NSString * _Nullable))completion;
- (void)quit;
/// Sends trusted renderer input only to the current disposable probe popup.
- (void)clickProbePopupID:(NSString *)popupID buttonTitle:(NSString *)title
              completion:(void (^)(BOOL clicked))completion;
- (void)clickProbeElementInTabID:(NSString *)tabID elementID:(NSString *)elementID
                    completion:(void (^)(BOOL clicked))completion;
@end

NS_ASSUME_NONNULL_END
