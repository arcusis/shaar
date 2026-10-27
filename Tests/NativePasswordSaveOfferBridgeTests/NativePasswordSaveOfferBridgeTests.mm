#import <XCTest/XCTest.h>

// Real bridge implementation; test flag replaces engine lookup and injects
// inert objects only. No engine initialization or UI object is created.
#import "../../Sources/ChromiumBridge/ChromiumBridge.mm"

namespace {
int libraryToken;
int Configure(uint32_t version) { return version == 1 ? 1 : 0; }
uint32_t VersionOne() { return 1; }
uint32_t VersionTwo() { return 2; }
NSString *const windowID = @"43D0A5F6-B639-4629-B34D-413193A0481A";
NSString *const profileID = @"FCF7739F-2E2A-4D70-BB86-A04BD8FD026C";
NSString *const tabID = @"21C07C67-F6B2-462F-9231-293039C0CFB0";
NSString *const captureID = @"57E79F29-91CE-4990-A9D1-124666AB5385";
NSString *const accountEpoch = @"14CAB0F2-E91A-43CA-9AC2-FB1C86044D0C";
}

@interface SaveFakeProfile : NSObject
@property BOOL offTheRecord;
@property BOOL destroyed;
@end
@implementation SaveFakeProfile
@end

@interface SaveFakeTab : NSObject
@property BOOL closed;
@property(strong) SaveFakeProfile *profile;
@property(strong) NSMutableArray *eventTrace;
@end
@implementation SaveFakeTab
- (void)close { [_eventTrace addObject:@"closeTab"]; }
- (void)closeNow { [_eventTrace addObject:@"discard"]; }
@end

@interface SaveFakeOffer : NSObject <ARCNativeSaveOffer>
@property(nonatomic, copy) NSString *offerID;
@property(nonatomic, copy) NSString *accountEpoch;
@property(nonatomic, copy) NSString *originalOrigin;
@property(nonatomic, copy) NSString *originalDocumentURL;
@property(nonatomic) NSInteger provenance;
@property(nonatomic) NSTimeInterval deadline;
@end
@implementation SaveFakeOffer
@end

@interface SaveFakeWindow : NSObject
@property(strong) SaveFakeProfile *activeProfile;
@property(strong) SaveFakeTab *tab;
@property(strong) NSMutableArray *eventTrace;
@property(copy) void (^offerCallback)(id<ARCNativeSaveOffer>);
@property(copy) void (^revokeCallback)(void);
@property(copy) void (^consumeCallback)(NSInteger, NSString *, NSString *);
@property NSInteger armCount;
@property NSInteger cancelCount;
@property NSInteger consumeCount;
@end
@implementation SaveFakeWindow
@synthesize activeProfile = _activeProfile;
- (void)setActiveProfile:(SaveFakeProfile *)profile {
  _activeProfile = profile;
  [_eventTrace addObject:@"profile"];
}
- (NSWindow *)window { return (NSWindow *)self; }
- (BOOL)isKeyWindow { return YES; }
- (NSArray *)tabsForProfile:(id)profile { return profile == self.activeProfile ? @[self.tab] : @[]; }
- (void)activateTab:(id)tab { [_eventTrace addObject:@"activate"]; }
- (void)close { [_eventTrace addObject:@"close"]; }
- (id)armPasswordSaveForTab:(id)tab accountEpoch:(NSString *)epoch
  onOffer:(void (^)(id<ARCNativeSaveOffer>))onOffer onRevoke:(void (^)(void))onRevoke {
  ++_armCount;
  _offerCallback = [onOffer copy];
  _revokeCallback = [onRevoke copy];
  return [NSObject new];
}
- (void)consumePasswordSaveOffer:(id)offer displayedOrigin:(NSString *)origin
  completion:(void (^)(NSInteger, NSString *, NSString *))completion {
  ++_consumeCount;
  _consumeCallback = [completion copy];
}
- (void)cancelPasswordSaveCapture:(id)capture {
  ++_cancelCount;
  if (_revokeCallback) _revokeCallback();
}
@end

@interface NativePasswordSaveOfferBridgeTests : XCTestCase
@end
@implementation NativePasswordSaveOfferBridgeTests
#define REQUIRE_CALLBACK(callback) do { XCTAssertNotNil(callback); if (!(callback)) return; } while (0)

