#import "ChromiumBridge.h"

NS_ASSUME_NONNULL_BEGIN

// Verification interface for the ShaarVerification harness, imported from Swift as
// `ChromiumBridge.Verification`. The app never imports it. Each entry point does nothing
// unless the runtime started in testing mode with an owned, marked disposable probe root.

/// Test-only sanitizer for external-app audit fixtures; returns fixed primitive fields only.
FOUNDATION_EXPORT NSDictionary * _Nullable ARCProbeExternalAppLaunchAuditForTesting(
  NSString *url, NSArray *launches, NSURL *root, BOOL enabled);

@interface ARCChromiumRuntime (Verification)
/// Test-only bounded audit. Requires explicit external-probe switch, testing mode, and owned marked root.
- (nullable NSDictionary *)probeExternalAppLaunchAuditForURL:(NSString *)url;
/// Captures only the disposable probe's own tab, without a remote debugging socket.
- (void)captureProbeTabID:(NSString *)tabID completion:(void (^)(NSData * _Nullable))completion;
- (void)evaluatePrivateProbeTabID:(NSString *)tabID script:(NSString *)script
                       completion:(void (^)(NSString * _Nullable))completion;
- (BOOL)attemptCancelledPrivateProbeCloseID:(NSString *)windowID;
- (nullable NSDictionary *)privateProbeAuditForContextID:(NSString *)contextID;
- (void)capturePrivateProbeTabID:(NSString *)tabID windowID:(NSString *)windowID
                       contextID:(NSString *)contextID
                      completion:(void (^)(NSData * _Nullable, NSString * _Nullable))completion;
- (NSDictionary *)normalProbeSelectionAuditForTabID:(NSString *)tabID;
- (nullable NSDictionary *)privateQuitCDPHoldAuditForTabID:(NSString *)tabID;
- (void)preparePrivateQuitCancellationProbeTabID:(NSString *)tabID
                                      completion:(void (^)(BOOL))completion;
- (void)cancelPrivateQuitDialogForProbeTabID:(NSString *)tabID
                                  completion:(void (^)(BOOL))completion;
/// Test-only component loader. Requires a path below the marked disposable probe root.
- (nullable NSString *)loadProbeExtensionAtURL:(NSURL *)url profileID:(NSString *)profileID error:(NSError **)error;
- (void)evaluateProbePopupID:(NSString *)popupID script:(NSString *)script
                 completion:(void (^)(NSString * _Nullable))completion;
- (void)captureProbePopupID:(NSString *)popupID completion:(void (^)(NSData * _Nullable))completion;
- (void)evaluateProbeUserGestureInTabID:(NSString *)tabID script:(NSString *)script
                           completion:(void (^)(NSString * _Nullable))completion;
/// Sends trusted renderer input only to the current disposable probe popup.
- (void)clickProbePopupID:(NSString *)popupID buttonTitle:(NSString *)title
              completion:(void (^)(BOOL clicked))completion;
- (void)clickProbeElementInTabID:(NSString *)tabID elementID:(NSString *)elementID
                    completion:(void (^)(BOOL clicked))completion;
/// Intentionally terminates only an authored loopback page in a disposable probe profile.
- (BOOL)crashProbeTabID:(NSString *)tabID;
@end

NS_ASSUME_NONNULL_END
