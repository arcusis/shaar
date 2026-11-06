// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#import "../../ChromiumBridge/include/ChromiumBridge.h"
#import "../../ChromiumBridge/ChromiumLocalState.h"
#import "../../ChromiumBridge/ChromiumShaarActivation.h"

NS_ASSUME_NONNULL_BEGIN

@interface ARCShaarRuntime (FrameworkDevToolsVerification)
/// Returns native component registration state only in SHAAR_ENGINE_TESTING mode.
- (void)probeFrameworkDevToolsForProfileID:(NSString *)profileID
    completion:(void (^)(NSDictionary<NSString *, id> * _Nullable, NSError * _Nullable))completion;
@end

// Verification interface for the ShaarVerification harness, imported from Swift as
// `ChromiumBridgeVerification`. The app never imports it. Each entry point does nothing
// unless the runtime started in testing mode with an owned, marked disposable probe root.

/// Test-only sanitizer for external-app audit fixtures; returns fixed primitive fields only.
FOUNDATION_EXPORT NSDictionary * _Nullable ARCProbeExternalAppLaunchAuditForTesting(
  NSString *url, NSArray *launches, NSURL *root, BOOL enabled);

/// Turns off Chromium background mode in the Local State of `userDataDirectory`; YES when it is off.
/// The runtime applies it before every launch. Exposed so tests can exercise the edit directly.
/// Verification callback transition: a pending/rejected dialog must retain its CDP hold.
FOUNDATION_EXPORT void ARCCompletePrivateQuitDialogCancellation(
  BOOL ownerCurrent, NSString * _Nullable dialogError, void (^releaseHold)(void), void (^reject)(void));

/// Decode a bounded PNG returned by Page.captureScreenshot; reject missing or malformed evidence.
FOUNDATION_EXPORT NSData * _Nullable ARCProbePNGFromDevToolsResult(NSDictionary * _Nullable result);

/// The shipped media reporter, for deterministic JavaScript event-order tests without an engine.
FOUNDATION_EXPORT NSString *ARCMediaSessionPageScript(void);

/// Tests native media state conversion without starting the Chromium engine.
FOUNDATION_EXPORT NSDictionary * _Nullable ARCProbeShaarMediaPublicState(NSDictionary *native);
/// Injects a scoped media event into a runtime without creating an engine or window.
FOUNDATION_EXPORT NSDictionary *ARCProbeShaarMediaEventDispatch(
  NSDictionary *payload, BOOL validOwner);
/// Injects a DevTools open-URL event and records its validated app callback.
FOUNDATION_EXPORT NSDictionary *ARCProbeShaarDevToolsURLDispatch(
  NSDictionary *payload, BOOL validOwner);

/// Test-only audit of a Shaar page view's attachment to its owning hidden window.
FOUNDATION_EXPORT NSDictionary<NSString *, id> *ARCProbeNormalSelectionAudit(
  NSView * _Nullable tabView, NSView * _Nullable hostView, NSWindow * _Nullable window);

/// Extracts a JSON value from a scoped Shaar Runtime.evaluate reply.
FOUNDATION_EXPORT NSString * _Nullable ARCProbePrivateEvaluationJSON(NSDictionary *reply);

/// Observe the real private selection method during a synchronous product action, forwarding unchanged.
/// Requires the owned Inspector probe root; restores the original method before returning.
FOUNDATION_EXPORT NSArray<NSDictionary *> * _Nullable ARCProbeTracePrivateSelection(
  ARCChromiumRuntime *runtime, void (^action)(void));

/// Await async privacy scripts before returning a copied JSON value.
FOUNDATION_EXPORT NSDictionary<NSString *, id> *ARCProbePrivacyEvaluationParameters(
  NSString *expression);
/// Only the dedicated permission fixture requests a scoped renderer visibility lease.
FOUNDATION_EXPORT NSDictionary<NSString *, id> *ARCProbePrivateEvaluationPayload(
  NSString *expression, BOOL probeVisibleForRenderer);

/// Preserve native normal/private preference observations and wildcard rejection.
FOUNDATION_EXPORT NSDictionary<NSString *, id> *ARCProbePrivatePrivacyPreferences(
  NSDictionary *status, NSInteger wildcardStatus);

/// Reads native-owned dock geometry without retaining or reparenting its frontend.
FOUNDATION_EXPORT NSDictionary * _Nullable ARCProbeDevToolsDockAudit(
  ARCChromiumRuntime *runtime, NSString *tabID, NSString *windowID,
  NSString * _Nullable contextID);

@interface ARCChromiumRuntime (Verification)
/// Testing-only DevTools frontend route through a selected Shaar-owned tab.
- (void)probeDevToolsRouteInTabID:(NSString *)tabID operation:(NSInteger)operation
                         payload:(NSDictionary *)payload
                      completion:(void (^)(BOOL))completion;
/// Grants geolocation only on the selected disposable Inspector loopback fixture.
- (void)grantProbeGeolocationInTabID:(NSString *)tabID completion:(void (NS_SWIFT_UI_ACTOR ^)(NSError * _Nullable))completion NS_SWIFT_UI_ACTOR;
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
/// Marketing capture only: captures the exact native viewport, excluding content below the window.
/// Requires the explicit capture flag and an owned disposable probe root.
- (void)captureMarketingProbeTabID:(NSString *)tabID completion:(void (^)(NSData * _Nullable))completion;
- (void)evaluatePrivateProbeTabID:(NSString *)tabID script:(NSString *)script
                       completion:(void (^)(NSString * _Nullable))completion;
- (void)probePrivateNetworkControlsForTabID:(NSString *)tabID completion:(void (^)(BOOL))completion;
- (nullable NSDictionary *)privatePrivacyStatusForProbeTabID:(NSString *)tabID;
- (nullable NSDictionary *)privatePrivacyPreferencesForContextID:(NSString *)contextID;
- (void)evaluatePrivacyProbeTabID:(NSString *)tabID script:(NSString *)script
                          completion:(void (^)(NSString * _Nullable))completion;
- (void)evaluatePrivatePermissionProbeTabID:(NSString *)tabID script:(NSString *)script
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
/// The owned private tab's pre-navigation stage in a marked hidden probe.
- (nullable NSDictionary<NSString *, id> *)privateNavigationProbeAuditForTabID:(NSString *)tabID;
/// Intentionally terminates only an authored loopback page in a disposable probe profile.
- (BOOL)crashProbeTabID:(NSString *)tabID;
/// Chromium's keep-alive registry and quit state, for diagnosing a process that outlives Quit.
/// Valid only while the engine loop runs.
- (nullable NSString *)probeKeepAliveState;
/// Whether Quit needed the shutdown guard to stop the AppKit event loop.
@property(readonly) BOOL probeQuitStoppedEventLoop;
@end

NS_ASSUME_NONNULL_END