- (ARCChromiumRuntime *)runtimeWithWindow:(SaveFakeWindow **)result version:(uint32_t (*)(void))version {
  XCTAssertTrue(NSThread.isMainThread);
  SaveFakeProfile *profile = [SaveFakeProfile new];
  SaveFakeTab *tab = [SaveFakeTab new]; tab.profile = profile;
  SaveFakeWindow *window = [SaveFakeWindow new]; window.activeProfile = profile; window.tab = tab;
  ARCChromiumRuntime *runtime = [ARCChromiumRuntime new];
  [runtime fixtureSetSaveLibrary:&libraryToken version:version window:window profile:profile tab:tab
    windowID:windowID profileID:profileID tabID:tabID];
  const void *owner = (__bridge const void *)runtime;
  XCTAssertTrue(PasswordStartup().select(owner, &libraryToken, Configure, false));
  XCTAssertTrue(PasswordStartup().begin(owner, &libraryToken));
  *result = window;
  return runtime;
}

- (SaveFakeOffer *)offer {
  SaveFakeOffer *offer = [SaveFakeOffer new];
  offer.offerID = @"14C90982-87E4-4680-A7A0-A6CFA0168858";
  offer.accountEpoch = accountEpoch;
  offer.originalOrigin = @"https://login.example";
  offer.originalDocumentURL = @"https://login.example/login?q=private";
  offer.provenance = 1;
  offer.deadline = NSProcessInfo.processInfo.systemUptime + 20;
  return offer;
}

- (void)testCanonicalOriginAndOriginalURLValidation {
  XCTAssertTrue(ARCCanonicalHTTPSOrigin(@"https://login.example"));
  XCTAssertTrue(ARCSaveDocumentURLMatchesOrigin(@"https://login.example/login?q=private",
                                                @"https://login.example"));
  XCTAssertTrue(ARCCanonicalHTTPSOrigin(@"https://login.example:8443"));
  XCTAssertTrue(ARCSaveDocumentURLMatchesOrigin(@"https://login.example:8443/login?q=private",
                                                @"https://login.example:8443"));
  XCTAssertFalse(ARCCanonicalHTTPSOrigin(@"https://login.example:443"));
  XCTAssertFalse(ARCCanonicalHTTPSOrigin(@"http://login.example"));
  XCTAssertFalse(ARCCanonicalHTTPSOrigin(@"https://login.example:abc"));
  XCTAssertFalse(ARCCanonicalHTTPSOrigin(@"https://login.example:0"));
  XCTAssertFalse(ARCCanonicalHTTPSOrigin(@"https://login.example:65536"));
  XCTAssertFalse(ARCCanonicalHTTPSOrigin(@"https://LOGIN.example"));
  XCTAssertFalse(ARCCanonicalHTTPSOrigin(@"https://user@login.example"));
  XCTAssertFalse(ARCSaveDocumentURLMatchesOrigin(@"https://user@login.example/login",
                                                 @"https://login.example"));
  XCTAssertFalse(ARCSaveDocumentURLMatchesOrigin(@"https://login.example:8443/login",
                                                 @"https://login.example"));
  XCTAssertFalse(ARCSaveDocumentURLMatchesOrigin(@"https://other.example/path",
                                                 @"https://login.example"));
}

- (void)testSaveAdmissionPredicates {
  SaveFakeWindow *window;
  ARCChromiumRuntime *runtime = [self runtimeWithWindow:&window version:VersionOne];
  __block NSInteger offers = 0;
  XCTAssertTrue([runtime armPasswordSaveCaptureID:captureID windowID:windowID
    profileID:profileID tabID:tabID accountEpoch:accountEpoch
    onOffer:^(ARCPasswordSaveOffer *offer) { ++offers; } onRevoke:^{}]);
  XCTAssertTrue([runtime fixtureSaveOwnerCurrent:captureID], @"owner");
  XCTAssertTrue([runtime fixtureSaveCaptureInstalled:captureID], @"capture");
  SaveFakeOffer *offer = [self offer];
  XCTAssertTrue(ValidID(offer.offerID), @"offer ID");
  XCTAssertEqualObjects(offer.accountEpoch, accountEpoch, @"account");
  XCTAssertTrue(ARCSaveDocumentURLMatchesOrigin(offer.originalDocumentURL, offer.originalOrigin), @"URL");
  XCTAssertTrue(offer.provenance >= 1 && offer.provenance <= 3, @"provenance");
  XCTAssertTrue(offer.deadline > NSProcessInfo.processInfo.systemUptime, @"deadline");
  REQUIRE_CALLBACK(window.offerCallback);
  window.offerCallback(offer);
  XCTAssertEqual(offers, 1);
  [runtime cancelPasswordSaveCaptureID:captureID];
}

