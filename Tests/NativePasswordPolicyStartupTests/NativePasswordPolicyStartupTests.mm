#import <XCTest/XCTest.h>

// Compile the production bridge into this isolated fixture, never a second model.
// The fixture exercises the arbiter only; it never starts Chromium or creates a window.
#import "../../Sources/ChromiumBridge/ChromiumBridge.mm"
#include <chrono>
#include <condition_variable>
#include <thread>

namespace {
int ownerOne;
int ownerTwo;
int libraryOne;
int libraryTwo;
int configureCalls;
uint32_t configuredVersion;
NativePasswordStartupArbiter *reentrantArbiter;
bool nestedSelection;
bool nestedStart;
std::mutex blockingMutex;
std::condition_variable blockingCondition;
bool configureEntered;
bool configureReleased;
bool configureTimedOut;

int ConfigureSuccess(uint32_t version) {
  ++configureCalls;
  configuredVersion = version;
  return 1;
}

int ConfigureFailure(uint32_t version) {
  ++configureCalls;
  configuredVersion = version;
  return 0;
}

int ConfigureUnexpected(uint32_t version) {
  ++configureCalls;
  configuredVersion = version;
  return 2;
}

int ConfigureReentrant(uint32_t version) {
  ++configureCalls;
  configuredVersion = version;
  nestedSelection = reentrantArbiter->select(&ownerTwo, &libraryOne, ConfigureSuccess, true);
  nestedStart = reentrantArbiter->begin(&ownerOne, &libraryOne);
  return 1;
}

int ConfigureBlocking(uint32_t version) {
  std::unique_lock<std::mutex> lock(blockingMutex);
  configuredVersion = version;
  configureEntered = true;
  blockingCondition.notify_all();
  configureTimedOut = !blockingCondition.wait_for(lock, std::chrono::seconds(5), [] {
    return configureReleased;
  });
  return configureTimedOut ? 0 : 1;
}
}  // namespace

@interface NativePasswordPolicyStartupTests : XCTestCase
@end

@interface StartupFakeWindow : NSObject
@property(nonatomic, readonly) NSWindow *window;
@end
@implementation StartupFakeWindow
- (NSWindow *)window { return (NSWindow *)self; }
- (void)requestPasswordFillForTab:(ArdiaCoreTab *)tab completion:(void (^)(id))completion {}
- (void)fillPasswordRequest:(id)request username:(NSString *)username password:(NSString *)password
  completion:(void (^)(BOOL))completion {}
- (void)cancelPasswordRequest:(id)request {}
@end

@implementation NativePasswordPolicyStartupTests

- (void)setUp {
  [super setUp];
  configureCalls = 0;
  configuredVersion = 0;
  nestedSelection = false;
  nestedStart = false;
  reentrantArbiter = nullptr;
  configureEntered = false;
  configureReleased = false;
  configureTimedOut = false;
}

- (void)testSelectionPrecedesOneStartAndBindsOwnerAndLibrary {
  NativePasswordStartupArbiter arbiter;
  XCTAssertTrue(arbiter.select(&ownerOne, &libraryOne, ConfigureSuccess, false));
  XCTAssertEqual(configureCalls, 1);
  XCTAssertEqual(configuredVersion, 1u);
  XCTAssertFalse(arbiter.nativeAvailable(&ownerOne, &libraryOne));
  XCTAssertFalse(arbiter.begin(&ownerTwo, &libraryOne));
  XCTAssertFalse(arbiter.begin(&ownerOne, &libraryTwo));
  XCTAssertTrue(arbiter.begin(&ownerOne, &libraryOne));
  XCTAssertTrue(arbiter.nativeAvailable(&ownerOne, &libraryOne));
  XCTAssertFalse(arbiter.nativeAvailable(&ownerTwo, &libraryOne));
  XCTAssertFalse(arbiter.nativeAvailable(&ownerOne, &libraryTwo));
  XCTAssertFalse(arbiter.begin(&ownerOne, &libraryOne));
  XCTAssertFalse(arbiter.select(&ownerOne, &libraryOne, ConfigureSuccess, false));
  XCTAssertEqual(configureCalls, 1);
}

- (void)testReleaseRejectsMissingAndNonSuccessWithoutRetry {
  NativePasswordStartupArbiter missing;
  XCTAssertFalse(missing.select(&ownerOne, &libraryOne, nullptr, false));
  XCTAssertFalse(missing.begin(&ownerOne, &libraryOne));
  XCTAssertFalse(missing.select(&ownerOne, &libraryOne, ConfigureSuccess, false));
  NativePasswordStartupArbiter failure;
  XCTAssertFalse(failure.select(&ownerOne, &libraryOne, ConfigureFailure, false));
  XCTAssertEqual(configureCalls, 1);
  XCTAssertFalse(failure.begin(&ownerOne, &libraryOne));
  XCTAssertFalse(failure.nativeAvailable(&ownerOne, &libraryOne));
  NativePasswordStartupArbiter unexpected;
  XCTAssertFalse(unexpected.select(&ownerOne, &libraryOne, ConfigureUnexpected, false));
  XCTAssertEqual(configureCalls, 2);
  XCTAssertFalse(unexpected.begin(&ownerOne, &libraryOne));
}

