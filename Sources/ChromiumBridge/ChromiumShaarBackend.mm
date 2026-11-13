// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#import "include/ChromiumBridge.h"
#import "include/ChromiumShaarHttpsOnly.h"
#import "ChromiumRuntimeInternal.h"
#import "ChromiumLocalState.h"
#import "ChromiumHttpsOnly.h"
#import "ChromiumShaarExtensionsInternal.h"
#import "ChromiumShaarPrivateSupport.h"
#import "ChromiumShaarFeatureTransport.h"
#import "ChromiumMediaSession.h"
#import "ChromiumShaarActivation.h"


#import <Security/Security.h>
#import <CoreFoundation/CoreFoundation.h>

#include <dlfcn.h>
#include <climits>
#include <cmath>
#include <cstdlib>
#include <cstring>

#include "../../ThirdParty/ChromiumEngine/layer/chrome/browser/shaar/public/shaar_engine.h"

// Optional for older engine builds that do not emit tab "opened" events.
extern "C" shaar_error_code shaar_tab_find(
    shaar_engine *engine, shaar_bytes window_id, shaar_bytes tab_id,
    shaar_tab **out, shaar_error *error);

// Patch 0072. shaar.28 does not export this; a null pointer skips the reply.
typedef shaar_error_code (*ShaarShareReplyFunction)(const char *request_id, int shared);
// Patch 0073. Older engine builds do not export this; a null pointer skips the reply.
typedef shaar_error_code (*ShaarPrintReplyFunction)(const char *request_id, int accepted);

namespace {

NSError *ShaarError(NSString *message) {
  return [NSError errorWithDomain:@"org.arcusis.shaar.engine" code:1
                         userInfo:@{NSLocalizedDescriptionKey: message}];
}

NSError *ShaarStatusError(NSString *message, shaar_error_code status) {
  return [NSError errorWithDomain:@"org.arcusis.shaar.engine" code:status
                         userInfo:@{NSLocalizedDescriptionKey: message}];
}

BOOL ShaarPrintField(id value, NSUInteger maxUTF8Length, BOOL required) {
  if (![value isKindOfClass:NSString.class]) return !required && value == nil;
  NSData *data = [(NSString *)value dataUsingEncoding:NSUTF8StringEncoding];
  return data && data.length <= maxUTF8Length && (!required || data.length > 0);
}

shaar_bytes Bytes(NSString *value) {
  const char *text = value.UTF8String;
  return {text, text ? std::strlen(text) : 0};
}

NSString *String(shaar_bytes bytes) {
  if (!bytes.data || !bytes.size) return @"";
  return [[NSString alloc] initWithBytes:bytes.data length:bytes.size
                               encoding:NSUTF8StringEncoding] ?: @"";
}

shaar_error EmptyError() {
  shaar_error error = {};
  error.size = sizeof(error);
  return error;
}

void IgnoreReply(void *, const shaar_result *) {}

// Camera and microphone keep the websiteMedia* names. Later prompts use
// websitePermission* with the same payload, so one sheet can answer both.
BOOL ShaarWebsitePermissionEvent(NSString *kind, BOOL *dismissed) {
  if ([kind isEqualToString:@"websiteMediaDismissed"] ||
      [kind isEqualToString:@"websitePermissionDismissed"]) {
    *dismissed = YES;
    return YES;
  }
  if ([kind isEqualToString:@"websiteMediaRequested"] ||
      [kind isEqualToString:@"websitePermissionRequested"]) {
    *dismissed = NO;
    return YES;
  }
  return NO;
}

NSInteger HistoryQueryVisitsPerURL(NSInteger limit) {
  const NSInteger maximumVisitsPerURL = 50;
  const NSInteger pageHeadroom = 5000;
  return MIN(maximumVisitsPerURL, MAX(2, pageHeadroom / limit + 1));
}

// Patch 0069 on #290. The shipping header stays at minor 8. This decision is
// submitted only when the loaded engine reports minor 13 or newer.
static const uint32_t kShaarDeviceChooserABIMinor = 13;
static const shaar_operation kShaarDeviceChooserDecision = (shaar_operation)1600;
static const shaar_operation kShaarHTTPCredentialsReply = SHAAR_OP_HTTP_AUTH_CREDENTIALS_REPLY;

static BOOL ShaarDeviceChooserKind(NSString *kind, BOOL *dismissed, BOOL *updated) {
  if ([kind isEqualToString:@"deviceChooserDismissed"]) {
    *dismissed = YES;
    *updated = NO;
    return YES;
  }
  if ([kind isEqualToString:@"deviceChooserUpdated"]) {
    *dismissed = NO;
    *updated = YES;
    return YES;
  }
  if ([kind isEqualToString:@"deviceChooserRequested"]) {
    *dismissed = NO;
    *updated = NO;
    return YES;
  }
  return NO;
}

static BOOL ShaarDeviceChooserID(NSString *value) {
  if (![value isKindOfClass:NSString.class] || value.length < 1 || value.length > 64) return NO;
  NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:
      @"0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-"];
  return [value rangeOfCharacterFromSet:allowed.invertedSet].location == NSNotFound;
}

struct Symbols {
  decltype(&shaar_abi_minor) abi_minor = nullptr;
  decltype(&shaar_engine_create) create = nullptr;
  decltype(&shaar_engine_run) run = nullptr;
  decltype(&shaar_engine_request_quit) request_quit = nullptr;
  decltype(&shaar_engine_release) release = nullptr;
  decltype(&shaar_profile_open) profile_open = nullptr;
  decltype(&shaar_window_open) window_open = nullptr;
  decltype(&shaar_window_close) window_close = nullptr;
  decltype(&shaar_window_host_view) window_host_view = nullptr;
  decltype(&shaar_window_host_resize) window_host_resize = nullptr;
  decltype(&shaar_window_native_window) window_native_window = nullptr;
  decltype(&shaar_tab_open) tab_open = nullptr;
  decltype(&shaar_tab_find) tab_find = nullptr;
  decltype(&shaar_tab_print) tab_print = nullptr;
  decltype(&shaar_tab_close) tab_close = nullptr;
  decltype(&shaar_tab_favicon_png) tab_favicon_png = nullptr;
  decltype(&shaar_tab_host_view) tab_host_view = nullptr;
  decltype(&shaar_tab_view_attach) tab_view_attach = nullptr;
  decltype(&shaar_tab_view_detach) tab_view_detach = nullptr;
  decltype(&shaar_tab_view_focus) tab_view_focus = nullptr;
  decltype(&shaar_submit) submit = nullptr;