- (void)testMetadataThenSingleExplicitConsume {
  SaveFakeWindow *window;
  ARCChromiumRuntime *runtime = [self runtimeWithWindow:&window version:VersionOne];
  __block ARCPasswordSaveOffer *received = nil;
  __block NSInteger revoked = 0;
  XCTAssertTrue([runtime armPasswordSaveCaptureID:captureID windowID:windowID
    profileID:profileID tabID:tabID accountEpoch:accountEpoch
    onOffer:^(ARCPasswordSaveOffer *offer) { received = offer; }
    onRevoke:^{ ++revoked; }]);
  REQUIRE_CALLBACK(window.offerCallback);
  window.offerCallback([self offer]);
  XCTAssertNotNil(received);
  if (!received) return;
  XCTAssertEqualObjects(received.originalOrigin, @"https://login.example");
  XCTAssertEqualObjects(received.originalDocumentURL, @"https://login.example/login?q=private");
  XCTAssertEqualObjects(received.accountEpoch, accountEpoch);
  XCTAssertEqual(window.consumeCount, 0);
  __block NSInteger completions = 0;
  [runtime consumePasswordSaveOffer:received displayedOrigin:received.originalOrigin
    completion:^(ARCPasswordSaveStatus status, NSString *username, NSString *password) {
      ++completions;
      XCTAssertEqual(status, ARCPasswordSaveStatusConsumed);
      XCTAssertEqualObjects(username, @"synthetic-user");
      XCTAssertEqualObjects(password, @"synthetic-password");
    }];
  XCTAssertEqual(window.consumeCount, 1);
  REQUIRE_CALLBACK(window.consumeCallback);
  window.consumeCallback(0, @"synthetic-user", @"synthetic-password");
  window.consumeCallback(0, @"synthetic-user", @"synthetic-password");
  XCTAssertEqual(completions, 1);
  [runtime cancelPasswordSaveCaptureID:captureID];
  XCTAssertEqual(revoked, 1);
}

- (void)testRevocationWinsBeforeDelayedCredentialCallback {
  SaveFakeWindow *window;
  ARCChromiumRuntime *runtime = [self runtimeWithWindow:&window version:VersionOne];
  __block ARCPasswordSaveOffer *received;
  __block NSInteger revoked = 0, completions = 0;
  XCTAssertTrue([runtime armPasswordSaveCaptureID:captureID windowID:windowID
    profileID:profileID tabID:tabID accountEpoch:accountEpoch
    onOffer:^(ARCPasswordSaveOffer *offer) { received = offer; }
    onRevoke:^{ ++revoked; }]);
  REQUIRE_CALLBACK(window.offerCallback);
  window.offerCallback([self offer]);
  XCTAssertNotNil(received);
  if (!received) return;
  [runtime consumePasswordSaveOffer:received displayedOrigin:received.originalOrigin
    completion:^(ARCPasswordSaveStatus status, NSString *username, NSString *password) {
      ++completions;
      XCTAssertEqual(revoked, 1);
      XCTAssertEqual(status, ARCPasswordSaveStatusUnavailable);
      XCTAssertNil(username); XCTAssertNil(password);
    }];
  [runtime cancelPasswordSaveCaptureID:captureID];
  REQUIRE_CALLBACK(window.consumeCallback);
  window.consumeCallback(0, @"synthetic-user", @"synthetic-password");
  XCTAssertEqual(revoked, 1);
  XCTAssertEqual(completions, 1);
  XCTAssertEqual(window.cancelCount, 1);
}

