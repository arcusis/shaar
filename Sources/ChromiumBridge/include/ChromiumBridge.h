#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// All methods and callbacks run on the main thread. The engine owns the AppKit run loop.
@interface ARCChromiumRuntime : NSObject
@property(copy, nullable) void (^onReady)(void);
@property(copy, nullable) void (^onNotice)(NSString *message);
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
- (void)closeTabID:(NSString *)tabID;
- (void)discardTabID:(NSString *)tabID;
- (void)goBackInTabID:(NSString *)tabID;
- (void)goForwardInTabID:(NSString *)tabID;
- (void)reloadTabID:(NSString *)tabID;
/// Evaluates a JavaScript expression and returns its JSON value through ArdiaCore's post callback.
- (void)evaluateInTabID:(NSString *)tabID script:(NSString *)script
            completion:(void (^)(NSString * _Nullable))completion;
/// Captures only the disposable probe's own tab, without a remote debugging socket.
- (void)captureProbeTabID:(NSString *)tabID completion:(void (^)(NSData * _Nullable))completion;
- (void)quit;
@end

NS_ASSUME_NONNULL_END
