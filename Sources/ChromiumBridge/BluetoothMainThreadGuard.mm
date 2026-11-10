// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#import "include/ChromiumBridge.h"

#include <dlfcn.h>
#include <libproc.h>
#include <pthread.h>
#include <unistd.h>

#import <IOKit/IOReturn.h>
#import <objc/message.h>
#import <objc/runtime.h>

/// CoreBluetooth's allowed-always value. Kept numeric so this file does not link CoreBluetooth.
static const NSInteger kShaarBluetoothAuthorizationAllowedAlways = 3;

@interface NSObject (ShaarBluetoothCallThrough)
- (nullable id)initShaarOriginalWithDelegate:(nullable id)delegate;
- (int)shaarBluetoothOriginalStart;
- (int)shaarBluetoothOriginalStop;
- (void)shaarBluetoothOriginalClearFoundDevices;
- (nullable id)shaarBluetoothOriginalDefaultController;
- (nullable id)shaarBluetoothOriginalPairedDevices;
- (nullable id)shaarBluetoothOriginalRegisterForConnectNotifications:(nullable id)observer
                                                           selector:(SEL)selector;
- (nullable id)shaarBluetoothOriginalDeviceWithAddressString:(nullable NSString *)address;
@end

typedef pid_t (*ShaarResponsiblePID)(pid_t pid);

static pid_t ShaarResponsiblePIDFor(pid_t pid) {
  static ShaarResponsiblePID function = NULL;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    void *library = dlopen("/usr/lib/system/libquarantine.dylib", RTLD_LAZY);
    if (!library) return;
    function = (ShaarResponsiblePID)dlsym(
        library, "responsibility_get_pid_responsible_for_pid");
  });
  if (!function) return -1;
  return function(pid);
}

static BOOL gInquiryInitExchanged = NO;
static BOOL gInquiryStartExchanged = NO;
static BOOL gInquiryStopExchanged = NO;
static BOOL gInquiryClearExchanged = NO;
static BOOL gDefaultControllerExchanged = NO;
static BOOL gPairedDevicesExchanged = NO;
static BOOL gRegisterConnectExchanged = NO;
static BOOL gDeviceWithAddressExchanged = NO;

BOOL ShaarBluetoothMayCallIOBluetooth(
    BOOL onMainThread, NSInteger authorization, BOOL hasUsageDescription) {
  if (onMainThread) return NO;
  if (authorization != kShaarBluetoothAuthorizationAllowedAlways) return NO;
  if (!hasUsageDescription) return NO;
  return YES;
}

static BOOL ShaarReadUsageDescription(void) {
  pid_t responsible = ShaarResponsiblePIDFor(getpid());
  if (responsible <= 0) return NO;
  char path[PROC_PIDPATHINFO_MAXSIZE];
  int length = proc_pidpath(responsible, path, sizeof(path));
  if (length <= 0) return NO;
  NSString *executable = [[NSString alloc] initWithBytes:path
                                                   length:(NSUInteger)length
                                                 encoding:NSUTF8StringEncoding];
  if (!executable) return NO;
  NSURL *macOS = [[NSURL fileURLWithPath:executable] URLByDeletingLastPathComponent];
  NSURL *contents = [macOS URLByDeletingLastPathComponent];
  if (![macOS.lastPathComponent isEqualToString:@"MacOS"]) return NO;
  if (![contents.lastPathComponent isEqualToString:@"Contents"]) return NO;
  NSURL *plistURL = [contents URLByAppendingPathComponent:@"Info.plist"];
  NSDictionary *info = [NSDictionary dictionaryWithContentsOfURL:plistURL];
  NSString *usage = info[@"NSBluetoothAlwaysUsageDescription"];
  return [usage isKindOfClass:NSString.class] && usage.length > 0;
}

static BOOL ShaarHasUsageDescription(void) {
  static BOOL value = NO;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    value = ShaarReadUsageDescription();
  });
  return value;
}

static NSInteger ShaarBluetoothAuthorization(void) {
  Class manager = NSClassFromString(@"CBCentralManager");
  if (!manager || ![manager respondsToSelector:@selector(authorization)]) return 0;
  NSInteger (*getter)(id, SEL) = (NSInteger (*)(id, SEL))objc_msgSend;
  return getter(manager, @selector(authorization));
}

static BOOL ShaarBluetoothCallThroughAllowed(void) {
  BOOL onMainThread = pthread_main_np() != 0;
  return ShaarBluetoothMayCallIOBluetooth(
      onMainThread, ShaarBluetoothAuthorization(), ShaarHasUsageDescription());
}

static BOOL ShaarExchangeOwnedMethod(Class cls, SEL original, SEL added, IMP imp, BOOL instance) {
  if (!cls) return NO;
  Class owner = instance ? cls : object_getClass((id)cls);
  Method method = instance ? class_getInstanceMethod(cls, original)
                           : class_getClassMethod(cls, original);
  if (!method || !owner) return NO;
  Class superclass = class_getSuperclass(owner);
  Method inherited = superclass
      ? class_getInstanceMethod(superclass, original) : NULL;
  const char *types = method_getTypeEncoding(method);
  if (method == inherited) {
    class_addMethod(owner, original, imp, types);
    return NO;
  }
  if (!class_addMethod(owner, added, imp, types)) return NO;
  Method addedMethod = class_getInstanceMethod(owner, added);
  if (!addedMethod) return NO;
  method_exchangeImplementations(method, addedMethod);
  return YES;
}