- (void)testRejectsForeignURLAndRevokesBeforeCallback {
  SaveFakeWindow *window;
  ARCChromiumRuntime *runtime = [self runtimeWithWindow:&window version:VersionOne];
  __block NSInteger offers = 0, revoked = 0;
  XCTAssertTrue([runtime armPasswordSaveCaptureID:captureID windowID:windowID
    profileID:profileID tabID:tabID accountEpoch:accountEpoch
    onOffer:^(ARCPasswordSaveOffer *offer) { ++offers; } onRevoke:^{ ++revoked; }]);
  SaveFakeOffer *bad = [self offer]; bad.originalDocumentURL = @"https://other.example/path";
  REQUIRE_CALLBACK(window.offerCallback);
  window.offerCallback(bad);
  XCTAssertEqual(offers, 0);
  XCTAssertEqual(revoked, 1);
  XCTAssertEqual(window.cancelCount, 1);
}

- (void)testUnsupportedVersionCannotArm {
  SaveFakeWindow *window;
  ARCChromiumRuntime *runtime = [self runtimeWithWindow:&window version:VersionTwo];
  XCTAssertFalse([runtime armPasswordSaveCaptureID:captureID windowID:windowID
    profileID:profileID tabID:tabID accountEpoch:accountEpoch
    onOffer:^(ARCPasswordSaveOffer *offer) {} onRevoke:^{}]);
  XCTAssertEqual(window.armCount, 0);
}

- (void)testMissingVersionCannotArm {
  SaveFakeWindow *window;
  ARCChromiumRuntime *runtime = [self runtimeWithWindow:&window version:nullptr];
  XCTAssertFalse([runtime armPasswordSaveCaptureID:captureID windowID:windowID
    profileID:profileID tabID:tabID accountEpoch:accountEpoch
    onOffer:^(ARCPasswordSaveOffer *offer) {} onRevoke:^{}]);
  XCTAssertEqual(window.armCount, 0);
}

- (void)testWrongDisplayedOriginCancelsBeforeConsume {
  SaveFakeWindow *window;
  ARCChromiumRuntime *runtime = [self runtimeWithWindow:&window version:VersionOne];
  __block ARCPasswordSaveOffer *received;
  __block NSInteger revokes = 0, completions = 0;
  XCTAssertTrue([runtime armPasswordSaveCaptureID:captureID windowID:windowID
    profileID:profileID tabID:tabID accountEpoch:accountEpoch
    onOffer:^(ARCPasswordSaveOffer *offer) { received = offer; } onRevoke:^{ ++revokes; }]);
  REQUIRE_CALLBACK(window.offerCallback);
  window.offerCallback([self offer]);
  XCTAssertNotNil(received);
  if (!received) return;
  [runtime consumePasswordSaveOffer:received displayedOrigin:@"https://other.example"
    completion:^(ARCPasswordSaveStatus status, NSString *username, NSString *password) {
      ++completions;
      XCTAssertEqual(status, ARCPasswordSaveStatusUnavailable);
      XCTAssertNil(username); XCTAssertNil(password);
    }];
  XCTAssertEqual(window.consumeCount, 0);
  XCTAssertEqual(revokes, 1);
  XCTAssertEqual(completions, 1);
}

- (void)testForeignEpochAndExpiredOfferCannotPublish {
  SaveFakeWindow *window;
  ARCChromiumRuntime *runtime = [self runtimeWithWindow:&window version:VersionOne];
  __block NSInteger offers = 0, revokes = 0;
  XCTAssertTrue([runtime armPasswordSaveCaptureID:captureID windowID:windowID
    profileID:profileID tabID:tabID accountEpoch:accountEpoch
    onOffer:^(ARCPasswordSaveOffer *offer) { ++offers; } onRevoke:^{ ++revokes; }]);
  SaveFakeOffer *bad = [self offer];
  bad.accountEpoch = @"EFEE0A65-44B9-42F1-85F2-2DCE137092BB";
  REQUIRE_CALLBACK(window.offerCallback);
  window.offerCallback(bad);
  XCTAssertEqual(offers, 0); XCTAssertEqual(revokes, 1);

  NSString *secondCapture = @"7A066649-97A5-4B8E-B688-852EC9B548AD";
  XCTAssertTrue([runtime armPasswordSaveCaptureID:secondCapture windowID:windowID
    profileID:profileID tabID:tabID accountEpoch:accountEpoch
    onOffer:^(ARCPasswordSaveOffer *offer) { ++offers; } onRevoke:^{ ++revokes; }]);
  SaveFakeOffer *expired = [self offer];
  expired.deadline = NSProcessInfo.processInfo.systemUptime - 1;
  REQUIRE_CALLBACK(window.offerCallback);
  window.offerCallback(expired);
  XCTAssertEqual(offers, 0); XCTAssertEqual(revokes, 2);
}

