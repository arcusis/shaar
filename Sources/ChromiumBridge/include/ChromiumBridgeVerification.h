// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#import "ChromiumBridge.h"

NS_ASSUME_NONNULL_BEGIN

// Verification interface for the ShaarVerification harness, imported from Swift as
// `ChromiumBridge.Verification`. The app never imports it. Each entry point does nothing
// unless the runtime started in testing mode with an owned, marked disposable probe root.

/// Test-only sanitizer for external-app audit fixtures; returns fixed primitive fields only.
FOUNDATION_EXPORT NSDictionary * _Nullable ARCProbeExternalAppLaunchAuditForTesting(
  NSString *url, NSArray *launches, NSURL *root, BOOL enabled);

/// Turns off Chromium background mode in the Local State of `userDataDirectory`; YES when it is off.
/// The runtime applies it before every launch. Exposed so tests can exercise the edit directly.
FOUNDATION_EXPORT BOOL ARCDisableBackgroundMode(NSURL *userDataDirectory);

@interface ARCChromiumRuntime (Verification)
- (void)inspectorProbePointerInTabID:(NSString *)tabID selector:(NSString *)selector
                            frames:(NSArray<NSString *> *)frames click:(BOOL)click modifiers:(NSInteger)modifiers
                        completion:(void (NS_SWIFT_UI_ACTOR ^)(BOOL))completion NS_SWIFT_UI_ACTOR;
- (void)inspectorProbeKeyInTabID:(NSString *)tabID key:(NSString *)key
                    completion:(void (NS_SWIFT_UI_ACTOR ^)(BOOL))completion NS_SWIFT_UI_ACTOR;
/// Opens the engine's own Inspect menu command on an authored loopback page, offscreen.
- (BOOL)inspectProbeElementInTabID:(NSString *)tabID;
@property(readonly) BOOL probeInspectFound;
@property(readonly, nullable) NSDictionary *probeInspectAudit;
/// Test-only bounded audit. Requires explicit external-probe switch, testing mode, and owned marked root.
- (nullable NSDictionary *)probeExternalAppLaunchAuditForURL:(NSString *)url;
/// Captures only the disposable probe's own tab, without a remote debugging socket.
- (void)captureProbeTabID:(NSString *)tabID completion:(void (^)(NSData * _Nullable))completion;
- (void)evaluatePrivateProbeTabID:(NSString *)tabID script:(NSString *)script
                       completion:(void (^)(NSString * _Nullable))completion;
- (BOOL)attemptCancelledPrivateProbeCloseID:(NSString *)windowID;
- (nullable NSDictionary *)privateProbeAuditForContextID:(NSString *)contextID;
/// The selected owned loopback tab is loaded and attached; does not start a capture.
- (BOOL)privateProbeCaptureIsReadyForTabID:(NSString *)tabID windowID:(NSString *)windowID
                              contextID:(NSString *)contextID;
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
/// Chromium's keep-alive registry and quit state, for diagnosing a process that outlives Quit.
/// Valid only while the engine loop runs.
- (nullable NSString *)probeKeepAliveState;
/// Whether Quit needed the shutdown guard to stop the AppKit event loop.
@property(readonly) BOOL probeQuitStoppedEventLoop;
@end

NS_ASSUME_NONNULL_END