- (void)testDebugAllowsBrowsingButNeverNativeCapabilityOnFailure {
  NativePasswordStartupArbiter missing;
  XCTAssertTrue(missing.select(&ownerOne, &libraryOne, nullptr, true));
  XCTAssertTrue(missing.begin(&ownerOne, &libraryOne));
  XCTAssertFalse(missing.nativeAvailable(&ownerOne, &libraryOne));
  XCTAssertFalse(missing.select(&ownerTwo, &libraryOne, ConfigureSuccess, true));
  NativePasswordStartupArbiter failed;
  XCTAssertTrue(failed.select(&ownerOne, &libraryOne, ConfigureFailure, true));
  XCTAssertTrue(failed.begin(&ownerOne, &libraryOne));
  XCTAssertFalse(failed.nativeAvailable(&ownerOne, &libraryOne));
  XCTAssertEqual(configureCalls, 1);
}

- (void)testBuildModeControlsUnavailablePolicy {
#if defined(DEBUG) && DEBUG
  XCTAssertTrue(NativePasswordPolicyAllowsUnavailable());
#else
  XCTAssertFalse(NativePasswordPolicyAllowsUnavailable());
#endif
  NativePasswordStartupArbiter arbiter;
  const bool admitted = arbiter.select(&ownerOne, &libraryOne, nullptr,
                                       NativePasswordPolicyAllowsUnavailable());
  XCTAssertEqual(admitted, NativePasswordPolicyAllowsUnavailable());
  if (admitted) XCTAssertTrue(arbiter.begin(&ownerOne, &libraryOne));
  XCTAssertFalse(arbiter.nativeAvailable(&ownerOne, &libraryOne));
}

- (void)testReentrantSelectionCannotStartOrReconfigure {
  NativePasswordStartupArbiter arbiter;
  reentrantArbiter = &arbiter;
  XCTAssertTrue(arbiter.select(&ownerOne, &libraryOne, ConfigureReentrant, false));
  XCTAssertFalse(nestedSelection);
  XCTAssertFalse(nestedStart);
  XCTAssertEqual(configureCalls, 1);
  XCTAssertTrue(arbiter.begin(&ownerOne, &libraryOne));
  XCTAssertTrue(arbiter.nativeAvailable(&ownerOne, &libraryOne));
  reentrantArbiter = nullptr;
}

- (void)testConcurrentSelectionCannotStartOrReconfigure {
  NativePasswordStartupArbiter arbiter;
  bool selected = false;
  std::thread worker([&] {
    selected = arbiter.select(&ownerOne, &libraryOne, ConfigureBlocking, false);
  });
  bool entered;
  {
    std::unique_lock<std::mutex> lock(blockingMutex);
    entered = blockingCondition.wait_for(lock, std::chrono::seconds(3), [] {
      return configureEntered;
    });
  }
  const bool competing = arbiter.select(&ownerTwo, &libraryOne, ConfigureSuccess, true);
  const bool premature = arbiter.begin(&ownerOne, &libraryOne);
  {
    std::lock_guard<std::mutex> lock(blockingMutex);
    configureReleased = true;
    blockingCondition.notify_all();
  }
  worker.join();
  XCTAssertTrue(entered);
  XCTAssertFalse(configureTimedOut);
  XCTAssertTrue(selected);
  XCTAssertFalse(competing);
  XCTAssertFalse(premature);
  XCTAssertEqual(configureCalls, 0);
  XCTAssertEqual(configuredVersion, 1u);
  XCTAssertTrue(arbiter.begin(&ownerOne, &libraryOne));
}

- (void)testTwoWindowsUseSameRuntimeCapability {
  XCTAssertTrue(NSThread.isMainThread);
  NSString *first = @"43D0A5F6-B639-4629-B34D-413193A0481A";
  NSString *second = @"FCF7739F-2E2A-4D70-BB86-A04BD8FD026C";
  ARCChromiumRuntime *runtime = [ARCChromiumRuntime new];
  [runtime fixtureSetLibrary:&libraryOne windows:@{
    first: [StartupFakeWindow new], second: [StartupFakeWindow new]
  }];
  const void *owner = (__bridge const void *)runtime;
  XCTAssertTrue(PasswordStartup().select(owner, &libraryOne, ConfigureSuccess, false));
  XCTAssertFalse([runtime supportsPasswordFillInWindowID:first]);
  XCTAssertTrue(PasswordStartup().begin(owner, &libraryOne));
  XCTAssertTrue([runtime supportsPasswordFillInWindowID:first]);
  XCTAssertTrue([runtime supportsPasswordFillInWindowID:second]);
  XCTAssertFalse([runtime supportsPasswordFillInWindowID:@"invalid"]);
  XCTAssertEqual(configureCalls, 1);
}

- (void)testTwoWindowsRemainUnavailableWithoutPolicy {
  XCTAssertTrue(NSThread.isMainThread);
  NSString *first = @"43D0A5F6-B639-4629-B34D-413193A0481A";
  NSString *second = @"FCF7739F-2E2A-4D70-BB86-A04BD8FD026C";
  ARCChromiumRuntime *runtime = [ARCChromiumRuntime new];
  [runtime fixtureSetLibrary:&libraryOne windows:@{
    first: [StartupFakeWindow new], second: [StartupFakeWindow new]
  }];
  const void *owner = (__bridge const void *)runtime;
  XCTAssertTrue(PasswordStartup().select(owner, &libraryOne, nullptr, true));
  XCTAssertTrue(PasswordStartup().begin(owner, &libraryOne));
  XCTAssertFalse([runtime supportsPasswordFillInWindowID:first]);
  XCTAssertFalse([runtime supportsPasswordFillInWindowID:second]);
  XCTAssertEqual(configureCalls, 0);
}

@end