- (void)testReentrantCancelDoesNotRepublish {
  SaveFakeWindow *window;
  ARCChromiumRuntime *runtime = [self runtimeWithWindow:&window version:VersionOne];
  __block NSInteger offers = 0, revokes = 0;
  XCTAssertTrue([runtime armPasswordSaveCaptureID:captureID windowID:windowID
    profileID:profileID tabID:tabID accountEpoch:accountEpoch
    onOffer:^(ARCPasswordSaveOffer *offer) {
      ++offers;
      [runtime cancelPasswordSaveCaptureID:captureID];
    } onRevoke:^{ ++revokes; }]);
  void (^oldCallback)(id<ARCNativeSaveOffer>) = window.offerCallback;
  REQUIRE_CALLBACK(oldCallback);
  oldCallback([self offer]);
  oldCallback([self offer]);
  XCTAssertEqual(offers, 1);
  XCTAssertEqual(revokes, 1);
}

- (void)testTwoWindowsRevokeIndependently {
  SaveFakeWindow *first;
  ARCChromiumRuntime *runtime = [self runtimeWithWindow:&first version:VersionOne];
  NSString *secondWindow = @"842865A7-A24A-4FD8-A448-D366B5DBD301";
  NSString *secondProfile = @"568AA969-7B1F-4872-BF67-B8C0DB2DA135";
  NSString *secondTab = @"5059F66A-83F3-46ED-8ABF-2B637901C4AC";
  NSString *secondCapture = @"7A066649-97A5-4B8E-B688-852EC9B548AD";
  SaveFakeProfile *profile = [SaveFakeProfile new];
  SaveFakeTab *tab = [SaveFakeTab new]; tab.profile = profile;
  SaveFakeWindow *second = [SaveFakeWindow new]; second.activeProfile = profile; second.tab = tab;
  [runtime fixtureAddSaveWindow:second profile:profile tab:tab
    windowID:secondWindow profileID:secondProfile tabID:secondTab];
  __block NSInteger firstRevoked = 0, secondRevoked = 0, secondOffers = 0;
  XCTAssertTrue([runtime armPasswordSaveCaptureID:captureID windowID:windowID
    profileID:profileID tabID:tabID accountEpoch:accountEpoch
    onOffer:^(ARCPasswordSaveOffer *offer) {} onRevoke:^{ ++firstRevoked; }]);
  XCTAssertTrue([runtime armPasswordSaveCaptureID:secondCapture windowID:secondWindow
    profileID:secondProfile tabID:secondTab accountEpoch:accountEpoch
    onOffer:^(ARCPasswordSaveOffer *offer) { ++secondOffers; } onRevoke:^{ ++secondRevoked; }]);
  [runtime cancelPasswordSaveCaptureID:captureID];
  REQUIRE_CALLBACK(second.offerCallback);
  second.offerCallback([self offer]);
  XCTAssertEqual(firstRevoked, 1);
  XCTAssertEqual(secondRevoked, 0);
  XCTAssertEqual(secondOffers, 1);
  [runtime cancelPasswordSaveCaptureID:secondCapture];
  XCTAssertEqual(secondRevoked, 1);
}