  bool Load(void *library) {
#define SHAAR_LOAD(field, symbol) \
  field = reinterpret_cast<decltype(field)>(dlsym(library, "shaar_" #symbol))
    SHAAR_LOAD(abi_minor, abi_minor);
    SHAAR_LOAD(create, engine_create);
    SHAAR_LOAD(run, engine_run);
    SHAAR_LOAD(request_quit, engine_request_quit);
    SHAAR_LOAD(release, engine_release);
    SHAAR_LOAD(profile_open, profile_open);
    SHAAR_LOAD(window_open, window_open);
    SHAAR_LOAD(window_close, window_close);
    SHAAR_LOAD(window_host_view, window_host_view);
    SHAAR_LOAD(window_host_resize, window_host_resize);
    SHAAR_LOAD(window_native_window, window_native_window);
    SHAAR_LOAD(tab_open, tab_open);
    SHAAR_LOAD(tab_print, tab_print);
    SHAAR_LOAD(tab_close, tab_close);
    SHAAR_LOAD(tab_favicon_png, tab_favicon_png);
    SHAAR_LOAD(tab_host_view, tab_host_view);
    SHAAR_LOAD(tab_view_attach, tab_view_attach);
    SHAAR_LOAD(tab_view_detach, tab_view_detach);
    SHAAR_LOAD(tab_view_focus, tab_view_focus);
    SHAAR_LOAD(submit, submit);
#undef SHAAR_LOAD
    return abi_minor && create && run && request_quit && release && profile_open &&
           window_open && window_close && window_host_view && window_host_resize &&
           window_native_window && tab_open && tab_close && tab_favicon_png && tab_host_view &&
           tab_view_attach && tab_view_detach && tab_view_focus && submit;
  }
};

}  // namespace

@interface ARCShaarRuntime () {
  void *_shaarLibrary;
  shaar_engine *_shaarEngine;
  Symbols _symbols;
  NSString *_shaarPrimaryWindowID;
  NSMutableDictionary<NSString *, NSValue *> *_shaarProfiles;
  NSMutableDictionary<NSString *, NSMutableArray *> *_shaarProfileWaiters;
  NSMutableDictionary<NSString *, NSValue *> *_shaarWindows;
  NSMutableDictionary<NSString *, NSValue *> *_shaarTabs;
  NSMutableDictionary<NSString *, NSString *> *_shaarTabWindows;
  NSMutableDictionary<NSString *, NSString *> *_shaarTabProfiles;
  NSMutableDictionary<NSString *, NSString *> *_shaarSelectedTabs;
  NSMutableDictionary<NSString *, id> *_hostResizeObservers;
  NSMutableDictionary<NSString *, id> *_hostCloseObservers;
  NSMutableDictionary<NSString *, NSValue *> *_hostSizes;
  NSMutableDictionary<NSString *, NSString *> *_shaarFindTokens;
  NSMutableDictionary<NSString *, NSString *> *_shaarFindRequests;
  NSMutableDictionary<NSString *, NSString *> *_shaarMediaRequests;
  NSMutableDictionary<NSString *, NSString *> *_shaarCaptureRequests;
  NSMutableDictionary<NSString *, NSString *> *_shaarDeviceChooserRequests;
  NSMutableDictionary<NSString *, NSString *> *_shaarHTTPAuthRequests;
  NSMutableDictionary<NSString *, NSString *> *_shaarShareRequests;
  ShaarShareReplyFunction _shaarShareReply;
  NSMutableDictionary<NSString *, NSDictionary *> *_shaarInstallRequests;
  NSMutableDictionary<NSString *, NSString *> *_shaarPrintRequests;
  NSMutableDictionary<NSString *, NSString *> *_shaarJavaScriptDialogRequests;
  ShaarPrintReplyFunction _shaarPrintReply;
  NSMutableDictionary<NSString *, NSString *> *_shaarSavePrompts;
  uint64_t _nextRequestID;
  BOOL _shaarQuitting;
  BOOL _shaarTesting;
  BOOL _shaarMediaConsentAvailable;
  BOOL _shaarDesktopCaptureAvailable;
  BOOL _shaarDeviceChooserAvailable;
  BOOL _shaarWebShareAvailable;
  BOOL _shaarPrintAvailable;
  BOOL _shaarJavaScriptDialogsAvailable;
  BOOL _shaarSavePromptsAvailable;
  NSString *_shaarStartupNotice;
  NSURL *_shaarUserDataDirectory;
  NSMutableDictionary<NSString *, NSNumber *> *_shaarHttpsOnly;
  NSMutableDictionary<NSString *, NSArray<NSString *> *> *_shaarProfileFilesBeforeOpen;
}
- (void)receiveEvent:(const shaar_event *)event;
- (void)receiveDesktopCaptureRequest:(const shaar_event *)event
                             payload:(NSDictionary *)payload
                               tabID:(NSString *)tabID
                           profileID:(NSString *)profileID;
- (void)receiveDesktopCaptureDismissal:(NSDictionary *)payload tabID:(NSString *)tabID;
- (void)receiveWebShareRequest:(const shaar_event *)event
                       payload:(NSDictionary *)payload
                         tabID:(NSString *)tabID
                     profileID:(NSString *)profileID;
- (void)receiveExtensionInstallEvent:(const shaar_event *)event
                             payload:(NSDictionary *)payload
                           profileID:(NSString *)profileID
                               tabID:(NSString *)tabID;
- (void)cancelExtensionInstallRequestsForTabID:(NSString *)tabID;
- (BOOL)shaarExtensionIDIsAcceptable:(NSString *)extensionID;
- (BOOL)shaarInstallList:(id)value maxCount:(NSUInteger)maxCount maxItem:(NSUInteger)maxItem;
- (BOOL)shaarSubmitExtensionOperation:(shaar_operation)operation
                           profileID:(NSString *)profileID
                               tabID:(NSString *)tabID
                  allowsProfileOnly:(BOOL)allowsProfileOnly
                            payload:(NSDictionary *)payload
                          completion:(void (^)(NSString *, shaar_error_code))completion
                            syncCode:(shaar_error_code *)syncCode;
- (void)receivePrintRequest:(const shaar_event *)event
                    payload:(NSDictionary *)payload
                      tabID:(NSString *)tabID
                  profileID:(NSString *)profileID;
- (void)receivePrivatePrintRequest:(NSDictionary *)payload
                         contextID:(NSString *)contextID
                         profileID:(NSString *)profileID
                          windowID:(NSString *)windowID
                            tabID:(NSString *)tabID;
- (void)adoptOpenedTabFromEvent:(const shaar_event *)event
                        payload:(NSDictionary *)payload
                      profileID:(NSString *)profileID;
- (BOOL)submitTabID:(NSString *)tabID operation:(shaar_operation)operation
            payload:(NSDictionary *)payload;
- (void)submitTabID:(NSString *)tabID operation:(shaar_operation)operation
            payload:(NSDictionary *)payload
         completion:(void (^)(NSDictionary *, NSError *))completion;
- (BOOL)submitWindowID:(NSString *)windowID profileID:(NSString *)profileID
             operation:(shaar_operation)operation payload:(NSDictionary *)payload;
- (void)finishProfileLoadID:(NSString *)profileID error:(NSError *)error;
- (void)finishWindowID:(NSString *)windowID;
- (void)submitProfileID:(NSString *)profileID operation:(shaar_operation)operation
                payload:(NSDictionary *)payload
             completion:(void (^)(NSDictionary *, NSError *))completion;
@end

#include "ChromiumShaarFeatureTransport.inc"

static const shaar_operation kShaarOpTabDiscard = (shaar_operation)208;
static const shaar_operation kShaarOpTabFreeze = (shaar_operation)209;
static const shaar_operation kShaarOpTabWake = (shaar_operation)210;
static const shaar_operation kShaarOpTabLifecycleGet = (shaar_operation)211;

static void ShaarFinishOnMain(void (^completion)(BOOL), BOOL accepted) {
  if (!completion) return;
  if (NSThread.isMainThread) completion(accepted);
  else dispatch_async(dispatch_get_main_queue(), ^{ completion(accepted); });
}

static BOOL ShaarLifecycleAccepted(NSDictionary *reply, NSError *error,
                                   NSArray<NSString *> *states) {
  if (error) return NO;
  NSString *state = [reply[@"state"] isKindOfClass:NSString.class] ? reply[@"state"] : @"";
  return [states containsObject:state];
}

/// A failed submit, including INVALID_ARGUMENT and UNSUPPORTED_CAPABILITY, is not a lifecycle.
static BOOL ShaarLifecycleProbeCapable(NSDictionary *reply, NSError *error) {
  if (error || [reply[@"error"] isKindOfClass:NSString.class] ||
      [reply[@"error"] isKindOfClass:NSNumber.class]) return NO;
  NSString *state = [reply[@"state"] isKindOfClass:NSString.class] ? reply[@"state"] : @"";
  return [@[@"active", @"frozen", @"discarded"] containsObject:state];
}

// Patch 0066. The pinned engine reports a lower minor and never emits this event.
static const uint32_t kShaarSavePromptABIMinor = 12;

static BOOL ShaarScalarIsFormatOrBidi(UTF32Char scalar) {
  if (scalar == 0x00AD || scalar == 0x061C || scalar == 0x06DD || scalar == 0x070F ||
      scalar == 0x08E2 || scalar == 0x180E || scalar == 0xFEFF || scalar == 0x110BD ||
      scalar == 0x110CD || scalar == 0xE0001)
    return YES;
  if ((scalar >= 0x0600 && scalar <= 0x0605) || (scalar >= 0x0890 && scalar <= 0x0891) ||
      (scalar >= 0x200B && scalar <= 0x200F) || (scalar >= 0x202A && scalar <= 0x202E) ||
      (scalar >= 0x2060 && scalar <= 0x2064) || (scalar >= 0x2066 && scalar <= 0x206F) ||
      (scalar >= 0xFFF9 && scalar <= 0xFFFB) || (scalar >= 0x13430 && scalar <= 0x1343F) ||
      (scalar >= 0x1BCA0 && scalar <= 0x1BCA3) || (scalar >= 0x1D173 && scalar <= 0x1D17A) ||
      (scalar >= 0xE0020 && scalar <= 0xE007F))
    return YES;
  return NO;
}

static BOOL ShaarTextUsesFormatOrBidi(NSString *text) {
  NSUInteger index = 0;
  while (index < text.length) {
    const unichar unit = [text characterAtIndex:index];
    UTF32Char scalar = unit;
    if (unit >= 0xD800 && unit <= 0xDBFF) {
      if (index + 1 >= text.length) return YES;
      const unichar trail = [text characterAtIndex:index + 1];
      if (trail < 0xDC00 || trail > 0xDFFF) return YES;
      scalar = 0x10000 + ((unit - 0xD800) << 10) + (trail - 0xDC00);
      index += 2;
    } else if (unit >= 0xDC00 && unit <= 0xDFFF) {
      return YES;
    } else {
      index += 1;
    }
    if (ShaarScalarIsFormatOrBidi(scalar)) return YES;
  }
  return NO;
}

static BOOL ShaarPlainText(id value, NSUInteger maxLength) {
  if (![value isKindOfClass:NSString.class]) return NO;
  NSString *text = value;
  if (!text.length || text.length > maxLength) return NO;
  if ([text rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound)
    return NO;
  return !ShaarTextUsesFormatOrBidi(text);
}

static BOOL ShaarSavePromptRequestIsValid(NSDictionary *payload) {
  NSSet *allowed = [NSSet setWithArray:@[
    @"schemaVersion", @"kind", @"id", @"prompt", @"origin", @"pageURL", @"detail", @"update"]];
  if (![[NSSet setWithArray:payload.allKeys] isEqualToSet:allowed]) return NO;
  if (![payload[@"schemaVersion"] isEqual:@1]) return NO;
  if (![payload[@"kind"] isEqualToString:@"savePromptRequested"]) return NO;
  if (!ShaarPlainText(payload[@"id"], 128)) return NO;
  NSString *prompt = payload[@"prompt"];
  if (![prompt isKindOfClass:NSString.class]) return NO;
  if (![prompt isEqualToString:@"password"] && ![prompt isEqualToString:@"card"] &&
      ![prompt isEqualToString:@"address"]) return NO;
  if (!ShaarPlainText(payload[@"origin"], 256) || !ShaarPlainText(payload[@"pageURL"], 2048))
    return NO;
  NSString *detail = payload[@"detail"];
  if (![detail isKindOfClass:NSString.class] || detail.length > 120) return NO;
  if ([detail rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound)
    return NO;
  if (ShaarTextUsesFormatOrBidi(detail)) return NO;
  if (![payload[@"update"] isKindOfClass:NSNumber.class]) return NO;
  return ![payload[@"update"] boolValue] || [prompt isEqualToString:@"password"];
}

static BOOL ShaarSavePromptDismissIsValid(NSDictionary *payload) {
  NSSet *allowed = [NSSet setWithArray:@[@"schemaVersion", @"kind", @"id"]];
  if (![[NSSet setWithArray:payload.allKeys] isEqualToSet:allowed]) return NO;
  if (![payload[@"schemaVersion"] isEqual:@1]) return NO;
  if (![payload[@"kind"] isEqualToString:@"savePromptDismissed"]) return NO;
  return ShaarPlainText(payload[@"id"], 128);
}

static void ShaarEventCallback(void *context, const shaar_event *event) {
  ARCPerformShaarEventCallback(^{
    [(__bridge ARCShaarRuntime *)context receiveEvent:event];
  });
}

static BOOL ARCInfoBool(id value) {
  return [value respondsToSelector:@selector(boolValue)] && [value boolValue];
}

static BOOL ARCReadJSONInteger(id value, int *result) {
  if (![value isKindOfClass:NSNumber.class] ||
      CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID()) return NO;
  double number = [value doubleValue];
  if (!std::isfinite(number) || std::trunc(number) != number ||
      number < INT_MIN || number > INT_MAX) return NO;
  *result = static_cast<int>(number);
  return YES;
}

static BOOL ARCEnvironmentRequestsMockKeychain(void) {
  const char *value = getenv("SHAAR_MOCK_KEYCHAIN");
  if (!value) return NO;
  if (std::strcmp(value, "1") == 0) return YES;
  if (std::strcmp(value, "true") == 0 || std::strcmp(value, "TRUE") == 0) return YES;
  if (std::strcmp(value, "yes") == 0 || std::strcmp(value, "YES") == 0) return YES;
  return NO;
}

static BOOL ARCSignatureIsAdHoc(CFDictionaryRef information) {
  CFTypeRef flags = CFDictionaryGetValue(information, kSecCodeInfoFlags);
  int32_t value = 0;
  if (!flags || CFGetTypeID(flags) != CFNumberGetTypeID()) return NO;
  if (!CFNumberGetValue((CFNumberRef)flags, kCFNumberSInt32Type, &value)) return NO;
  if ((value & kSecCodeSignatureAdhoc) == 0) return NO;
  CFTypeRef certificates = CFDictionaryGetValue(information, kSecCodeInfoCertificates);
  if (certificates && CFGetTypeID(certificates) == CFArrayGetTypeID()
      && CFArrayGetCount((CFArrayRef)certificates) > 0) {
    return NO;
  }
  CFTypeRef team = CFDictionaryGetValue(information, kSecCodeInfoTeamIdentifier);
  if (team && CFGetTypeID(team) == CFStringGetTypeID() && CFStringGetLength((CFStringRef)team) > 0) {
    return NO;
  }
  return YES;
}

BOOL ARCMockKeychainEnabled(BOOL requested, BOOL adHocSigned) {
  return requested && adHocSigned;
}

BOOL ARCBundleIsAdHocSigned(NSBundle *bundle) {
  NSURL *url = bundle.bundleURL;
  if (!url.isFileURL) return NO;
  SecStaticCodeRef code = NULL;
  OSStatus status = SecStaticCodeCreateWithPath((__bridge CFURLRef)url, kSecCSDefaultFlags, &code);
  if (status != errSecSuccess || !code) return NO;
  CFDictionaryRef information = NULL;
  status = SecCodeCopySigningInformation(code, kSecCSSigningInformation, &information);
  CFRelease(code);
  if (status != errSecSuccess || !information) return NO;
  BOOL adHoc = ARCSignatureIsAdHoc(information);
  CFRelease(information);
  return adHoc;
}

@implementation ARCShaarRuntime

- (NSString *)startupNotice { return _shaarStartupNotice; }

- (instancetype)initWithFrameworkURL:(NSURL *)url error:(NSError **)error {
  if (!(self = [super init])) return nil;
  self.languageIdentifier = @"en";
  _shaarPrimaryWindowID = NSUUID.UUID.UUIDString;
  _shaarProfiles = [NSMutableDictionary dictionary];
  _shaarProfileWaiters = [NSMutableDictionary dictionary];
  _shaarWindows = [NSMutableDictionary dictionary];
  _shaarTabs = [NSMutableDictionary dictionary];
  _shaarTabWindows = [NSMutableDictionary dictionary];
  _shaarTabProfiles = [NSMutableDictionary dictionary];
  _shaarSelectedTabs = [NSMutableDictionary dictionary];
  _hostResizeObservers = [NSMutableDictionary dictionary];
  _hostCloseObservers = [NSMutableDictionary dictionary];
  _hostSizes = [NSMutableDictionary dictionary];
  _shaarFindTokens = [NSMutableDictionary dictionary];
  _shaarFindRequests = [NSMutableDictionary dictionary];
  _shaarMediaRequests = [NSMutableDictionary dictionary];
  _shaarHttpsOnly = [NSMutableDictionary dictionary];
  _shaarCaptureRequests = [NSMutableDictionary dictionary];
  _shaarInstallRequests = [NSMutableDictionary dictionary];
  _shaarProfileFilesBeforeOpen = [NSMutableDictionary dictionary];
  _shaarDeviceChooserRequests = [NSMutableDictionary dictionary];
  _shaarHTTPAuthRequests = [NSMutableDictionary dictionary];
  _shaarShareRequests = [NSMutableDictionary dictionary];
  _shaarPrintRequests = [NSMutableDictionary dictionary];
  _shaarJavaScriptDialogRequests = [NSMutableDictionary dictionary];
  _shaarSavePrompts = [NSMutableDictionary dictionary];
  _nextRequestID = 1;
  NSURL *binary = [url URLByAppendingPathComponent:@"Versions/Current/Chromium Framework"];
  _shaarLibrary = dlopen(binary.fileSystemRepresentation, RTLD_NOW | RTLD_GLOBAL);
  if (!_shaarLibrary || !_symbols.Load(_shaarLibrary)) {
    if (error) {
      NSString *format = ARCBridgeLocalizedString(@"Cannot load Chromium: %@");
      NSString *message = [NSString stringWithFormat:format, binary.path];
      *error = [NSError errorWithDomain:@"com.arcusis.browser.chromium" code:1
                              userInfo:@{NSLocalizedDescriptionKey: message}];
    }
    if (_shaarLibrary) dlclose(_shaarLibrary);
    _shaarLibrary = nullptr;
    return nil;
  }
  _shaarMediaConsentAvailable = _symbols.abi_minor() >= 8;
  // Desktop capture requests arrive with patch 0071. Minor 14 is that bump.
  _shaarDesktopCaptureAvailable = _symbols.abi_minor() >= 14;
  _shaarDeviceChooserAvailable = _symbols.abi_minor() >= kShaarDeviceChooserABIMinor;
  _symbols.tab_find = reinterpret_cast<decltype(_symbols.tab_find)>(
      dlsym(_shaarLibrary, "shaar_tab_find"));
  _shaarShareReply = reinterpret_cast<ShaarShareReplyFunction>(
      dlsym(_shaarLibrary, "shaar_share_reply"));
  _shaarWebShareAvailable = _symbols.abi_minor() >= 15 && _shaarShareReply != nullptr;
  _shaarPrintReply = reinterpret_cast<ShaarPrintReplyFunction>(
      dlsym(_shaarLibrary, "shaar_print_reply"));
  _shaarPrintAvailable = _symbols.abi_minor() >= 16 && _shaarPrintReply != nullptr;
  _shaarJavaScriptDialogsAvailable = _symbols.abi_minor() >= 17;
  _shaarSavePromptsAvailable = _symbols.abi_minor() >= kShaarSavePromptABIMinor;
  return self;
}

- (int)runWithDataDirectory:(NSURL *)directory testing:(BOOL)testing {
  NSAssert(NSThread.isMainThread, @"Shaar engine requires the main thread");
  if (![NSFileManager.defaultManager createDirectoryAtURL:directory
                              withIntermediateDirectories:YES attributes:nil error:nil]) return 1;
  _shaarUserDataDirectory = directory;
  ARCDisableBackgroundMode(directory);
  ARCDisableHttpsFirstDialog(directory);
  char *resolved = realpath(directory.fileSystemRepresentation, nullptr);
  if (!resolved) return 1;
  NSString *path = [NSString stringWithUTF8String:resolved];
  free(resolved);
  shaar_config config = {};
  config.size = sizeof(config);
  config.requested_major = SHAAR_ENGINE_ABI_MAJOR;
  // Minor 7 remains the launch baseline; website media consent is gated below.
  config.requested_minor = 7;
  config.data_root = Bytes(path);
  config.locale = Bytes(self.languageIdentifier ?: @"en");
  config.on_event = ShaarEventCallback;
  config.event_context = (__bridge void *)self;
  shaar_error error = EmptyError();
  // Verification builds alone enable the engine's mock keychain and test fixtures.
#if defined(SHAAR_VERIFICATION)
  id mockKeychainSetting = [NSBundle.mainBundle objectForInfoDictionaryKey:@"ShaarUseMockKeychain"];
  BOOL requested = ARCInfoBool(mockKeychainSetting) || ARCEnvironmentRequestsMockKeychain();
  BOOL adHoc = NO;
  if (requested) adHoc = ARCBundleIsAdHocSigned(NSBundle.mainBundle);
  BOOL mockKeychain = ARCMockKeychainEnabled(requested, adHoc);
  const char *engineTesting = "0";
  if (testing) engineTesting = "1";
  if (mockKeychain) engineTesting = "1";
  setenv("SHAAR_ENGINE_TESTING", engineTesting, 1);
#endif
  if (_symbols.create(&config, &_shaarEngine, &error) != SHAAR_OK) {
#if defined(SHAAR_VERIFICATION)
    unsetenv("SHAAR_ENGINE_TESTING");
#endif
    return 1;
  }
  _shaarTesting = testing;
  const shaar_error_code result = _symbols.run(_shaarEngine, &error);
#if defined(SHAAR_VERIFICATION)
  unsetenv("SHAAR_ENGINE_TESTING");
#endif
  // Remaining native handles are being torn down, not closed by the user.
  _shaarQuitting = YES;
  if (self.onQuitRequested) self.onQuitRequested();
  for (NSString *windowID in [_shaarWindows.allKeys copy]) [self finishWindowID:windowID];
  for (id observer in _hostResizeObservers.allValues)
    [NSNotificationCenter.defaultCenter removeObserver:observer];
  [_hostResizeObservers removeAllObjects];
  for (id observer in _hostCloseObservers.allValues)
    [NSNotificationCenter.defaultCenter removeObserver:observer];
  [_hostCloseObservers removeAllObjects];
  [_hostSizes removeAllObjects];
  [_shaarWindows removeAllObjects];
  [_shaarTabs removeAllObjects];
  [_shaarFindTokens removeAllObjects];
  [_shaarFindRequests removeAllObjects];
  [_shaarMediaRequests removeAllObjects];
  [_shaarDeviceChooserRequests removeAllObjects];
  [_shaarShareRequests removeAllObjects];
  [_shaarInstallRequests removeAllObjects];
  [_shaarJavaScriptDialogRequests removeAllObjects];
  [_shaarSavePrompts removeAllObjects];
  _symbols.release(_shaarEngine);
  _shaarEngine = nullptr;
  return result == SHAAR_OK ? 0 : 1;
}

- (void)receiveEvent:(const shaar_event *)event {
  if (!event) return;
  NSData *data = [NSData dataWithBytes:event->payload_json.data ?: ""
                                length:event->payload_json.size];
  NSDictionary *payload = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
  if (![payload isKindOfClass:NSDictionary.class]) return;
  [self shaarExtensionEvent:event payload:payload];
  NSString *kind = payload[@"kind"];
  if (event->kind == SHAAR_EVENT_ENGINE && !event->session_id.size &&
      [kind isEqualToString:@"storage.keychainUnavailable"] &&
      [payload[@"schemaVersion"] isEqual:@1] &&
      [payload[@"restartRequired"] isEqual:@YES] &&
      [payload[@"persistentCookiesAvailable"] isEqual:@NO]) {
    _shaarStartupNotice = ARCBridgeLocalizedString(@"Browsing is available, but saved cookies and passwords are unavailable for this launch. Unlock your keychain or approve access, then restart Shaar.");
    if (self.onNotice) self.onNotice(_shaarStartupNotice);
    return;
  }
  if (event->session_id.size) {
    [self receivePrivateEvent:event payload:payload];
    return;
  }
  if (event->kind == SHAAR_EVENT_ENGINE && [kind isEqualToString:@"engine.ready"]) {
    if (_shaarTesting) [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
    NSError *error = nil;
    if (![self createWindowID:_shaarPrimaryWindowID error:&error]) {
      if (self.onNotice) self.onNotice(error.localizedDescription);
      [self quit];
      return;
    }
    if (self.onReady) self.onReady();
    return;
  }
  if (event->kind == SHAAR_EVENT_ENGINE &&
      ([kind isEqualToString:@"engine.quitRequested"] ||
       [kind isEqualToString:@"engine.willShutDown"])) {
    _shaarQuitting = YES;
    if (self.onQuitRequested) self.onQuitRequested();
    return;
  }
  if (event->kind == SHAAR_EVENT_ENGINE && [kind isEqualToString:@"engine.quitCancelled"]) {
    _shaarQuitting = NO;
    if (self.onQuitCancelled) self.onQuitCancelled();
    return;
  }
  NSString *tabID = String(event->tab_id);
  NSString *profileID = String(event->profile_id).uppercaseString;
  BOOL websitePermissionDismissed = NO;
  if (event->kind == SHAAR_EVENT_PERMISSION && !event->session_id.size &&
      [kind isEqualToString:@"httpAuthRequested"]) {
    NSString *requestID = payload[@"id"];
    NSString *windowID = String(event->window_id);
    NSString *realm = payload[@"realm"];
    NSString *host = payload[@"host"];
    if (![payload[@"schemaVersion"] isEqual:@1] ||
        ![requestID isKindOfClass:NSString.class] || !requestID.length ||
        requestID.length > 128 || _shaarHTTPAuthRequests[requestID] ||
        !_shaarTabs[tabID] || ![profileID isEqualToString:_shaarTabProfiles[tabID]] ||
        ![windowID isEqualToString:_shaarTabWindows[tabID]] ||
        ![realm isKindOfClass:NSString.class] || realm.length > 512 ||
        ![host isKindOfClass:NSString.class] || !host.length || host.length > 255) return;
    _shaarHTTPAuthRequests[requestID] = tabID;
    NSMutableDictionary *request = [payload mutableCopy];
    request[@"profileID"] = profileID; request[@"tabID"] = tabID; request[@"windowID"] = windowID;
    if (self.onHTTPAuthRequest) self.onHTTPAuthRequest(request);
    else [self resolveHTTPAuthRequestID:requestID tabID:tabID username:nil password:nil];
    return;
  }
  if (event->kind == SHAAR_EVENT_JAVASCRIPT_DIALOG &&
      _shaarJavaScriptDialogsAvailable && !event->session_id.size &&
      [kind isEqualToString:@"javascriptDialogRequested"]) {
    NSString *requestID = payload[@"id"];
    NSString *windowID = String(event->window_id);
    if (![payload[@"schemaVersion"] isEqual:@1] ||
        ![requestID isKindOfClass:NSString.class] || !requestID.length ||
        requestID.length > 64 || _shaarJavaScriptDialogRequests[requestID] ||
        !_shaarTabs[tabID] || ![profileID isEqualToString:_shaarTabProfiles[tabID]] ||
        ![windowID isEqualToString:_shaarTabWindows[tabID]]) return;
    _shaarJavaScriptDialogRequests[requestID] = tabID;
    NSMutableDictionary *request = [payload mutableCopy];
    request[@"profileID"] = profileID; request[@"tabID"] = tabID; request[@"windowID"] = windowID;
    if (self.onJavaScriptDialogRequest) self.onJavaScriptDialogRequest(request);
    else [self resolveJavaScriptDialogRequestID:requestID accepted:NO input:nil];
    return;
  }
  if (event->kind == SHAAR_EVENT_PERMISSION && !event->session_id.size &&
      [kind isEqualToString:@"httpAuthDismissed"]) {
    NSString *requestID = payload[@"id"];
    if (![payload[@"schemaVersion"] isEqual:@1] || ![requestID isKindOfClass:NSString.class] ||
        ![_shaarHTTPAuthRequests[requestID] isEqualToString:tabID]) return;
    [_shaarHTTPAuthRequests removeObjectForKey:requestID];
    if (self.onHTTPAuthDismissed) self.onHTTPAuthDismissed(requestID);
    return;
  }
  if (event->kind == SHAAR_EVENT_JAVASCRIPT_DIALOG && _shaarJavaScriptDialogsAvailable &&
      !event->session_id.size && [kind isEqualToString:@"javascriptDialogDismissed"]) {
    NSString *requestID = payload[@"id"];
    if (![payload[@"schemaVersion"] isEqual:@1] || ![requestID isKindOfClass:NSString.class] ||
        ![_shaarJavaScriptDialogRequests[requestID] isEqualToString:tabID]) return;
    [_shaarJavaScriptDialogRequests removeObjectForKey:requestID];
    if (self.onJavaScriptDialogDismissed) self.onJavaScriptDialogDismissed(requestID);
    return;
  }
  if (event->kind == SHAAR_EVENT_PERMISSION &&
      ShaarWebsitePermissionEvent(kind, &websitePermissionDismissed)) {
    if (websitePermissionDismissed) {
      NSString *requestID = payload[@"id"];
      if (![payload[@"schemaVersion"] isEqual:@1] ||
          ![requestID isKindOfClass:NSString.class] ||
          ![_shaarMediaRequests[requestID] isEqualToString:tabID]) return;
      [_shaarMediaRequests removeObjectForKey:requestID];
      if (self.onWebsiteMediaDismissed) self.onWebsiteMediaDismissed(requestID);
      return;
    }
    NSString *windowID = String(event->window_id);
    NSString *requestID = payload[@"id"];
    if (!_shaarMediaConsentAvailable || event->session_id.size ||
        ![payload[@"schemaVersion"] isEqual:@1] ||
        ![requestID isKindOfClass:NSString.class] || !requestID.length ||
        requestID.length > 128 || _shaarMediaRequests[requestID] ||
        !_shaarTabs[tabID] ||
        ![profileID isEqualToString:_shaarTabProfiles[tabID]] ||
        ![windowID isEqualToString:_shaarTabWindows[tabID]]) return;
    _shaarMediaRequests[requestID] = tabID;
    NSMutableDictionary *request = [payload mutableCopy];
    request[@"profileID"] = profileID;
    request[@"tabID"] = tabID;
    request[@"windowID"] = windowID;
    if (self.onWebsiteMediaRequest) {
      self.onWebsiteMediaRequest(request);
    } else {
      [self resolveWebsiteMediaRequestID:requestID accepted:NO];
    }
    return;
  }
  if (event->kind == SHAAR_EVENT_PERMISSION &&
      [kind isEqualToString:@"desktopCaptureDismissed"]) {
    [self receiveDesktopCaptureDismissal:payload tabID:tabID];
    return;
  }
  if (event->kind == SHAAR_EVENT_PERMISSION &&
      [kind isEqualToString:@"desktopCaptureRequested"]) {
    [self receiveDesktopCaptureRequest:event payload:payload tabID:tabID profileID:profileID];
    return;
  }
  BOOL chooserDismissed = NO;
  BOOL chooserUpdated = NO;
  if (_shaarDeviceChooserAvailable && event->kind == SHAAR_EVENT_PERMISSION &&
      ShaarDeviceChooserKind(kind, &chooserDismissed, &chooserUpdated)) {
    NSString *requestID = payload[@"id"];
    NSString *windowID = String(event->window_id);
    if (![payload[@"schemaVersion"] isEqual:@1] || !ShaarDeviceChooserID(requestID)) return;
    if (chooserDismissed || chooserUpdated) {
      if (![_shaarDeviceChooserRequests[requestID] isEqualToString:tabID]) return;
      if (chooserDismissed) [_shaarDeviceChooserRequests removeObjectForKey:requestID];
      NSMutableDictionary *chooserEvent = [payload mutableCopy];
      chooserEvent[@"profileID"] = profileID;
      chooserEvent[@"tabID"] = tabID;
      chooserEvent[@"windowID"] = windowID;
      if (self.onDeviceChooserEvent) self.onDeviceChooserEvent(chooserEvent);
      return;
    }
    if (event->session_id.size || _shaarDeviceChooserRequests[requestID] ||
        !_shaarTabs[tabID] ||
        ![profileID isEqualToString:_shaarTabProfiles[tabID]] ||
        ![windowID isEqualToString:_shaarTabWindows[tabID]]) return;
    _shaarDeviceChooserRequests[requestID] = tabID;
    NSMutableDictionary *chooserEvent = [payload mutableCopy];
    chooserEvent[@"profileID"] = profileID;
    chooserEvent[@"tabID"] = tabID;
    chooserEvent[@"windowID"] = windowID;
    if (self.onDeviceChooserEvent) {
      self.onDeviceChooserEvent(chooserEvent);
    } else {
      [self resolveDeviceChooserRequestID:requestID optionID:nil];
    }
  }
  if (event->kind == SHAAR_EVENT_PERMISSION &&
      [kind isEqualToString:@"webShareRequested"] && _shaarWebShareAvailable) {
    [self receiveWebShareRequest:event payload:payload tabID:tabID profileID:profileID];
    return;
  }
  if (event->kind == SHAAR_EVENT_EXTENSION &&
      [kind isEqualToString:@"installRequested"] && !event->session_id.size) {
    [self receiveExtensionInstallEvent:event payload:payload profileID:profileID tabID:tabID];
    return;
  }
  if (event->kind == SHAAR_EVENT_PERMISSION &&
      [kind isEqualToString:@"printRequested"] && _shaarPrintAvailable) {
    [self receivePrintRequest:event payload:payload tabID:tabID profileID:profileID];
    return;
  }
  if (event->kind == SHAAR_EVENT_DEVTOOLS && [kind isEqualToString:@"panelEvent"] &&
      !event->session_id.size && [payload[@"schemaVersion"] isEqual:@1] &&
      _shaarTabs[tabID] && [profileID isEqualToString:_shaarTabProfiles[tabID]] &&
      [String(event->window_id) isEqualToString:_shaarTabWindows[tabID]] &&
      self.onDevToolsPanelEvent) {
    self.onDevToolsPanelEvent(tabID, profileID, String(event->window_id), data,
                              event->sequence);
    return;
  }
  if (event->kind == SHAAR_EVENT_DEVTOOLS &&
      [kind isEqualToString:@"openURLRequested"]) {
    NSString *windowID = String(event->window_id);
    NSString *requestedProfile = payload[@"profileID"];
    if ([payload[@"schemaVersion"] intValue] != 1 ||
        ![payload[@"sourceWindowID"] isEqualToString:windowID] ||
        ![payload[@"sourceTabID"] isEqualToString:tabID] ||
        ![requestedProfile isKindOfClass:NSString.class] ||
        ![requestedProfile.uppercaseString isEqualToString:profileID]) return;
    NSMutableDictionary *request = [payload mutableCopy];
    request[@"profileID"] = profileID;
    NSString *contextID = String(event->session_id).uppercaseString;
    if (contextID.length) request[@"contextID"] = contextID;
    if (self.onDevToolsOpenURLRequest) self.onDevToolsOpenURLRequest(request);
    return;
  }
  if (event->kind == SHAAR_EVENT_DEVTOOLS && [kind isEqualToString:@"controlStatus"] &&
      [payload[@"schemaVersion"] isEqual:@1] && !event->session_id.size &&
      [[NSSet setWithArray:payload.allKeys] isSubsetOfSet:
          [NSSet setWithArray:@[@"schemaVersion", @"kind", @"enabled", @"connectionCount"]]] &&
      _shaarTabs[tabID] && [profileID isEqualToString:_shaarTabProfiles[tabID]] &&
      [String(event->window_id) isEqualToString:_shaarTabWindows[tabID]] &&
      [payload[@"enabled"] isKindOfClass:NSNumber.class] &&
      [payload[@"connectionCount"] isKindOfClass:NSNumber.class] &&
      self.onAgentBridgeStatus) {
    self.onAgentBridgeStatus(tabID, profileID, payload);
    return;
  }
  if (event->kind == SHAAR_EVENT_FIND) {
    id nativeRequestID = payload[@"requestID"];
    NSString *token = [nativeRequestID isKindOfClass:NSString.class]
        ? _shaarFindTokens[nativeRequestID] : nil;
    int schemaVersion = 0, matchCount = 0, activeMatch = 0;
    id finalValue = payload[@"final"];
    if ([payload[@"kind"] isEqual:@"result"] &&
        ARCReadJSONInteger(payload[@"schemaVersion"], &schemaVersion) && schemaVersion == 1 &&
        ARCReadJSONInteger(payload[@"matchCount"], &matchCount) && matchCount >= 0 &&
        ARCReadJSONInteger(payload[@"activeMatch"], &activeMatch) && activeMatch >= -1 &&
        [finalValue isKindOfClass:NSNumber.class] &&
        CFGetTypeID((__bridge CFTypeRef)finalValue) == CFBooleanGetTypeID() &&
        token && [_shaarFindRequests[tabID] isEqualToString:nativeRequestID] &&
        _shaarTabs[tabID] && self.onFindResult)
      self.onFindResult(tabID, token, matchCount, activeMatch, [finalValue boolValue]);
    return;
  }
  if (event->kind == SHAAR_EVENT_BOOKMARK && !event->session_id.size &&
      _shaarProfiles[profileID]) {
    if (self.onLibraryChanged) self.onLibraryChanged(profileID, @"bookmarks");
    return;
  }
  if (event->kind == SHAAR_EVENT_HISTORY && !event->session_id.size &&
      _shaarProfiles[profileID]) {
    if (self.onLibraryChanged) self.onLibraryChanged(profileID, @"history");
    return;
  }
  if (event->kind == SHAAR_EVENT_WINDOW && [kind isEqualToString:@"closed"]) {
    [self finishWindowID:String(event->window_id)];
    return;
  }
  if (event->kind == SHAAR_EVENT_TAB && [kind isEqualToString:@"opened"]) {
    [self adoptOpenedTabFromEvent:event payload:payload profileID:profileID];
    return;
  }
  if (event->kind == SHAAR_EVENT_TAB && [kind isEqualToString:@"closed"]) {
    for (NSString *requestID in [_shaarMediaRequests allKeysForObject:tabID])
      [self resolveWebsiteMediaRequestID:requestID accepted:NO];
    for (NSString *requestID in [_shaarCaptureRequests allKeysForObject:tabID])
      [self resolveDesktopCaptureRequestID:requestID sourceID:nil];
    for (NSString *requestID in [_shaarDeviceChooserRequests allKeysForObject:tabID])
      [self resolveDeviceChooserRequestID:requestID optionID:nil];
    for (NSString *requestID in [_shaarShareRequests allKeysForObject:tabID])
      [self resolveWebShareRequestID:requestID outcome:@"cancelled"];
    [self cancelExtensionInstallRequestsForTabID:tabID];
    for (NSString *requestID in [_shaarPrintRequests allKeysForObject:tabID])
      [self resolvePrintRequestID:requestID accepted:NO];
    for (NSString *requestID in [_shaarHTTPAuthRequests allKeysForObject:tabID])
      [self resolveHTTPAuthRequestID:requestID tabID:tabID username:nil password:nil];
    for (NSString *requestID in [_shaarJavaScriptDialogRequests allKeysForObject:tabID])
      [self resolveJavaScriptDialogRequestID:requestID accepted:NO input:nil];
    for (NSString *requestID in [_shaarSavePrompts allKeysForObject:tabID])
      [self resolveSavePromptRequestID:requestID decision:@"dismiss"];
    NSString *mappedWindowID = _shaarTabWindows[tabID];
    NSString *windowID = String(event->window_id);
    if (!windowID.length) windowID = mappedWindowID;
    if (windowID && [_shaarSelectedTabs[windowID] isEqualToString:tabID])
      [_shaarSelectedTabs removeObjectForKey:windowID];
    [_shaarTabs removeObjectForKey:tabID];
    [self forgetShaarMediaForTabID:tabID];
    [self stopFindingInTabID:tabID];
    [_shaarTabWindows removeObjectForKey:tabID];
    [_shaarTabProfiles removeObjectForKey:tabID];
    if (self.onTabClosed && windowID.length) self.onTabClosed(tabID, windowID);
    return;
  }
  if (event->kind == SHAAR_EVENT_TAB && [kind isEqualToString:@"lifecycle"]) {
    if (_shaarTabs[tabID] && self.onTabLifecycle) {
      NSString *state = [payload[@"state"] isKindOfClass:NSString.class] ? payload[@"state"] : @"";
      self.onTabLifecycle(tabID, state, [payload[@"audible"] boolValue],
                          [payload[@"capturing"] boolValue]);
    }
    return;
  }
  if (event->kind == SHAAR_EVENT_SAVE_PROMPT) {
    if (!_shaarSavePromptsAvailable) return;
    NSString *requestID = payload[@"id"];
    if ([payload[@"kind"] isEqualToString:@"savePromptDismissed"]) {
      if (!ShaarSavePromptDismissIsValid(payload) ||
          ![_shaarSavePrompts[requestID] isEqualToString:tabID]) return;
      [_shaarSavePrompts removeObjectForKey:requestID];
      if (self.onSavePromptDismissed) self.onSavePromptDismissed(requestID);
      return;
    }
    NSString *windowID = String(event->window_id);
    if (!ShaarSavePromptRequestIsValid(payload) || _shaarSavePrompts[requestID] ||
        !_shaarTabs[tabID] ||
        ![profileID isEqualToString:_shaarTabProfiles[tabID]] ||
        ![windowID isEqualToString:_shaarTabWindows[tabID]]) return;
    _shaarSavePrompts[requestID] = tabID;
    NSMutableDictionary *request = [payload mutableCopy];
    request[@"profileID"] = profileID;
    request[@"tabID"] = tabID;
    request[@"windowID"] = windowID;
    if (self.onSavePromptRequest) self.onSavePromptRequest(request);
    else [self resolveSavePromptRequestID:requestID decision:@"dismiss"];
    return;
  }
  if (event->kind == SHAAR_EVENT_DOWNLOAD) {
    [self shaarReceiveDownloadEventForProfileID:
        [self shaarProfileIDForNativeID:String(event->profile_id)] payload:payload];
    return;
  }
  if (event->kind == SHAAR_EVENT_MEDIA) {
    if (_shaarTabs[tabID] && [profileID isEqualToString:_shaarTabProfiles[tabID]] &&
        [String(event->window_id) isEqualToString:_shaarTabWindows[tabID]])
      [self receiveShaarMediaEventForTabID:tabID payload:payload];
    return;
  }
  if (event->kind != SHAAR_EVENT_NAVIGATION || !_shaarTabs[tabID]) return;
  NSString *url = [payload[@"url"] isKindOfClass:NSString.class] ? payload[@"url"] : @"";
  NSString *title = [payload[@"title"] isKindOfClass:NSString.class] ? payload[@"title"] : @"";
  if (self.onTabChanged) {
    self.onTabChanged(tabID, url, title, [payload[@"loading"] boolValue],
                      [payload[@"canGoBack"] boolValue], [payload[@"canGoForward"] boolValue]);
  }
  if ([payload[@"phase"] isEqualToString:@"committed"] && self.onDocumentCommitted)
    self.onDocumentCommitted(tabID, _shaarTabProfiles[tabID] ?: @"");
  if ([payload[@"phase"] isEqualToString:@"committed"] && self.onLibraryChanged)
    self.onLibraryChanged(_shaarTabProfiles[tabID] ?: @"", @"history");
  NSDictionary *failure = [payload[@"failure"] isKindOfClass:NSDictionary.class]
      ? payload[@"failure"] : nil;
  if ([failure[@"descriptionCode"] isEqualToString:@"renderer_gone"] && self.onRendererGone)
    self.onRendererGone(tabID, _shaarTabProfiles[tabID] ?: @"", @"renderer_gone", 0);
}

- (void)resolveHTTPAuthRequestID:(NSString *)requestID tabID:(NSString *)tabID
                        username:(NSString *)username password:(NSString *)password {
  if (![_shaarHTTPAuthRequests[requestID] isEqualToString:tabID]) return;
  [_shaarHTTPAuthRequests removeObjectForKey:requestID];
  NSMutableDictionary *payload = [@{@"schemaVersion": @1, @"id": requestID,
                                    @"cancelled": @(username == nil || password == nil)} mutableCopy];
  if (username && password) {
    payload[@"username"] = username;
    payload[@"password"] = password;
  }
  [self submitTabID:tabID operation:kShaarHTTPCredentialsReply payload:payload];
}

- (NSValue *)loadedProfileValueForID:(NSString *)profileID {
  NSValue *value = _shaarProfiles[profileID];
  if (value) return value;
  for (NSString *key in _shaarProfiles) {
    if ([key caseInsensitiveCompare:profileID] == NSOrderedSame) return _shaarProfiles[key];
  }
  return nil;
}

- (BOOL)applyLiveHttpsOnly:(BOOL)enabled profileID:(NSString *)profileID {
  NSValue *value = [self loadedProfileValueForID:profileID];
  if (!_shaarLibrary || !value) return NO;
  auto setter = reinterpret_cast<shaar_error_code (*)(shaar_profile *, int, shaar_error *)>(
      dlsym(_shaarLibrary, "shaar_profile_set_https_only"));
  shaar_profile *profile = static_cast<shaar_profile *>(value.pointerValue);
  if (!setter || !profile) return NO;
  shaar_error error = EmptyError();
  return setter(profile, enabled ? 1 : 0, &error) == SHAAR_OK;
}

- (void)seedHttpsOnlyForProfileID:(NSString *)profileID {
  NSString *canonical = ARCCanonicalProfileID(profileID);
  if (!canonical || !_shaarUserDataDirectory) return;
  NSNumber *applied = ARCSeedHttpsOnlyPreference(
      _shaarUserDataDirectory, canonical, _shaarHttpsOnly[canonical]);
  if (applied) _shaarHttpsOnly[canonical] = applied;
}

- (BOOL)setHttpsOnlyModeEnabled:(BOOL)enabled forProfileID:(NSString *)profileID {
  NSString *canonical = ARCCanonicalProfileID(profileID);
  if (!canonical) return NO;
  NSNumber *previous = _shaarHttpsOnly[canonical];
  BOOL changed = !previous || previous.boolValue != enabled;
  _shaarHttpsOnly[canonical] = @(enabled);
  if (_shaarUserDataDirectory && changed &&
      !ARCWriteHttpsOnlyPreference(_shaarUserDataDirectory, canonical, enabled)) return NO;
  if ([self loadedProfileValueForID:profileID]) {
    return [self applyLiveHttpsOnly:enabled profileID:profileID];
  }
  return YES;
}

- (NSArray<NSString *> *)profileDirectoryEntriesBeforeOpenForProfileID:(NSString *)profileID {
  return _shaarProfileFilesBeforeOpen[profileID] ?: @[];
}

- (void)loadProfileID:(NSString *)profileID completion:(void (^)(NSError *))completion {
  if ([self isPrivateIdentity:profileID]) {
    completion(ShaarError(@"Invalid profile identity or engine not ready."));
    return;
  }
  if (_shaarProfiles[profileID]) {
    NSMutableArray *waiters = _shaarProfileWaiters[profileID];
    if (waiters) [waiters addObject:[completion copy]];
    else completion(nil);
    return;
  }
  [self seedHttpsOnlyForProfileID:profileID];
  _shaarProfileWaiters[profileID] = [NSMutableArray arrayWithObject:[completion copy]];
  NSString *canonicalID = profileID.lowercaseString;
  NSString *directory = [@"Profile " stringByAppendingString:canonicalID];
  NSArray<NSString *> *entries = nil;
  if (_shaarUserDataDirectory) {
    NSURL *profileDirectory = [_shaarUserDataDirectory URLByAppendingPathComponent:directory
                                                                       isDirectory:YES];
    entries = [NSFileManager.defaultManager contentsOfDirectoryAtPath:profileDirectory.path
                                                                 error:nil];
  }
  _shaarProfileFilesBeforeOpen[profileID] =
      [entries sortedArrayUsingSelector:@selector(compare:)] ?: @[];
  __weak ARCShaarRuntime *weakSelf = self;
  void (^reply)(NSError *) = ^(NSError *failure) {
    if (failure) {
      [weakSelf finishProfileLoadID:profileID error:failure];
      return;
    }
    [weakSelf submitProfileID:profileID operation:SHAAR_OP_BOOKMARK_WATCH
                       payload:@{@"schemaVersion": @1, @"enabled": @YES}
                    completion:^(NSDictionary *result, NSError *error) {}];
    [weakSelf shaarPrimeSiteControlsForProfileID:profileID completion:^{
      [weakSelf shaarPrimeEngineServicesForProfileID:profileID completion:^{
        [weakSelf finishProfileLoadID:profileID error:nil];
      }];
    }];
  };
  void *context = (__bridge_retained void *)reply;
  shaar_profile *profile = nullptr;
  shaar_error error = EmptyError();
  shaar_error_code status = _symbols.profile_open(
      _shaarEngine, Bytes(canonicalID), Bytes(directory), 1, _nextRequestID++,
      [](void *context, const shaar_result *result) {
        void (^finish)(NSError *) = (__bridge_transfer id)context;
        finish(result && result->error.code == SHAAR_OK ? nil :
               ShaarError(@"Shaar could not load the profile."));
      }, context, &profile, &error);
  if (status != SHAAR_OK) {
    CFBridgingRelease(context);
    [self finishProfileLoadID:profileID error:ShaarError(@"Shaar could not open the profile.")];
    return;
  }
  _shaarProfiles[profileID] = [NSValue valueWithPointer:profile];
}

- (void)finishProfileLoadID:(NSString *)profileID error:(NSError *)error {
  NSArray *waiters = [_shaarProfileWaiters[profileID] copy];
  [_shaarProfileWaiters removeObjectForKey:profileID];
  if (error) [_shaarProfiles removeObjectForKey:profileID];
  for (id pending in waiters) {
    void (^complete)(NSError *) = pending;
    complete(error);
  }
}

- (shaar_engine *)privateEngineHandle { return _shaarEngine; }
- (uint64_t)nextPrivateDevToolsRequestID { return _nextRequestID++; }
- (shaar_profile *)privateProfileHandleForID:(NSString *)profileID {
  return (shaar_profile *)_shaarProfiles[profileID].pointerValue;
}

- (NSString *)primaryWindowID { return _shaarPrimaryWindowID; }
- (BOOL)isQuitting { return _shaarQuitting; }
- (NSString *)chromiumVersion { return @"157.0.8103.51"; }
- (NSWindow *)window { return [self windowForID:_shaarPrimaryWindowID]; }
- (NSView *)hostView { return [self hostViewForWindowID:_shaarPrimaryWindowID]; }

- (BOOL)createWindowID:(NSString *)windowID error:(NSError **)error {
  if ([self privateIdentityOccupied:windowID]) {
    if (error) *error = ShaarError(@"Invalid or reused native window identity.");
    return NO;
  }
  if (!_shaarEngine || _shaarWindows[windowID]) return NO;
  shaar_window *window = nullptr;
  shaar_error nativeError = EmptyError();
  const shaar_error_code status = _symbols.window_open(
      _shaarEngine, SHAAR_WINDOW_REGULAR, nullptr, Bytes(windowID), &window,
      &nativeError);
  if (status != SHAAR_OK) {
    if (error) *error = ShaarError(@"Shaar could not open the window.");
    return NO;
  }
  _shaarWindows[windowID] = [NSValue valueWithPointer:window];
  NSWindow *nativeWindow = (__bridge NSWindow *)_symbols.window_native_window(window);
  if (nativeWindow) {
    __weak ARCShaarRuntime *weakSelf = self;
    _hostCloseObservers[windowID] = [NSNotificationCenter.defaultCenter
        addObserverForName:NSWindowWillCloseNotification object:nativeWindow
                     queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *notification) {
      [weakSelf finishWindowID:windowID];
    }];
  }
  return YES;
}

- (BOOL)closeWindowID:(NSString *)windowID {
  shaar_window *window = (shaar_window *)_shaarWindows[windowID].pointerValue;
  if (!window) return NO;
  shaar_error error = EmptyError();
  if (_symbols.window_close(window, &error) != SHAAR_OK) return NO;
  return YES;
}

- (BOOL)isWindowOpenID:(NSString *)windowID {
  shaar_window *window = (shaar_window *)_shaarWindows[windowID].pointerValue;
  return window && _symbols.window_native_window(window) != nullptr;
}

- (void)retireClosedWindowID:(NSString *)windowID {
  [self finishWindowID:windowID];
}

- (void)finishWindowID:(NSString *)windowID {
  if (!_shaarWindows[windowID]) return;
  id observer = _hostResizeObservers[windowID];
  if (observer) [NSNotificationCenter.defaultCenter removeObserver:observer];
  id closeObserver = _hostCloseObservers[windowID];
  if (closeObserver) [NSNotificationCenter.defaultCenter removeObserver:closeObserver];
  [_hostResizeObservers removeObjectForKey:windowID];
  [_hostCloseObservers removeObjectForKey:windowID];
  [_hostSizes removeObjectForKey:windowID];
  [_shaarSelectedTabs removeObjectForKey:windowID];
  for (NSString *requestID in [_shaarShareRequests.allKeys copy]) {
    NSString *tabID = _shaarShareRequests[requestID];
    if ([_shaarTabWindows[tabID] isEqualToString:windowID])
      [self resolveWebShareRequestID:requestID outcome:@"cancelled"];
  }
  for (NSString *tabID in [_shaarTabWindows.allKeys copy]) {
    if (![_shaarTabWindows[tabID] isEqualToString:windowID]) continue;
    [_shaarTabs removeObjectForKey:tabID];
    [_shaarTabWindows removeObjectForKey:tabID];
    [_shaarTabProfiles removeObjectForKey:tabID];
  }
  [_shaarWindows removeObjectForKey:windowID];
  [self closeExtensionPopupForWindowID:windowID];
  if (self.onWindowClosed) self.onWindowClosed(windowID, _shaarQuitting);
}

- (NSWindow *)windowForID:(NSString *)windowID {
  shaar_window *window = (shaar_window *)_shaarWindows[windowID].pointerValue;
  return window ? (__bridge NSWindow *)_symbols.window_native_window(window) : nil;
}

- (NSView *)hostViewForWindowID:(NSString *)windowID {
  shaar_window *window = (shaar_window *)_shaarWindows[windowID].pointerValue;
  if (!window) return nil;
  NSView *view = (__bridge NSView *)_symbols.window_host_view(window);
  if (!view || _hostResizeObservers[windowID]) return view;
  view.postsFrameChangedNotifications = YES;
  __weak ARCShaarRuntime *weakSelf = self;
  _hostResizeObservers[windowID] = [NSNotificationCenter.defaultCenter
      addObserverForName:NSViewFrameDidChangeNotification object:view
                   queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *notification) {
    ARCShaarRuntime *owner = weakSelf;
    if (!owner) return;
    shaar_window *current = (shaar_window *)owner->_shaarWindows[windowID].pointerValue;
    if (!current || !owner->_shaarEngine) return;
    NSSize size = [(NSView *)notification.object bounds].size;
    NSValue *last = owner->_hostSizes[windowID];
    if (last && NSEqualSizes(last.sizeValue, size)) return;
    owner->_hostSizes[windowID] = [NSValue valueWithSize:size];
    shaar_error error = EmptyError();
    owner->_symbols.window_host_resize(owner->_shaarEngine, current,
                                        size.width, size.height, &error);
  }];
  return view;
}

- (void)adoptOpenedTabFromEvent:(const shaar_event *)event
                        payload:(NSDictionary *)payload
                      profileID:(NSString *)profileID {
  if (!_symbols.tab_find || !_shaarEngine || event->session_id.size) return;
  if ([payload[@"schemaVersion"] intValue] != 1) return;
  NSString *tabID = String(event->tab_id);
  NSString *windowID = String(event->window_id);
  if (!tabID.length || !windowID.length || _shaarTabs[tabID]) return;
  NSString *openerID = [payload[@"openerTabID"] isKindOfClass:NSString.class]
      ? payload[@"openerTabID"] : nil;
  NSString *storedProfile = openerID.length ? _shaarTabProfiles[openerID] : nil;
  if (storedProfile.length) profileID = storedProfile;
  shaar_tab *tab = nullptr;
  shaar_error error = EmptyError();
  if (_symbols.tab_find(_shaarEngine, Bytes(windowID), Bytes(tabID), &tab, &error) != SHAAR_OK ||
      !tab) return;
  if (!_shaarWindows[windowID] || !_shaarProfiles[profileID]) {
    _shaarTabs[tabID] = [NSValue valueWithPointer:tab];
    [self closeTabID:tabID];
    return;
  }
  _shaarTabs[tabID] = [NSValue valueWithPointer:tab];
  _shaarTabWindows[tabID] = windowID;
  _shaarTabProfiles[tabID] = profileID;
  NSString *url = [payload[@"url"] isKindOfClass:NSString.class] ? payload[@"url"] : @"";
  if (self.onNewTab) {
    self.onNewTab(tabID, profileID, url, openerID, [payload[@"foreground"] boolValue]);
  } else {
    [self closeTabID:tabID];
  }
}

- (NSString *)windowIDForTabID:(NSString *)tabID { return _shaarTabWindows[tabID]; }
- (NSString *)profileIDForTabID:(NSString *)tabID { return _shaarTabProfiles[tabID]; }

- (BOOL)openTabID:(NSString *)tabID profileID:(NSString *)profileID windowID:(NSString *)windowID
               url:(NSString *)url error:(NSError **)error {
  if ([self isPrivateIdentity:tabID] || [self isPrivateIdentity:profileID]) {
    if (error) *error = ShaarError(@"Private identities cannot enter regular tab ownership.");
    return NO;
  }
  if (![self isWindowOpenID:windowID]) {
    if (error) *error = ShaarStatusError(@"Shaar window is closed.", SHAAR_NOT_FOUND);
    return NO;
  }
  shaar_window *window = (shaar_window *)_shaarWindows[windowID].pointerValue;
  shaar_profile *profile = (shaar_profile *)_shaarProfiles[profileID].pointerValue;
  if (!window || !profile || _shaarTabs[tabID]) {
    if (error) *error = ShaarError(@"Shaar tab scope is unavailable.");
    return NO;
  }
  shaar_scope scope = {};
  scope.size = sizeof(scope);
  scope.profile = profile;
  shaar_tab *tab = nullptr;
  shaar_error nativeError = EmptyError();
  const shaar_error_code status = _symbols.tab_open(
      scope, window, Bytes(tabID), Bytes(url), 0, &tab, &nativeError);
  if (status != SHAAR_OK) {
    if (_shaarTesting) {
      fprintf(stderr, "Shaar tab_open failed: status=%d native=%d profile=%s window=%s\n",
              (int)status, (int)nativeError.code, profileID.UTF8String,
              windowID.UTF8String);
    }
    if (error) *error = ShaarStatusError(@"Shaar could not open the tab.", status);
    return NO;
  }
  _shaarTabs[tabID] = [NSValue valueWithPointer:tab];
  _shaarTabWindows[tabID] = windowID;
  _shaarTabProfiles[tabID] = profileID;
  if (self.onTabChanged) self.onTabChanged(tabID, url, @"", url.length > 0, NO, NO);
  return YES;
}

- (BOOL)openTabID:(NSString *)tabID profileID:(NSString *)profileID url:(NSString *)url
              error:(NSError **)error {
  return [self openTabID:tabID profileID:profileID windowID:_shaarPrimaryWindowID
                    url:url error:error];
}

- (NSView *)viewForTabID:(NSString *)tabID {
  shaar_tab *tab = (shaar_tab *)_shaarTabs[tabID].pointerValue;
  return tab ? (__bridge NSView *)_symbols.tab_host_view(tab) : nil;
}

- (void)activateTabID:(NSString *)tabID {
  NSString *windowID = _shaarTabWindows[tabID];
  shaar_window *window = (shaar_window *)_shaarWindows[windowID].pointerValue;
  shaar_tab *tab = (shaar_tab *)_shaarTabs[tabID].pointerValue;
  if (!window || !tab) return;
  shaar_error error = EmptyError();
  if (_symbols.tab_view_attach(_shaarEngine, window, tab, &error) != SHAAR_OK) return;
  if (![_shaarSelectedTabs[windowID] isEqualToString:tabID])
    [self closeExtensionPopupForWindowID:windowID];
  _shaarSelectedTabs[windowID] = tabID;
  // Native notifications must unwind before reentering TabStripModel. Host
  // actions can activate immediately, without waiting behind Chromium's pump.
  __weak ARCShaarRuntime *weakSelf = self;
  ARCDispatchShaarTabActivation(^{
    ARCShaarRuntime *owner = weakSelf;
    if (!owner || !owner->_shaarEngine || !owner->_shaarTabs[tabID] ||
        ![owner->_shaarSelectedTabs[windowID] isEqualToString:tabID]) return;
    [owner shaarSubmit:SHAAR_OP_WINDOW_ACTIVATE_TAB
            profileID:owner->_shaarTabProfiles[tabID] tabID:tabID
              payload:@{@"schemaVersion": @1, @"tabID": tabID}
           completion:^(NSDictionary *, NSError *error) {
      ARCShaarRuntime *current = weakSelf;
      // Wait for the native completion task, after Chromium's tab-strip update
      // unwinds. Swift can then restore the page once rather than cycling
      // reconcile/activate to repair presentation.
      if (error || !current || !current->_shaarTabs[tabID] ||
          ![current->_shaarSelectedTabs[windowID] isEqualToString:tabID]) return;
      if (current.onTabActivated)
        current.onTabActivated(tabID, current->_shaarTabProfiles[tabID]);
    }];
  });
}

- (void)focusTabID:(NSString *)tabID {
  NSString *windowID = _shaarTabWindows[tabID];
  shaar_window *window = (shaar_window *)_shaarWindows[windowID].pointerValue;
  shaar_tab *tab = (shaar_tab *)_shaarTabs[tabID].pointerValue;
  if (!window || !tab) return;
  shaar_error error = EmptyError();
  _symbols.tab_view_focus(_shaarEngine, window, tab, &error);
}

- (BOOL)supportsNativePrint { return _symbols.tab_print != nullptr; }

- (BOOL)printTabID:(NSString *)tabID windowID:(NSString *)windowID profileID:(NSString *)profileID {
  if (!NSThread.isMainThread || !_shaarEngine || !_symbols.tab_print ||
      !tabID.length || !windowID.length || !profileID.length ||
      ![_shaarSelectedTabs[windowID] isEqualToString:tabID] ||
      ![_shaarTabWindows[tabID] isEqualToString:windowID] ||
      [_shaarTabProfiles[tabID] caseInsensitiveCompare:profileID] != NSOrderedSame) return NO;
  shaar_window *window = (shaar_window *)_shaarWindows[windowID].pointerValue;
  shaar_tab *tab = (shaar_tab *)_shaarTabs[tabID].pointerValue;
  if (!window || !tab) return NO;
  shaar_error error = EmptyError();
  return _symbols.tab_print(tab, &error) == SHAAR_OK;
}

- (void)clearActiveTabInWindowID:(NSString *)windowID {
  NSString *tabID = _shaarSelectedTabs[windowID];
  shaar_window *window = (shaar_window *)_shaarWindows[windowID].pointerValue;
  shaar_tab *tab = (shaar_tab *)_shaarTabs[tabID].pointerValue;
  if (window && tab) {
    shaar_error error = EmptyError();
    _symbols.tab_view_detach(_shaarEngine, window, tab, &error);
  }
  [_shaarSelectedTabs removeObjectForKey:windowID];
}

- (void)clearActiveTab { [self clearActiveTabInWindowID:_shaarPrimaryWindowID]; }
- (void)activateProfileID:(NSString *)profileID {
  [self activateProfileID:profileID windowID:_shaarPrimaryWindowID];
}
- (void)activateProfileID:(NSString *)profileID windowID:(NSString *)windowID {
  [self submitWindowID:windowID profileID:profileID
             operation:SHAAR_OP_WINDOW_SET_ACTIVE_PROFILE
               payload:@{@"schemaVersion": @1,
                         @"profileID": profileID.lowercaseString}];
}

- (BOOL)placeTabIDs:(NSArray<NSString *> *)tabIDs pinnedIDs:(NSArray<NSString *> *)pinnedIDs
          profileID:(NSString *)profileID windowID:(NSString *)windowID {
  return [self submitWindowID:windowID profileID:profileID
                   operation:SHAAR_OP_WINDOW_PLACE_TABS
                     payload:@{@"schemaVersion": @1, @"tabIDs": tabIDs,
                               @"pinnedIDs": pinnedIDs}];
}

- (BOOL)placeTabIDs:(NSArray<NSString *> *)tabIDs pinnedIDs:(NSArray<NSString *> *)pinnedIDs
          profileID:(NSString *)profileID {
  return [self placeTabIDs:tabIDs pinnedIDs:pinnedIDs profileID:profileID
                 windowID:_shaarPrimaryWindowID];
}

- (void)closeTabID:(NSString *)tabID {
  shaar_tab *tab = (shaar_tab *)_shaarTabs[tabID].pointerValue;
  if (!tab) return;
  shaar_error error = EmptyError();
  _symbols.tab_close(tab, &error);
}

- (void)discardTabID:(NSString *)tabID { [self closeTabID:tabID]; }

- (BOOL)tabLifecycleSupported {
  // Operations 208-211 arrive with ABI minor 11. An older engine must not
  // discard or freeze, even if a submit would return unsupported.
  return _symbols.abi_minor && _symbols.abi_minor() >= 11;
}

- (void)probeTabLifecycleForTabID:(NSString *)tabID completion:(void (^)(BOOL))completion {
  if (![self tabLifecycleSupported]) {
    ShaarFinishOnMain(completion, NO);
    return;
  }
  [self submitTabID:tabID operation:kShaarOpTabLifecycleGet
            payload:@{@"schemaVersion": @1}
         completion:^(NSDictionary *reply, NSError *error) {
    const BOOL capable = ShaarLifecycleProbeCapable(reply, error);
    if (!capable) {
      NSLog(@"Shaar lifecycle probe failed (ABI %u)",
            _symbols.abi_minor ? _symbols.abi_minor() : 0);
    }
    ShaarFinishOnMain(completion, capable);
  }];
}

- (void)sleepTabID:(NSString *)tabID reason:(NSString *)reason
        completion:(void (^)(BOOL))completion {
  if (![self tabLifecycleSupported]) {
    ShaarFinishOnMain(completion, NO);
    return;
  }
  NSString *discardReason = reason.length ? reason : @"proactive";
  NSLog(@"Shaar tab discard requested");
  [self submitTabID:tabID operation:kShaarOpTabDiscard
            payload:@{@"schemaVersion": @1, @"reason": discardReason}
         completion:^(NSDictionary *reply, NSError *error) {
    const BOOL accepted = ShaarLifecycleAccepted(reply, error, @[@"discarded"]);
    if (!accepted) {
      NSLog(@"Shaar tab discard refused");
    }
    ShaarFinishOnMain(completion, accepted);
  }];
}

- (void)wakeTabID:(NSString *)tabID completion:(void (^)(BOOL))completion {
  if (![self tabLifecycleSupported]) {
    ShaarFinishOnMain(completion, NO);
    return;
  }
  [self submitTabID:tabID operation:kShaarOpTabWake payload:@{@"schemaVersion": @1}
         completion:^(NSDictionary *reply, NSError *error) {
    ShaarFinishOnMain(completion, ShaarLifecycleAccepted(reply, error, @[@"active"]));
  }];
}

- (void)freezeTabID:(NSString *)tabID completion:(void (^)(BOOL))completion {
  if (![self tabLifecycleSupported]) {
    ShaarFinishOnMain(completion, NO);
    return;
  }
  [self submitTabID:tabID operation:kShaarOpTabFreeze payload:@{@"schemaVersion": @1}
         completion:^(NSDictionary *reply, NSError *error) {
    ShaarFinishOnMain(completion, ShaarLifecycleAccepted(reply, error, @[@"frozen", @"discarded"]));
  }];
}

- (BOOL)submitTabID:(NSString *)tabID operation:(shaar_operation)operation
            payload:(NSDictionary *)payload {
  NSString *windowID = _shaarTabWindows[tabID];
  shaar_window *window = (shaar_window *)_shaarWindows[windowID].pointerValue;
  shaar_tab *tab = (shaar_tab *)_shaarTabs[tabID].pointerValue;
  shaar_profile *profile = (shaar_profile *)_shaarProfiles[_shaarTabProfiles[tabID]].pointerValue;
  if (!window || !tab || !profile) return NO;
  NSData *json = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
  if (!json) return NO;
  shaar_scope scope = {};
  scope.size = sizeof(scope);
  scope.profile = profile;
  shaar_error error = EmptyError();
  return _symbols.submit(_shaarEngine, scope, window, tab, operation,
                         {(const char *)json.bytes, json.length}, _nextRequestID++,
                         IgnoreReply, nullptr, &error) == SHAAR_OK;
}

- (void)submitTabID:(NSString *)tabID operation:(shaar_operation)operation
            payload:(NSDictionary *)payload
         completion:(void (^)(NSDictionary *, NSError *))completion {
  NSString *windowID = _shaarTabWindows[tabID];
  shaar_window *window = (shaar_window *)_shaarWindows[windowID].pointerValue;
  shaar_tab *tab = (shaar_tab *)_shaarTabs[tabID].pointerValue;
  shaar_profile *profile = (shaar_profile *)_shaarProfiles[_shaarTabProfiles[tabID]].pointerValue;
  NSData *json = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
  if (!window || !tab || !profile || !json || !_shaarEngine) {
    completion(nil, ShaarError(@"Shaar tab operation is unavailable."));
    return;
  }
  shaar_scope scope = {};
  scope.size = sizeof(scope);
  scope.profile = profile;
  void (^reply)(NSDictionary *, NSError *) = [completion copy];
  void *context = (__bridge_retained void *)reply;
  shaar_error error = EmptyError();
  shaar_error_code status = _symbols.submit(
      _shaarEngine, scope, window, tab, operation,
      {(const char *)json.bytes, json.length}, _nextRequestID++,
      [](void *context, const shaar_result *result) {
        void (^finish)(NSDictionary *, NSError *) = (__bridge_transfer id)context;
        if (!result || result->error.code != SHAAR_OK) {
          if (!result) {
            finish(nil, ShaarError(@"Shaar tab operation failed."));
            return;
          }
          NSString *message = String(result->error.message);
          if (message.length == 0) message = @"Shaar tab operation failed.";
          finish(nil, ShaarStatusError(message, result->error.code));
          return;
        }
        NSData *bytes = [NSData dataWithBytes:result->payload_json.data ?: ""
                                      length:result->payload_json.size];
        NSDictionary *value = bytes.length
            ? [NSJSONSerialization JSONObjectWithData:bytes options:0 error:nil] : @{};
        if (![value isKindOfClass:NSDictionary.class]) {
          finish(nil, ShaarError(@"Shaar returned an invalid tab response."));
          return;
        }
        finish(value, nil);
      }, context, &error);
  if (status != SHAAR_OK) {
    CFBridgingRelease(context);
    completion(nil, ShaarError(@"Shaar rejected the tab operation."));
  }
}

- (void)submitProfileID:(NSString *)profileID operation:(shaar_operation)operation
                payload:(NSDictionary *)payload
             completion:(void (^)(NSDictionary *, NSError *))completion {
  shaar_profile *profile = (shaar_profile *)_shaarProfiles[profileID].pointerValue;
  NSData *json = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
  if (!profile || !json || !_shaarEngine) {
    completion(nil, ShaarError(@"Shaar profile operation is unavailable."));
    return;
  }
  shaar_scope scope = {};
  scope.size = sizeof(scope);
  scope.profile = profile;
  void (^reply)(NSDictionary *, NSError *) = [completion copy];
  void *context = (__bridge_retained void *)reply;
  shaar_error error = EmptyError();
  shaar_error_code status = _symbols.submit(
      _shaarEngine, scope, nullptr, nullptr, operation,
      {(const char *)json.bytes, json.length}, _nextRequestID++,
      [](void *context, const shaar_result *result) {
        void (^finish)(NSDictionary *, NSError *) = (__bridge_transfer id)context;
        if (!result || result->error.code != SHAAR_OK) {
          finish(nil, ShaarError(@"Shaar profile operation failed."));
          return;
        }
        NSData *bytes = [NSData dataWithBytes:result->payload_json.data ?: ""
                                      length:result->payload_json.size];
        NSDictionary *value = bytes.length
            ? [NSJSONSerialization JSONObjectWithData:bytes options:0 error:nil] : @{};
        if (![value isKindOfClass:NSDictionary.class]) {
          finish(nil, ShaarError(@"Shaar returned an invalid profile response."));
          return;
        }
        finish(value, nil);
      }, context, &error);
  if (status != SHAAR_OK) {
    CFBridgingRelease(context);
    completion(nil, ShaarError(@"Shaar rejected the profile operation."));
  }
}

- (BOOL)submitWindowID:(NSString *)windowID profileID:(NSString *)profileID
             operation:(shaar_operation)operation payload:(NSDictionary *)payload {
  shaar_window *window = (shaar_window *)_shaarWindows[windowID].pointerValue;
  shaar_profile *profile = (shaar_profile *)_shaarProfiles[profileID].pointerValue;
  if (!window || !profile) return NO;
  NSData *json = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
  if (!json) return NO;
  shaar_scope scope = {};
  scope.size = sizeof(scope);
  scope.profile = profile;
  shaar_error error = EmptyError();
  return _symbols.submit(_shaarEngine, scope, window, nullptr, operation,
                         {(const char *)json.bytes, json.length}, _nextRequestID++,
                         IgnoreReply, nullptr, &error) == SHAAR_OK;
}

- (BOOL)navigateTabID:(NSString *)tabID profileID:(NSString *)profileID
             windowID:(NSString *)windowID url:(NSString *)url {
  if (![_shaarTabProfiles[tabID] isEqualToString:profileID] ||
      ![_shaarTabWindows[tabID] isEqualToString:windowID]) return NO;
  return [self submitTabID:tabID operation:SHAAR_OP_TAB_NAVIGATE
                  payload:@{@"schemaVersion": @1, @"url": url,
                            @"userInitiated": @YES}];
}

- (void)goBackInTabID:(NSString *)tabID {
  [self submitTabID:tabID operation:SHAAR_OP_TAB_GO
            payload:@{@"schemaVersion": @1, @"direction": @"back"}];
}
- (void)goForwardInTabID:(NSString *)tabID {
  [self submitTabID:tabID operation:SHAAR_OP_TAB_GO
            payload:@{@"schemaVersion": @1, @"direction": @"forward"}];
}
- (void)reloadTabID:(NSString *)tabID {
  [self reloadTabID:tabID profileID:_shaarTabProfiles[tabID] mode:ARCPageReloadModeNormal];
}
- (BOOL)reloadTabID:(NSString *)tabID profileID:(NSString *)profileID {
  return [self reloadTabID:tabID profileID:profileID mode:ARCPageReloadModeNormal];
}
- (BOOL)reloadTabID:(NSString *)tabID profileID:(NSString *)profileID
                mode:(ARCPageReloadMode)mode {
  if (![_shaarTabProfiles[tabID] isEqualToString:profileID] ||
      mode == ARCPageReloadModeNewRenderer) return NO;
  return [self submitTabID:tabID operation:SHAAR_OP_TAB_RELOAD
                  payload:@{@"schemaVersion": @1,
                            @"mode": mode == ARCPageReloadModeBypassingCache ?
                                @"bypass_cache" : @"normal"}];
}

- (NSImage *)faviconForTabID:(NSString *)tabID profileID:(NSString *)profileID
                    windowID:(NSString *)windowID {
  if (!_shaarEngine || ![_shaarTabProfiles[tabID] isEqualToString:profileID] ||
      ![_shaarTabWindows[tabID] isEqualToString:windowID]) return nil;
  shaar_profile *profile = (shaar_profile *)_shaarProfiles[profileID].pointerValue;
  shaar_window *window = (shaar_window *)_shaarWindows[windowID].pointerValue;
  shaar_tab *tab = (shaar_tab *)_shaarTabs[tabID].pointerValue;
  if (!profile || !window || !tab) return nil;
  shaar_scope scope = {.size = sizeof(scope), .profile = profile};
  shaar_bytes png = {};
  shaar_error error = EmptyError();
  if (_symbols.tab_favicon_png(_shaarEngine, scope, window, tab, &png, &error) != SHAAR_OK ||
      !png.data || !png.size) return nil;
  return [[NSImage alloc] initWithData:[NSData dataWithBytes:png.data length:png.size]];
}

- (int)chromeWindowIDForProfileID:(NSString *)profileID windowID:(NSString *)windowID {
  return -1;  // Native Chromium window IDs are not part of the Shaar ABI.
}

- (int)nativeTabIDForID:(NSString *)tabID {
  return -1;  // Chromium's integer tab ids are not part of the Shaar ABI.
}

- (void)resolveExternalAppRequestID:(NSString *)requestID accepted:(BOOL)accepted {
  // No Shaar external-app request ABI exists yet.
}

- (BOOL)findInTabID:(NSString *)tabID profileID:(NSString *)profileID
         requestID:(NSString *)requestID text:(NSString *)text forward:(BOOL)forward {
  NSString *windowID = _shaarTabWindows[tabID];
  if (!text.length || ![[NSUUID alloc] initWithUUIDString:requestID] ||
      ![_shaarTabProfiles[tabID] isEqualToString:profileID] ||
      ![_shaarSelectedTabs[windowID] isEqualToString:tabID]) return NO;
  NSString *previous = _shaarFindRequests[tabID];
  if (previous) [_shaarFindTokens removeObjectForKey:previous];
  NSString *nativeID = [NSString stringWithFormat:@"%llu", _nextRequestID];
  _shaarFindTokens[nativeID] = requestID;
  _shaarFindRequests[tabID] = nativeID;
  BOOL accepted = [self submitTabID:tabID operation:SHAAR_OP_TAB_FIND
                           payload:@{@"schemaVersion": @1, @"query": text,
                                     @"forward": @(forward)}];
  if (!accepted) {
    [_shaarFindTokens removeObjectForKey:nativeID];
    [_shaarFindRequests removeObjectForKey:tabID];
  }
  return accepted;
}

- (BOOL)performPageZoomAction:(NSString *)action tabID:(NSString *)tabID
                     profileID:(NSString *)profileID {
  NSString *windowID = _shaarTabWindows[tabID];
  if (![@[@"get", @"in", @"out", @"reset"] containsObject:action] ||
      ![_shaarTabProfiles[tabID] isEqualToString:profileID] ||
      ![_shaarSelectedTabs[windowID] isEqualToString:tabID]) return NO;
  return [self submitTabID:tabID operation:SHAAR_OP_TAB_ZOOM
                   payload:@{@"schemaVersion": @1, @"action": action}];
}

- (void)stopFindingInTabID:(NSString *)tabID {
  NSString *nativeID = _shaarFindRequests[tabID];
  if (!nativeID) return;
  [_shaarFindRequests removeObjectForKey:tabID];
  [_shaarFindTokens removeObjectForKey:nativeID];
  if (_shaarTabs[tabID])
    [self submitTabID:tabID operation:SHAAR_OP_TAB_STOP_FIND
              payload:@{@"schemaVersion": @1, @"selection": @"keep"}];
}

- (void)evaluateInTabID:(NSString *)tabID script:(NSString *)script
            completion:(void (^)(NSString *))completion {
  NSString *profileID = _shaarTabProfiles[tabID];
  NSString *windowID = _shaarTabWindows[tabID];
  if (!script.length || ![self shaarDevToolsOwnsTabID:tabID profileID:profileID
                                           windowID:windowID]) {
    completion(nil);
    return;
  }
  [self shaarDevToolsCall:@"Runtime.evaluate"
                  params:@{@"expression": script, @"returnByValue": @YES}
              capability:SHAAR_DEVTOOLS_CAPABILITY_DEVELOPER tabID:tabID
               profileID:profileID windowID:windowID
              completion:^(NSDictionary *result, NSError *error) {
    NSDictionary *remote = [result[@"result"] isKindOfClass:NSDictionary.class]
                             ? result[@"result"] : nil;
    id value = remote[@"value"];
    if (error || result[@"exceptionDetails"] || !value) {
      completion(nil);
      return;
    }
    NSData *json = [NSJSONSerialization dataWithJSONObject:value
                                               options:NSJSONWritingFragmentsAllowed error:nil];
    completion(json ? [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding] : nil);
  }];
}

- (void)bookmarksForProfileID:(NSString *)profileID
                  completion:(void (^)(NSDictionary *, NSError *))completion {
  [self submitProfileID:profileID operation:SHAAR_OP_BOOKMARK_TREE
                payload:@{@"schemaVersion": @1}
             completion:^(NSDictionary *result, NSError *error) {
    if (error || ![result[@"bar"] isKindOfClass:NSDictionary.class] ||
        ![result[@"other"] isKindOfClass:NSDictionary.class]) {
      completion(nil, error ?: ShaarError(@"Invalid Shaar bookmark tree."));
      return;
    }
    completion(result, nil);
  }];
}

- (void)applyBookmarkOperation:(NSDictionary *)operation profileID:(NSString *)profileID
                    completion:(void (^)(NSError *))completion {
  if (![operation isKindOfClass:NSDictionary.class]) {
    completion(ShaarError(@"Invalid Shaar bookmark action."));
    return;
  }
  [self submitProfileID:profileID operation:SHAAR_OP_BOOKMARK_APPLY
                payload:@{@"schemaVersion": @1, @"ops": @[operation]}
             completion:^(NSDictionary *result, NSError *error) {
    NSArray *invalid = result[@"invalid"];
    BOOL confirmed = [result[@"applied"] isEqual:@1] &&
                     [result[@"skipped"] isEqual:@0] &&
                     [invalid isKindOfClass:NSArray.class] && !invalid.count;
    if (error) { completion(error); return; }
    completion(confirmed ? nil : ShaarError(@"Shaar did not confirm the bookmark action."));
  }];
}

- (void)historyForProfileID:(NSString *)profileID limit:(NSInteger)limit
                 completion:(void (^)(NSArray<NSDictionary *> *, NSError *))completion {
  if (limit < 1 || limit > 5000) {
    completion(nil, ShaarError(@"Invalid Shaar history limit."));
    return;
  }
  // The engine rejects queries that fill its maxUrls * maxVisitsPerUrl bound.
  // Preserve the caller's URL limit and leave bounded room for repeated visits.
  NSInteger visitsPerURL = HistoryQueryVisitsPerURL(limit);
  [self submitProfileID:profileID operation:SHAAR_OP_HISTORY_QUERY
                payload:@{@"schemaVersion": @1, @"maxUrls": @(limit),
                          @"maxVisitsPerUrl": @(visitsPerURL)}
             completion:^(NSDictionary *result, NSError *error) {
    NSArray *entries = result[@"entries"];
    if (error || ![entries isKindOfClass:NSArray.class]) {
      completion(nil, error ?: ShaarError(@"Invalid Shaar history response."));
      return;
    }
    NSMutableArray<NSDictionary *> *rows = [NSMutableArray arrayWithCapacity:entries.count];
    for (id entry in entries) {
      if ((NSInteger)rows.count >= limit) break;
      if (![entry isKindOfClass:NSDictionary.class] ||
          ![entry[@"url"] isKindOfClass:NSString.class] ||
          ![entry[@"title"] isKindOfClass:NSString.class] ||
          ![entry[@"visitCount"] isKindOfClass:NSNumber.class] ||
          ![entry[@"visits"] isKindOfClass:NSArray.class]) {
        completion(nil, ShaarError(@"Invalid Shaar history entry."));
        return;
      }
      NSArray *visits = entry[@"visits"];
      NSArray *latestVisit = visits.count ? @[visits.firstObject] : @[];
      [rows addObject:@{@"u": entry[@"url"], @"t": entry[@"title"],
                        @"n": entry[@"visitCount"], @"v": latestVisit}];
    }
    completion(rows, nil);
  }];
}

- (void)deleteHistoryURL:(NSString *)url profileID:(NSString *)profileID
              completion:(void (^)(NSError *))completion {
  NSURL *address = [NSURL URLWithString:url];
  if (![@[@"http", @"https"] containsObject:address.scheme.lowercaseString]) {
    completion(ShaarError(@"Invalid Shaar history address."));
    return;
  }
  [self submitProfileID:profileID operation:SHAAR_OP_HISTORY_DELETE
                payload:@{@"schemaVersion": @1, @"urls": @[url]}
             completion:^(NSDictionary *result, NSError *error) {
    if (error) { completion(error); return; }
    if (![result[@"deleted"] isKindOfClass:NSNumber.class]) {
      completion(ShaarError(@"Shaar did not confirm history deletion."));
      return;
    }
    if (self.onLibraryChanged) self.onLibraryChanged(profileID, @"history");
    completion(nil);
  }];
}

- (void)importHistoryRows:(NSArray<NSDictionary *> *)rows source:(NSString *)source
                profileID:(NSString *)profileID completion:(void (^)(NSError *))completion {
  if (![@[@"safari", @"chrome", @"arc", @"firefox"] containsObject:source] ||
      !rows.count || rows.count > 5000) {
    completion(ShaarError(@"Unsupported Shaar history import."));
    return;
  }
  NSMutableArray<NSDictionary *> *pages = [NSMutableArray arrayWithCapacity:rows.count];
  for (NSDictionary *row in rows) {
    if (![row isKindOfClass:NSDictionary.class] ||
        ![row[@"u"] isKindOfClass:NSString.class] ||
        ![row[@"t"] isKindOfClass:NSString.class] ||
        ![row[@"v"] isKindOfClass:NSArray.class]) {
      completion(ShaarError(@"Invalid Shaar history import row."));
      return;
    }
    [pages addObject:@{@"url": row[@"u"], @"title": row[@"t"],
                       @"visits": row[@"v"]}];
  }
  [self submitProfileID:profileID operation:SHAAR_OP_HISTORY_INSERT
                payload:@{@"schemaVersion": @1, @"source": source, @"pages": pages}
             completion:^(NSDictionary *result, NSError *error) {
    NSArray *rejected = result[@"rejected"];
    BOOL confirmed = [result[@"accepted"] isEqual:@(rows.count)] &&
                     [rejected isKindOfClass:NSArray.class] && !rejected.count;
    if (error) { completion(error); return; }
    if (!confirmed) {
      completion(ShaarError(@"Shaar did not import every history row."));
      return;
    }
    if (self.onLibraryChanged) self.onLibraryChanged(profileID, @"history");
    completion(nil);
  }];
}

- (BOOL)shaarSubmitExtensionOperation:(shaar_operation)operation
                           profileID:(NSString *)profileID tabID:(NSString *)tabID
                  allowsProfileOnly:(BOOL)allowsProfileOnly
                             payload:(NSDictionary *)payload
                          completion:(void (^)(NSString *, shaar_error_code))completion {
  return [self shaarSubmitExtensionOperation:operation profileID:profileID tabID:tabID
                         allowsProfileOnly:allowsProfileOnly payload:payload
                                  completion:completion syncCode:NULL];
}

- (BOOL)shaarSubmitExtensionOperation:(shaar_operation)operation
                           profileID:(NSString *)profileID tabID:(NSString *)tabID
                             payload:(NSDictionary *)payload
                          completion:(void (^)(NSString *, shaar_error_code))completion
                            syncCode:(shaar_error_code *)syncCode {
  return [self shaarSubmitExtensionOperation:operation profileID:profileID tabID:tabID
                         allowsProfileOnly:NO payload:payload completion:completion
                                  syncCode:syncCode];
}

- (BOOL)shaarSubmitExtensionOperation:(shaar_operation)operation
                           profileID:(NSString *)profileID tabID:(NSString *)tabID
                  allowsProfileOnly:(BOOL)allowsProfileOnly
                             payload:(NSDictionary *)payload
                          completion:(void (^)(NSString *, shaar_error_code))completion
                            syncCode:(shaar_error_code *)syncCode {
  shaar_profile *profile = (shaar_profile *)_shaarProfiles[profileID].pointerValue;
  NSString *windowID = tabID ? _shaarTabWindows[tabID] : _shaarPrimaryWindowID;
  shaar_window *window = (shaar_window *)_shaarWindows[windowID].pointerValue;
  shaar_tab *tab = tabID ? (shaar_tab *)_shaarTabs[tabID].pointerValue : nullptr;
  const BOOL profileOnly = allowsProfileOnly && !tabID;
  if (!_shaarEngine || !profile || (!profileOnly && !window) || (tabID && (!tab ||
      ![_shaarTabProfiles[tabID] isEqualToString:profileID]))) {
    if (syncCode) *syncCode = SHAAR_NOT_READY;
    return NO;
  }
  NSData *json = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
  if (!json) {
    if (syncCode) *syncCode = SHAAR_INVALID_ARGUMENT;
    return NO;
  }
  shaar_scope scope = {};
  scope.size = sizeof(scope);
  scope.profile = profile;
  void *context = (__bridge_retained void *)[completion copy];
  shaar_error error = EmptyError();
  shaar_error_code status = _symbols.submit(
      _shaarEngine, scope, window, tab, operation,
      {(const char *)json.bytes, json.length}, _nextRequestID++,
      [](void *context, const shaar_result *result) {
        void (^reply)(NSString *, shaar_error_code) = (__bridge_transfer id)context;
        NSString *json = result ? String(result->payload_json) : nil;
        reply(json, result ? result->error.code : SHAAR_CHROMIUM_ERROR);
      }, context, &error);
  if (status != SHAAR_OK) {
    if (syncCode) *syncCode = error.code == SHAAR_OK ? SHAAR_CHROMIUM_ERROR : error.code;
    CFBridgingRelease(context);
    return NO;
  }
  return YES;
}

- (BOOL)shaarOwnsSelectedTabID:(NSString *)tabID profileID:(NSString *)profileID {
  NSString *windowID = _shaarTabWindows[tabID];
  return windowID && [_shaarTabProfiles[tabID] isEqualToString:profileID] &&
         [_shaarSelectedTabs[windowID] isEqualToString:tabID];
}

- (NSString *)shaarProfileIDForTabID:(NSString *)tabID {
  return _shaarTabProfiles[tabID];
}

- (NSString *)shaarWindowIDForTabID:(NSString *)tabID {
  return _shaarTabWindows[tabID];
}

- (NSString *)shaarProfileIDForWindowID:(NSString *)windowID {
  NSString *selectedTabID = _shaarSelectedTabs[windowID];
  return _shaarTabProfiles[selectedTabID];
}

- (NSURL *)shaarProfileDirectoryForID:(NSString *)profileID {
  shaar_profile *profile = (shaar_profile *)_shaarProfiles[profileID].pointerValue;
  if (!profile) return nil;
  auto getPath = reinterpret_cast<decltype(&shaar_profile_get_path)>(
      dlsym(_shaarLibrary, "shaar_profile_get_path"));
  if (!getPath) return nil;
  shaar_bytes path = {};
  shaar_error error = EmptyError();
  if (getPath(profile, &path, &error) != SHAAR_OK) return nil;
  NSString *value = String(path);
  return value.length ? [NSURL fileURLWithPath:value isDirectory:YES] : nil;
}

- (NSView *)shaarExtensionPopupViewForID:(NSString *)popupID
                                 windowID:(NSString *)windowID {
  shaar_window *window = (shaar_window *)_shaarWindows[windowID].pointerValue;
  if (!_shaarEngine || !window || !popupID.length) return nil;
  auto popupView = reinterpret_cast<decltype(&shaar_extension_popup_view)>(
      dlsym(_shaarLibrary, "shaar_extension_popup_view"));
  return popupView ? (__bridge NSView *)popupView(_shaarEngine, window, Bytes(popupID)) : nil;
}

- (void)quit {
  if (!_shaarEngine) return;
  _shaarQuitting = YES;
  if (self.onQuitRequested) self.onQuitRequested();
  shaar_error error = EmptyError();
  shaar_error_code status = _symbols.request_quit(_shaarEngine, &error);
  if (status != SHAAR_OK && status != SHAAR_SHUTTING_DOWN) {
    _shaarQuitting = NO;
    if (self.onQuitCancelled) self.onQuitCancelled();
  }
}

- (void)resolveInstallRequestID:(NSString *)requestID accepted:(BOOL)accepted {
  NSDictionary *pending = _shaarInstallRequests[requestID];
  if (![pending isKindOfClass:NSDictionary.class]) {
    if (self.onNotice) {
      self.onNotice(ARCBridgeLocalizedString(
          @"Extension installation is unsupported by this Shaar engine."));
    }
    return;
  }
  [_shaarInstallRequests removeObjectForKey:requestID];
  NSString *profileID = pending[@"profileID"];
  NSString *tabID = pending[@"tabID"];
  BOOL submitted = [self shaarSubmitExtensionOperation:SHAAR_OP_EXTENSION_INSTALL_DECISION
      profileID:profileID tabID:tabID allowsProfileOnly:NO
      payload:@{@"schemaVersion": @1, @"consentRequestId": requestID, @"accepted": @(accepted)}
      completion:^(NSString *json, shaar_error_code code) {
        if (code == SHAAR_OK && accepted) {
          [self shaarForgetExtensionListForProfileID:profileID];
          return;
        }
        if (code != SHAAR_OK && self.onNotice) {
          self.onNotice(ARCBridgeLocalizedString(
              @"This Shaar engine cannot install extensions yet."));
        }
      }];
  if (!submitted && self.onNotice) {
    self.onNotice(ARCBridgeLocalizedString(@"This Shaar engine cannot install extensions yet."));
  }
}

- (void)cancelExtensionInstallRequestsForTabID:(NSString *)tabID {
  for (NSString *requestID in [_shaarInstallRequests allKeys]) {
    NSDictionary *pending = _shaarInstallRequests[requestID];
    if (![pending[@"tabID"] isEqualToString:tabID]) continue;
    [_shaarInstallRequests removeObjectForKey:requestID];
    [self shaarSubmitExtensionOperation:SHAAR_OP_EXTENSION_INSTALL_DECISION
        profileID:pending[@"profileID"] tabID:tabID allowsProfileOnly:NO
        payload:@{@"schemaVersion": @1, @"consentRequestId": requestID, @"accepted": @NO}
        completion:^(NSString *json, shaar_error_code code) {}];
  }
}

- (void)receiveExtensionInstallEvent:(const shaar_event *)event
                             payload:(NSDictionary *)payload
                           profileID:(NSString *)profileID
                               tabID:(NSString *)tabID {
  NSString *windowID = String(event->window_id);
  NSString *requestID = payload[@"requestId"];
  if (![requestID isKindOfClass:NSString.class] || !requestID.length || requestID.length > 128
      || _shaarInstallRequests[requestID]) return;
  NSString *extensionID = payload[@"id"];
  NSString *name = payload[@"name"];
  NSString *version = payload[@"version"];
  NSString *sourceURL = payload[@"sourceURL"];
  NSString *type = payload[@"type"];
  NSURL *page = [sourceURL isKindOfClass:NSString.class] ? [NSURL URLWithString:sourceURL] : nil;
  NSString *scheme = page.scheme.lowercaseString;
  BOOL usable = [payload[@"schemaVersion"] isEqual:@1]
      && [@[@"install", @"permissions", @"re-enable", @"repair"] containsObject:type]
      && [self shaarExtensionIDIsAcceptable:extensionID]
      && [name isKindOfClass:NSString.class]
      && name.length && [name lengthOfBytesUsingEncoding:NSUTF8StringEncoding] <= 1024
      && [version isKindOfClass:NSString.class]
      && version.length && [version lengthOfBytesUsingEncoding:NSUTF8StringEncoding] <= 128
      && page.host.length
      && ([scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"])
      && [self shaarInstallList:payload[@"permissions"] maxCount:128 maxItem:8192]
      && [self shaarInstallList:payload[@"hostPermissions"] maxCount:128 maxItem:8192]
      && _shaarTabs[tabID]
      && [profileID isEqualToString:_shaarTabProfiles[tabID]]
      && [windowID isEqualToString:_shaarTabWindows[tabID]];
  if (!usable) {
    if (_shaarTabs[tabID] && [profileID isEqualToString:_shaarTabProfiles[tabID]]) {
      [self shaarSubmitExtensionOperation:SHAAR_OP_EXTENSION_INSTALL_DECISION
          profileID:profileID tabID:tabID allowsProfileOnly:NO
          payload:@{@"schemaVersion": @1, @"consentRequestId": requestID, @"accepted": @NO}
          completion:^(NSString *json, shaar_error_code code) {}];
    }
    return;
  }
  _shaarInstallRequests[requestID] = @{@"profileID": profileID, @"tabID": tabID};
  NSMutableDictionary *request = [payload mutableCopy];
  request[@"profileID"] = profileID;
  request[@"tabID"] = tabID;
  request[@"windowID"] = windowID;
  if (self.onInstallRequest) self.onInstallRequest(request);
  else [self resolveInstallRequestID:requestID accepted:NO];
}

- (BOOL)shaarExtensionIDIsAcceptable:(NSString *)extensionID {
  if (![extensionID isKindOfClass:NSString.class] || extensionID.length != 32) return NO;
  for (NSUInteger index = 0; index < extensionID.length; index++) {
    unichar character = [extensionID characterAtIndex:index];
    if (character < 'a' || character > 'p') return NO;
  }
  return YES;
}

- (BOOL)shaarInstallList:(id)value maxCount:(NSUInteger)maxCount maxItem:(NSUInteger)maxItem {
  if (!value) return YES;
  if (![value isKindOfClass:NSArray.class] || [(NSArray *)value count] > maxCount) return NO;
  for (id item in (NSArray *)value) {
    if (![item isKindOfClass:NSString.class] || ![(NSString *)item length]) return NO;
    if ([(NSString *)item lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > maxItem) return NO;
  }
  return YES;
}

- (void)resolveWebsiteMediaRequestID:(NSString *)requestID accepted:(BOOL)accepted {
  if (!_shaarMediaConsentAvailable) {
    if (self.onNotice) self.onNotice(@"Website media approval is unsupported by this Shaar engine.");
    return;
  }
  NSString *tabID = _shaarMediaRequests[requestID];
  if (!tabID) return;
  [_shaarMediaRequests removeObjectForKey:requestID];
  [self submitTabID:tabID operation:SHAAR_OP_MEDIA_PERMISSION_DECISION
            payload:@{@"schemaVersion": @1, @"id": requestID,
                      @"accepted": @(accepted)}];
}

- (BOOL)desktopCaptureField:(id)value maxLength:(NSUInteger)maxLength {
  if (![value isKindOfClass:NSString.class]) return NO;
  NSUInteger length = [(NSString *)value length];
  return length > 0 && length <= maxLength;
}

- (void)receiveDesktopCaptureDismissal:(NSDictionary *)payload tabID:(NSString *)tabID {
  if (!_shaarDesktopCaptureAvailable) return;
  NSString *requestID = [payload[@"id"] isKindOfClass:NSString.class]
      ? payload[@"id"] : payload[@"promptID"];
  if (![payload[@"schemaVersion"] isEqual:@1] ||
      ![requestID isKindOfClass:NSString.class] ||
      ![_shaarCaptureRequests[requestID] isEqualToString:tabID]) return;
  [_shaarCaptureRequests removeObjectForKey:requestID];
  if (self.onDesktopCaptureDismissed) self.onDesktopCaptureDismissed(requestID);
}

- (void)receiveDesktopCaptureRequest:(const shaar_event *)event
                             payload:(NSDictionary *)payload
                               tabID:(NSString *)tabID
                           profileID:(NSString *)profileID {
  if (!_shaarDesktopCaptureAvailable || event->session_id.size) return;
  NSString *windowID = String(event->window_id);
  NSString *requestID = [payload[@"id"] isKindOfClass:NSString.class]
      ? payload[@"id"] : payload[@"promptID"];
  BOOL ownsTab = _shaarTabs[tabID] &&
      [profileID isEqualToString:_shaarTabProfiles[tabID]] &&
      [windowID isEqualToString:_shaarTabWindows[tabID]];
  BOOL validPromptID = [requestID isKindOfClass:NSString.class] &&
      requestID.length <= 64 && [[NSUUID alloc] initWithUUIDString:requestID];
  if (!validPromptID) return;
  if (_shaarCaptureRequests[requestID]) return;
  if (!ownsTab) {
    // The event identity is untrusted here, but the registered tab mapping is
    // authoritative. Cancel a valid pending prompt through that mapping so a
    // malformed ownership tuple does not leave Chromium waiting for its timeout.
    if (_shaarTabs[tabID] && _shaarTabProfiles[tabID] && _shaarTabWindows[tabID]) {
      _shaarCaptureRequests[requestID] = tabID;
      [self resolveDesktopCaptureRequestID:requestID sourceID:nil];
    }
    return;
  }
  if (![payload[@"schemaVersion"] isEqual:@1] ||
      ![self desktopCaptureField:payload[@"origin"] maxLength:2048] ||
      ![self desktopCaptureField:payload[@"pageURL"] maxLength:4096] ||
      ![self desktopCaptureField:payload[@"frameID"] maxLength:256] ||
      (payload[@"sourceTypes"] &&
       ![payload[@"sourceTypes"] isKindOfClass:NSArray.class])) {
    _shaarCaptureRequests[requestID] = tabID;
    [self resolveDesktopCaptureRequestID:requestID sourceID:nil];
    return;
  }
  _shaarCaptureRequests[requestID] = tabID;
  NSMutableDictionary *request = [payload mutableCopy];
  request[@"id"] = requestID;
  request[@"profileID"] = profileID;
  request[@"tabID"] = tabID;
  request[@"windowID"] = windowID;
  if (self.onDesktopCaptureRequest) {
    self.onDesktopCaptureRequest(request);
  } else {
    [self resolveDesktopCaptureRequestID:requestID sourceID:nil];
  }
}

- (void)resolveDeviceChooserRequestID:(NSString *)requestID optionID:(NSString *)optionID {
  if (!_shaarDeviceChooserAvailable) return;
  NSString *tabID = _shaarDeviceChooserRequests[requestID];
  if (!tabID) return;
  [_shaarDeviceChooserRequests removeObjectForKey:requestID];
  BOOL select = optionID.length > 0;
  NSMutableDictionary *payload = [@{
    @"schemaVersion": @1,
    @"id": requestID,
    @"action": select ? @"select" : @"cancel",
  } mutableCopy];
  if (select) payload[@"optionId"] = optionID;
  [self submitTabID:tabID operation:kShaarDeviceChooserDecision payload:payload];
}

- (void)receiveWebShareRequest:(const shaar_event *)event
                       payload:(NSDictionary *)payload
                         tabID:(NSString *)tabID
                     profileID:(NSString *)profileID {
  if (!_shaarWebShareAvailable || event->session_id.size) return;
  NSString *windowID = String(event->window_id);
  NSString *requestID = payload[@"id"];
  if (![requestID isKindOfClass:NSString.class] || requestID.length > 64 ||
      ![[NSUUID alloc] initWithUUIDString:requestID] ||
      _shaarShareRequests[requestID]) return;
  if (!_shaarTabs[tabID] ||
      ![profileID isEqualToString:_shaarTabProfiles[tabID]] ||
      ![windowID isEqualToString:_shaarTabWindows[tabID]]) {
    if (_shaarShareReply && requestID.UTF8String)
      _shaarShareReply(requestID.UTF8String, 0);
    return;
  }
  _shaarShareRequests[requestID] = tabID;
  id activationValue = payload[@"userActivated"];
  BOOL userActivated = [activationValue isKindOfClass:NSNumber.class] &&
      CFGetTypeID((__bridge CFTypeRef)activationValue) == CFBooleanGetTypeID() &&
      [activationValue boolValue];
  if (![payload[@"schemaVersion"] isEqual:@1] || !userActivated ||
      ![self desktopCaptureField:payload[@"origin"] maxLength:2048] ||
      ![self desktopCaptureField:payload[@"pageURL"] maxLength:4096] ||
      ![self desktopCaptureField:payload[@"frameID"] maxLength:256]) {
    [self resolveWebShareRequestID:requestID outcome:@"cancelled"];
    return;
  }
  NSMutableDictionary *request = [payload mutableCopy];
  request[@"profileID"] = profileID;
  request[@"tabID"] = tabID;
  request[@"windowID"] = windowID;
  if (self.onWebShareRequest) {
    self.onWebShareRequest(request);
  } else {
    [self resolveWebShareRequestID:requestID outcome:@"cancelled"];
  }
}

- (void)resolveWebShareRequestID:(NSString *)requestID outcome:(NSString *)outcome {
  if (!_shaarWebShareAvailable) return;
  NSString *tabID = _shaarShareRequests[requestID];
  if (!tabID) return;
  [_shaarShareRequests removeObjectForKey:requestID];
  if (!_shaarShareReply || !requestID.UTF8String) return;
  _shaarShareReply(requestID.UTF8String, [outcome isEqualToString:@"shared"] ? 1 : 0);
}

- (void)receivePrintRequest:(const shaar_event *)event
                    payload:(NSDictionary *)payload
                      tabID:(NSString *)tabID
                  profileID:(NSString *)profileID {
  if (!_shaarPrintAvailable) return;
  NSString *requestID = payload[@"id"];
  if (![requestID isKindOfClass:NSString.class] || requestID.length > 64 ||
      ![[NSUUID alloc] initWithUUIDString:requestID] || _shaarPrintRequests[requestID]) return;
  _shaarPrintRequests[requestID] = tabID ?: @"";
  NSString *windowID = String(event->window_id);
  if (event->session_id.size || ![payload[@"schemaVersion"] isEqual:@1] ||
      !_shaarTabs[tabID] ||
      ![profileID isEqualToString:_shaarTabProfiles[tabID]] ||
      ![windowID isEqualToString:_shaarTabWindows[tabID]] ||
      !ShaarPrintField(payload[@"pageURL"], 4096, YES) ||
      !ShaarPrintField(payload[@"origin"], 2048, YES) ||
      !ShaarPrintField(payload[@"frameID"], 256, YES) ||
      !ShaarPrintField(payload[@"title"], 2048, NO)) {
    [self resolvePrintRequestID:requestID accepted:NO];
    return;
  }
  NSMutableDictionary *request = [payload mutableCopy];
  request[@"profileID"] = profileID;
  request[@"tabID"] = tabID;
  request[@"windowID"] = windowID;
  if (self.onPrintRequest) {
    self.onPrintRequest(request);
  } else {
    [self resolvePrintRequestID:requestID accepted:NO];
  }
}

- (void)receivePrivatePrintRequest:(NSDictionary *)payload
                         contextID:(NSString *)contextID
                         profileID:(NSString *)profileID
                          windowID:(NSString *)windowID
                            tabID:(NSString *)tabID {
  if (!_shaarPrintAvailable) return;
  NSString *requestID = payload[@"id"];
  if (![requestID isKindOfClass:NSString.class] || requestID.length > 64 ||
      ![[NSUUID alloc] initWithUUIDString:requestID] || _shaarPrintRequests[requestID]) return;
  _shaarPrintRequests[requestID] = tabID ?: @"";
  if (![payload[@"schemaVersion"] isEqual:@1] || !profileID.length ||
      !ShaarPrintField(payload[@"pageURL"], 4096, YES) ||
      !ShaarPrintField(payload[@"origin"], 2048, YES) ||
      !ShaarPrintField(payload[@"frameID"], 256, YES) ||
      !ShaarPrintField(payload[@"title"], 2048, NO)) {
    [self resolvePrintRequestID:requestID accepted:NO];
    return;
  }
  NSMutableDictionary *request = [payload mutableCopy];
  request[@"profileID"] = profileID;
  request[@"tabID"] = tabID;
  request[@"windowID"] = windowID;
  request[@"contextID"] = contextID;
  if (self.onPrivatePrintRequest) {
    self.onPrivatePrintRequest(contextID, windowID, tabID, request);
  } else {
    [self resolvePrintRequestID:requestID accepted:NO];
  }
}

- (void)resolvePrintRequestID:(NSString *)requestID accepted:(BOOL)accepted {
  if (!_shaarPrintAvailable) return;
  if (!_shaarPrintRequests[requestID]) return;
  [_shaarPrintRequests removeObjectForKey:requestID];
  if (!_shaarPrintReply || !requestID.UTF8String) return;
  _shaarPrintReply(requestID.UTF8String, accepted ? 1 : 0);
}

- (void)resolveJavaScriptDialogRequestID:(NSString *)requestID accepted:(BOOL)accepted
                                  input:(NSString *)input {
  NSString *tabID = _shaarJavaScriptDialogRequests[requestID];
  if (!tabID) return;
  [_shaarJavaScriptDialogRequests removeObjectForKey:requestID];
  NSString *profileID = [self shaarProfileIDForTabID:tabID];
  if (!profileID) return;
  NSDictionary *payload = @{@"schemaVersion": @1, @"id": requestID,
    @"accepted": @(accepted), @"input": input ?: @""};
  [self shaarSubmit:SHAAR_OP_JAVASCRIPT_DIALOG_REPLY profileID:profileID
              tabID:tabID payload:payload completion:nil];
}

- (void)resolveDesktopCaptureRequestID:(NSString *)requestID sourceID:(NSString *)sourceID {
  if (!_shaarDesktopCaptureAvailable) return;
  NSString *tabID = _shaarCaptureRequests[requestID];
  if (!tabID) return;
  [_shaarCaptureRequests removeObjectForKey:requestID];
  NSString *token = sourceID ?: @"";
  NSString *decision = token.length ? @"approve" : @"cancel";
  [self submitTabID:tabID operation:SHAAR_OP_MEDIA_CAPTURE_REPLY
            payload:@{@"schemaVersion": @1, @"promptID": requestID,
                      @"decision": decision, @"sourceToken": token}];
}

- (void)resolveSavePromptRequestID:(NSString *)requestID decision:(NSString *)decision {
  NSString *tabID = _shaarSavePrompts[requestID];
  if (!tabID || !_shaarSavePromptsAvailable) return;
  if (![decision isEqualToString:@"save"] && ![decision isEqualToString:@"dismiss"] &&
      ![decision isEqualToString:@"never"]) {
    decision = @"dismiss";
  }
  [_shaarSavePrompts removeObjectForKey:requestID];
  [self submitTabID:tabID operation:SHAAR_OP_SAVE_PROMPT_DECIDE
            payload:@{@"schemaVersion": @1, @"id": requestID, @"decision": decision}];
}

- (void)dealloc {
  for (id observer in _hostResizeObservers.allValues)
    [NSNotificationCenter.defaultCenter removeObserver:observer];
  if (_shaarLibrary) dlclose(_shaarLibrary);
}

@end
