// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#import "include/ChromiumBridgeVerification.h"

static NSError *ProbeUnsupported(void) {
  return [NSError errorWithDomain:@"org.arcusis.shaar.probe" code:1
                         userInfo:@{NSLocalizedDescriptionKey: @"This native probe is not supported by the Shaar engine."}];
}

void ARCCompletePrivateQuitDialogCancellation(
    BOOL ownerCurrent, NSString *dialogError, void (^releaseHold)(void), void (^reject)(void)) {
  if (!ownerCurrent || dialogError) { reject(); return; }
  releaseHold();
}

@implementation ARCChromiumRuntime (Verification)
- (void)grantProbeGeolocationInTabID:(NSString *)tabID completion:(void (^)(NSError *))completion {
  completion(ProbeUnsupported());
}
- (void)inspectorProbePointerInTabID:(NSString *)tabID selector:(NSString *)selector
                            frames:(NSArray<NSString *> *)frames click:(BOOL)click modifiers:(NSInteger)modifiers
                        completion:(void (^)(BOOL))completion { completion(NO); }
- (void)inspectorProbeKeyInTabID:(NSString *)tabID key:(NSString *)key
                    completion:(void (^)(BOOL))completion { completion(NO); }
- (BOOL)inspectProbeElementInTabID:(NSString *)tabID { return NO; }
- (BOOL)probeInspectFound { return NO; }
- (NSDictionary *)probeInspectAudit { return nil; }
- (NSDictionary *)probeExternalAppLaunchAuditForURL:(NSString *)url { return nil; }
- (void)captureProbeTabID:(NSString *)tabID completion:(void (^)(NSData *))completion { completion(nil); }
- (void)captureMarketingProbeTabID:(NSString *)tabID completion:(void (^)(NSData *))completion { completion(nil); }
- (void)evaluatePrivateProbeTabID:(NSString *)tabID script:(NSString *)script
                       completion:(void (^)(NSString *))completion { completion(nil); }
- (void)probePrivateNetworkControlsForTabID:(NSString *)tabID completion:(void (^)(BOOL))completion { completion(NO); }
- (NSDictionary *)privatePrivacyStatusForProbeTabID:(NSString *)tabID { return nil; }
- (NSDictionary *)privatePrivacyPreferencesForContextID:(NSString *)contextID { return nil; }
- (void)evaluatePrivacyProbeTabID:(NSString *)tabID script:(NSString *)script
                          completion:(void (^)(NSString *))completion { completion(nil); }
- (BOOL)attemptCancelledPrivateProbeCloseID:(NSString *)windowID { return NO; }
- (NSDictionary *)privateProbeAuditForContextID:(NSString *)contextID { return nil; }
- (BOOL)privateProbeCaptureIsReadyForTabID:(NSString *)tabID windowID:(NSString *)windowID
                              contextID:(NSString *)contextID { return NO; }
- (void)capturePrivateProbeTabID:(NSString *)tabID windowID:(NSString *)windowID
                       contextID:(NSString *)contextID
                      completion:(void (^)(NSData *, NSString *))completion {
  completion(nil, @"Shaar native capture probe is unsupported.");
}
- (NSDictionary *)normalProbeSelectionAuditForTabID:(NSString *)tabID { return @{@"supported": @NO}; }
- (NSDictionary *)privateQuitCDPHoldAuditForTabID:(NSString *)tabID { return nil; }
- (void)preparePrivateQuitCancellationProbeTabID:(NSString *)tabID
                                      completion:(void (^)(BOOL))completion { completion(NO); }
- (void)cancelPrivateQuitDialogForProbeTabID:(NSString *)tabID
                                  completion:(void (^)(BOOL))completion { completion(NO); }
- (NSString *)loadProbeExtensionAtURL:(NSURL *)url profileID:(NSString *)profileID
                                 error:(NSError **)error {
  if (error) *error = ProbeUnsupported();
  return nil;
}
- (void)evaluateProbePopupID:(NSString *)popupID script:(NSString *)script
                 completion:(void (^)(NSString *))completion { completion(nil); }
- (void)captureProbePopupID:(NSString *)popupID completion:(void (^)(NSData *))completion { completion(nil); }
- (void)evaluateProbeUserGestureInTabID:(NSString *)tabID script:(NSString *)script
                           completion:(void (^)(NSString *))completion { completion(nil); }
- (void)clickProbePopupID:(NSString *)popupID buttonTitle:(NSString *)title
              completion:(void (^)(BOOL))completion { completion(NO); }
- (void)clickProbeElementInTabID:(NSString *)tabID elementID:(NSString *)elementID
                    completion:(void (^)(BOOL))completion { completion(NO); }
- (BOOL)crashProbeTabID:(NSString *)tabID { return NO; }
- (NSString *)probeKeepAliveState { return nil; }
- (BOOL)probeQuitStoppedEventLoop { return NO; }
@end