- (void)testKeyResignRevokesSynchronously {
  SaveFakeWindow *window;
  ARCChromiumRuntime *runtime = [self runtimeWithWindow:&window version:VersionOne];
  __block NSInteger revoked = 0;
  XCTAssertTrue([runtime armPasswordSaveCaptureID:captureID windowID:windowID
    profileID:profileID tabID:tabID accountEpoch:accountEpoch
    onOffer:^(ARCPasswordSaveOffer *offer) {} onRevoke:^{ ++revoked; }]);
  [NSNotificationCenter.defaultCenter postNotificationName:NSWindowDidResignKeyNotification
                                                    object:window.window];
  XCTAssertEqual(revoked, 1);
  XCTAssertEqual(window.cancelCount, 1);
}

- (void)testMalformedMetadataIsRejected {
  SaveFakeWindow *window;
  ARCChromiumRuntime *runtime = [self runtimeWithWindow:&window version:VersionOne];
  __block NSInteger offers = 0, revoked = 0;
  XCTAssertTrue([runtime armPasswordSaveCaptureID:captureID windowID:windowID
    profileID:profileID tabID:tabID accountEpoch:accountEpoch
    onOffer:^(ARCPasswordSaveOffer *offer) { ++offers; } onRevoke:^{ ++revoked; }]);
  SaveFakeOffer *bad = [self offer];
  bad.accountEpoch = (NSString *)(id)@42;
  REQUIRE_CALLBACK(window.offerCallback);
  window.offerCallback(bad);
  XCTAssertEqual(offers, 0);
  XCTAssertEqual(revoked, 1);
  __block NSInteger completions = 0;
  [runtime consumePasswordSaveOffer:(ARCPasswordSaveOffer *)(id)@42 displayedOrigin:@"https://login.example"
    completion:^(ARCPasswordSaveStatus status, NSString *username, NSString *password) {
      ++completions;
      XCTAssertEqual(status, ARCPasswordSaveStatusUnavailable);
      XCTAssertNil(username); XCTAssertNil(password);
    }];
  XCTAssertEqual(completions, 1);
}

- (void)testHostTabChangeRevokesConsumedPendingOfferBeforeActivation {
  SaveFakeWindow *window;
  ARCChromiumRuntime *runtime = [self runtimeWithWindow:&window version:VersionOne];
  window.eventTrace = [NSMutableArray array];
  __block ARCPasswordSaveOffer *received;
  __block NSInteger completions = 0;
  XCTAssertTrue([runtime armPasswordSaveCaptureID:captureID windowID:windowID
    profileID:profileID tabID:tabID accountEpoch:accountEpoch
    onOffer:^(ARCPasswordSaveOffer *offer) { received = offer; }
    onRevoke:^{ [window.eventTrace addObject:@"revoke"]; }]);
  REQUIRE_CALLBACK(window.offerCallback);
  window.offerCallback([self offer]);
  XCTAssertNotNil(received);
  if (!received) return;
  [runtime consumePasswordSaveOffer:received displayedOrigin:received.originalOrigin
    completion:^(ARCPasswordSaveStatus status, NSString *username, NSString *password) {
      ++completions;
      XCTAssertEqual(status, ARCPasswordSaveStatusUnavailable);
      XCTAssertNil(username); XCTAssertNil(password);
      [window.eventTrace addObject:@"completion"];
    }];
  NSString *otherTabID = @"EAA3BEA4-59DD-476A-820C-789E191675C5";
  SaveFakeTab *other = [SaveFakeTab new]; other.profile = window.activeProfile;
  [runtime fixtureAddSaveTab:other tabID:otherTabID profileID:profileID windowID:windowID];
  [runtime activateTabID:otherTabID];
  XCTAssertEqualObjects(window.eventTrace, (@[@"revoke", @"completion", @"profile", @"activate"]));
  REQUIRE_CALLBACK(window.consumeCallback);
  window.consumeCallback(0, @"synthetic-user", @"synthetic-password");
  XCTAssertEqual(completions, 1);
}

- (void)testHostProfileChangeRevokesBeforeProfileSwitch {
  SaveFakeWindow *window;
  ARCChromiumRuntime *runtime = [self runtimeWithWindow:&window version:VersionOne];
  window.eventTrace = [NSMutableArray array];
  XCTAssertTrue([runtime armPasswordSaveCaptureID:captureID windowID:windowID
    profileID:profileID tabID:tabID accountEpoch:accountEpoch
    onOffer:^(ARCPasswordSaveOffer *offer) {}
    onRevoke:^{ [window.eventTrace addObject:@"revoke"]; }]);
  NSString *otherID = @"568AA969-7B1F-4872-BF67-B8C0DB2DA135";
  [runtime fixtureAddSaveProfile:[SaveFakeProfile new] profileID:otherID];
  [runtime activateProfileID:otherID windowID:windowID];
  XCTAssertEqualObjects(window.eventTrace, (@[@"revoke", @"profile"]));
}