static id ShaarInquiryInit(id self, SEL _cmd, id delegate) {
  if (!gInquiryInitExchanged || !ShaarBluetoothCallThroughAllowed()) return nil;
  return [self initShaarOriginalWithDelegate:delegate];
}

static int ShaarInquiryStart(id self, SEL _cmd) {
  if (!gInquiryStartExchanged || !ShaarBluetoothCallThroughAllowed()) return kIOReturnNotPermitted;
  return [self shaarBluetoothOriginalStart];
}

static int ShaarInquiryStop(id self, SEL _cmd) {
  if (!gInquiryStopExchanged || !ShaarBluetoothCallThroughAllowed()) return kIOReturnNotPermitted;
  return [self shaarBluetoothOriginalStop];
}

static void ShaarInquiryClear(id self, SEL _cmd) {
  if (!gInquiryClearExchanged || !ShaarBluetoothCallThroughAllowed()) return;
  [self shaarBluetoothOriginalClearFoundDevices];
}

static id ShaarDefaultController(id self, SEL _cmd) {
  if (!gDefaultControllerExchanged || !ShaarBluetoothCallThroughAllowed()) return nil;
  return [self shaarBluetoothOriginalDefaultController];
}

static id ShaarPairedDevices(id self, SEL _cmd) {
  if (!gPairedDevicesExchanged || !ShaarBluetoothCallThroughAllowed()) return nil;
  return [self shaarBluetoothOriginalPairedDevices];
}

static id ShaarRegisterConnect(id self, SEL _cmd, id observer, SEL selector) {
  if (!gRegisterConnectExchanged || !ShaarBluetoothCallThroughAllowed()) return nil;
  return [self shaarBluetoothOriginalRegisterForConnectNotifications:observer selector:selector];
}

static id ShaarDeviceWithAddress(id self, SEL _cmd, NSString *address) {
  if (!gDeviceWithAddressExchanged || !ShaarBluetoothCallThroughAllowed()) return nil;
  return [self shaarBluetoothOriginalDeviceWithAddressString:address];
}

static void ShaarInstallBluetoothSwizzles(void) {
  dlopen("/System/Library/Frameworks/CoreBluetooth.framework/CoreBluetooth", RTLD_LAZY);
  dlopen("/System/Library/Frameworks/IOBluetooth.framework/IOBluetooth", RTLD_LAZY);
  Class inquiry = NSClassFromString(@"IOBluetoothDeviceInquiry");
  gInquiryInitExchanged = ShaarExchangeOwnedMethod(
      inquiry, @selector(initWithDelegate:),
      @selector(initShaarOriginalWithDelegate:), (IMP)ShaarInquiryInit, YES);
  gInquiryStartExchanged = ShaarExchangeOwnedMethod(
      inquiry, @selector(start), @selector(shaarBluetoothOriginalStart),
      (IMP)ShaarInquiryStart, YES);
  gInquiryStopExchanged = ShaarExchangeOwnedMethod(
      inquiry, @selector(stop), @selector(shaarBluetoothOriginalStop),
      (IMP)ShaarInquiryStop, YES);
  gInquiryClearExchanged = ShaarExchangeOwnedMethod(
      inquiry, @selector(clearFoundDevices),
      @selector(shaarBluetoothOriginalClearFoundDevices), (IMP)ShaarInquiryClear, YES);
  Class controller = NSClassFromString(@"IOBluetoothHostController");
  gDefaultControllerExchanged = ShaarExchangeOwnedMethod(
      controller, @selector(defaultController),
      @selector(shaarBluetoothOriginalDefaultController), (IMP)ShaarDefaultController, NO);
  Class device = NSClassFromString(@"IOBluetoothDevice");
  gPairedDevicesExchanged = ShaarExchangeOwnedMethod(
      device, @selector(pairedDevices), @selector(shaarBluetoothOriginalPairedDevices),
      (IMP)ShaarPairedDevices, NO);
  gRegisterConnectExchanged = ShaarExchangeOwnedMethod(
      device, @selector(registerForConnectNotifications:selector:),
      @selector(shaarBluetoothOriginalRegisterForConnectNotifications:selector:),
      (IMP)ShaarRegisterConnect, NO);
  gDeviceWithAddressExchanged = ShaarExchangeOwnedMethod(
      device, @selector(deviceWithAddressString:),
      @selector(shaarBluetoothOriginalDeviceWithAddressString:),
      (IMP)ShaarDeviceWithAddress, NO);
}

void ShaarInstallBluetoothMainThreadGuard(void) {
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    ShaarInstallBluetoothSwizzles();
  });
}

BOOL ShaarBluetoothIOIsBlocked(void) {
  ShaarInstallBluetoothMainThreadGuard();
  return !ShaarBluetoothMayCallIOBluetooth(
      NO, ShaarBluetoothAuthorization(), ShaarHasUsageDescription());
}