- (void)testHostWindowCloseRevokesBeforeCloseAndKeepsOtherWindow {
  SaveFakeWindow *first;
  ARCChromiumRuntime *runtime = [self runtimeWithWindow:&first version:VersionOne];
  first.eventTrace = [NSMutableArray array];
  NSString *secondWindow = @"842865A7-A24A-4FD8-A448-D366B5DBD301";
  NSString *secondProfile = @"568AA969-7B1F-4872-BF67-B8C0DB2DA135";
  NSString *secondTab = @"5059F66A-83F3-46ED-8ABF-2B637901C4AC";
  NSString *secondCapture = @"7A066649-97A5-4B8E-B688-852EC9B548AD";
  SaveFakeProfile *profile = [SaveFakeProfile new];
  SaveFakeTab *tab = [SaveFakeTab new]; tab.profile = profile;
  SaveFakeWindow *second = [SaveFakeWindow new]; second.activeProfile = profile; second.tab = tab;
  [runtime fixtureAddSaveWindow:second profile:profile tab:tab
    windowID:secondWindow profileID:secondProfile tabID:secondTab];
  __block NSInteger secondRevoked = 0, secondOffers = 0;
  XCTAssertTrue([runtime armPasswordSaveCaptureID:captureID windowID:windowID
    profileID:profileID tabID:tabID accountEpoch:accountEpoch
    onOffer:^(ARCPasswordSaveOffer *offer) {} onRevoke:^{ [first.eventTrace addObject:@"revoke"]; }]);
  XCTAssertTrue([runtime armPasswordSaveCaptureID:secondCapture windowID:secondWindow
    profileID:secondProfile tabID:secondTab accountEpoch:accountEpoch
    onOffer:^(ARCPasswordSaveOffer *offer) { ++secondOffers; } onRevoke:^{ ++secondRevoked; }]);
  XCTAssertTrue([runtime closeWindowID:windowID]);
  XCTAssertEqualObjects(first.eventTrace, (@[@"revoke", @"close"]));
  REQUIRE_CALLBACK(second.offerCallback);
  second.offerCallback([self offer]);
  XCTAssertEqual(secondRevoked, 0);
  XCTAssertEqual(secondOffers, 1);
  [runtime cancelPasswordSaveCaptureID:secondCapture];
  XCTAssertEqual(secondRevoked, 1);
}

- (void)testHostTabCloseRevokesBeforeNativeClose {
  SaveFakeWindow *window;
  ARCChromiumRuntime *runtime = [self runtimeWithWindow:&window version:VersionOne];
  NSMutableArray *trace = [NSMutableArray array];
  window.tab.eventTrace = trace;
  XCTAssertTrue([runtime armPasswordSaveCaptureID:captureID windowID:windowID
    profileID:profileID tabID:tabID accountEpoch:accountEpoch
    onOffer:^(ARCPasswordSaveOffer *offer) {} onRevoke:^{ [trace addObject:@"revoke"]; }]);
  [runtime closeTabID:tabID];
  XCTAssertEqualObjects(trace, (@[@"revoke", @"closeTab"]));
}

- (void)testHostClearActiveTabRevokesBeforeReturn {
  SaveFakeWindow *window;
  ARCChromiumRuntime *runtime = [self runtimeWithWindow:&window version:VersionOne];
  __block NSInteger revoked = 0;
  XCTAssertTrue([runtime armPasswordSaveCaptureID:captureID windowID:windowID
    profileID:profileID tabID:tabID accountEpoch:accountEpoch
    onOffer:^(ARCPasswordSaveOffer *offer) {} onRevoke:^{ ++revoked; }]);
  [runtime clearActiveTabInWindowID:windowID];
  XCTAssertEqual(revoked, 1);
}
@end
#undef REQUIRE_CALLBACK
