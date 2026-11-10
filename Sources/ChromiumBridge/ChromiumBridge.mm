// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#import "ChromiumRuntimeInternal.h"
#import <dlfcn.h>
#import <objc/message.h>
#include <string>
#include <vector>
#include <cmath>
#include <errno.h>
#include <sys/stat.h>
#include <unistd.h>

static NSBundle *ARCSelectedBridgeBundle;
static NSString *ARCBridgeLanguage = @"en";

NSString *ARCBridgeLocalizedString(NSString *key) {
  return [ARCSelectedBridgeBundle localizedStringForKey:key value:key table:@"Bridge"] ?: key;
}

NSError *ARCBridgeError(NSString *message) {
  NSString *localized = ARCBridgeLocalizedString(message);
  return [NSError errorWithDomain:@"com.arcusis.browser.chromium" code:1
                        userInfo:@{NSLocalizedDescriptionKey: localized}];
}

void ARCConfigureLocalization(NSURL *bundleURL, NSString *languageIdentifier) {
  NSString *language = [@[@"en", @"he"] containsObject:languageIdentifier] ? languageIdentifier : @"en";
  ARCBridgeLanguage = language;
  NSBundle *packageBundle = [NSBundle bundleWithURL:bundleURL];
  NSString *localizationPath = [packageBundle pathForResource:language ofType:@"lproj"];
  ARCSelectedBridgeBundle = localizationPath ? [NSBundle bundleWithPath:localizationPath] : packageBundle;
}

static NSString *ARCStringWithLocale(NSString *format, NSLocale *locale, ...) {
  va_list arguments;
  va_start(arguments, locale);
  NSString *result = [[NSString alloc] initWithFormat:format locale:locale arguments:arguments];
  va_end(arguments);
  return result;
}

static NSString *ARCBridgeActiveDownloadsMessage(int count) {
  if (!ARCSelectedBridgeBundle) {
    return count == 1 ? @"Closing the browser will cancel 1 active download."
      : [NSString stringWithFormat:@"Closing the browser will cancel %d active downloads.", count];
  }
  NSString *englishFallback = @"Closing the browser will cancel %d active downloads.";
  NSString *format = [ARCSelectedBridgeBundle localizedStringForKey:@"%d active downloads"
      value:englishFallback table:@"Bridge"];
  if ([format isEqualToString:englishFallback]) {
    return count == 1 ? @"Closing the browser will cancel 1 active download."
      : [NSString stringWithFormat:englishFallback, count];
  }
  return ARCStringWithLocale(format, [NSLocale localeWithLocaleIdentifier:ARCBridgeLanguage], count);
}

BOOL ARCIsCanonicalID(NSString *value) {
  return [[[[NSUUID alloc] initWithUUIDString:value] UUIDString] isEqualToString:value];
}

NSString *ARCValidatedProfileID(NSString *profileID) {
  if (![profileID isKindOfClass:NSString.class] ||
      ![profileID rangeOfString:@"^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$"
                       options:NSRegularExpressionSearch].length) return nil;
  NSUUID *identity = [[NSUUID alloc] initWithUUIDString:profileID];
  return identity.UUIDString;
}

BOOL ARCReservedBrowserShortcut(NSString *key, NSEventModifierFlags modifiers) {
  NSEventModifierFlags chord = modifiers & (NSEventModifierFlagCommand | NSEventModifierFlagControl |
    NSEventModifierFlagOption | NSEventModifierFlagShift | NSEventModifierFlagFunction);
  // Keep Command-N out of Chromium: Shaar intentionally leaves it without a menu action.
  if (chord == NSEventModifierFlagCommand) {
    return [@[@"n", @"t", @"l", @"w", @"s", @"q", @"r", @"f", @"g", @"d", @"y", @","] containsObject:key.lowercaseString];
  }
  if (chord == (NSEventModifierFlagCommand | NSEventModifierFlagShift)) {
    return [@[@"w", @"g", @"j", @"t", @"r", @"c"] containsObject:key.lowercaseString];
  }
  if (chord == (NSEventModifierFlagCommand | NSEventModifierFlagOption | NSEventModifierFlagShift))
    return [@[@"c", @"i"] containsObject:key.lowercaseString];
  if (chord == (NSEventModifierFlagCommand | NSEventModifierFlagOption))
    return [key.lowercaseString isEqualToString:@"i"];
  return chord == (NSEventModifierFlagControl | NSEventModifierFlagOption) &&
    [@[@"[", @"]"] containsObject:key];
}

@implementation ARCChromiumRuntime

- (NSString *)startupNotice { return nil; }

- (instancetype)initWithFrameworkURL:(NSURL *)url error:(NSError **)error {
  if (error) *error = [NSError errorWithDomain:@"org.arcusis.shaar.engine" code:1
                                     userInfo:@{NSLocalizedDescriptionKey: @"Shaar engine unavailable."}];
  return nil;
}

- (void)loadProfileID:(NSString *)profileID completion:(void (^)(NSError *))completion {
  if (completion) completion(ARCBridgeError(@"Shaar engine unavailable."));
}

- (void)discardTabID:(NSString *)tabID {}

- (void)probeTabLifecycleForTabID:(NSString *)tabID completion:(void (^)(BOOL))completion {
  if (completion) completion(NO);
}
- (void)sleepTabID:(NSString *)tabID reason:(NSString *)reason completion:(void (^)(BOOL))completion {
  if (completion) completion(NO);
}
- (void)wakeTabID:(NSString *)tabID completion:(void (^)(BOOL))completion {
  if (completion) completion(NO);
}
- (void)freezeTabID:(NSString *)tabID completion:(void (^)(BOOL))completion {
  if (completion) completion(NO);
}
- (void)probePrivateTabLifecycleForTabID:(NSString *)tabID windowID:(NSString *)windowID
                              contextID:(NSString *)contextID completion:(void (^)(BOOL))completion {
  if (completion) completion(NO);
}
- (void)sleepPrivateTabID:(NSString *)tabID windowID:(NSString *)windowID
               contextID:(NSString *)contextID reason:(NSString *)reason
              completion:(void (^)(BOOL))completion {
  if (completion) completion(NO);
}
- (void)wakePrivateTabID:(NSString *)tabID windowID:(NSString *)windowID
              contextID:(NSString *)contextID completion:(void (^)(BOOL))completion {
  if (completion) completion(NO);
}
- (void)evaluateInPrivateTabID:(NSString *)tabID windowID:(NSString *)windowID
                    contextID:(NSString *)contextID script:(NSString *)script
                   completion:(void (^)(NSString *))completion {
  if (completion) completion(nil);
}

- (BOOL)createWindowID:(NSString *)windowID error:(NSError **)error {
  if (error) *error = ARCBridgeError(@"Shaar engine unavailable.");
  return NO;
}

- (NSWindow *)windowForID:(NSString *)windowID { return nil; }

- (void)closeExtensionPopupForWindowID:(NSString *)windowID {}

- (void)activateProfileID:(NSString *)profileID windowID:(NSString *)windowID {}

- (NSImage *)faviconForTabID:(NSString *)tabID profileID:(NSString *)profileID
                   windowID:(NSString *)windowID { return nil; }

- (int)runWithDataDirectory:(NSURL *)directory testing:(BOOL)testing { return 1; }
- (BOOL)closeWindowID:(NSString *)windowID { return NO; }
- (BOOL)isWindowOpenID:(NSString *)windowID { return YES; }
- (void)retireClosedWindowID:(NSString *)windowID {}
- (NSView *)hostViewForWindowID:(NSString *)windowID { return nil; }
- (NSString *)windowIDForTabID:(NSString *)tabID { return nil; }
- (NSString *)profileIDForTabID:(NSString *)tabID { return nil; }
- (int)chromeWindowIDForProfileID:(NSString *)profileID windowID:(NSString *)windowID { return -1; }
- (void)clearActiveTabInWindowID:(NSString *)windowID {}
- (BOOL)openTabID:(NSString *)tabID profileID:(NSString *)profileID windowID:(NSString *)windowID
             url:(NSString *)url error:(NSError **)error {
  if (error) *error = ARCBridgeError(@"Shaar engine unavailable.");
  return NO;
}
- (BOOL)openTabID:(NSString *)tabID profileID:(NSString *)profileID url:(NSString *)url
           error:(NSError **)error {
  return [self openTabID:tabID profileID:profileID windowID:@"" url:url error:error];
}
- (BOOL)navigateTabID:(NSString *)tabID profileID:(NSString *)profileID
             windowID:(NSString *)windowID url:(NSString *)url { return NO; }
- (BOOL)placeTabIDs:(NSArray<NSString *> *)tabIDs pinnedIDs:(NSArray<NSString *> *)pinnedIDs
         profileID:(NSString *)profileID windowID:(NSString *)windowID { return NO; }
- (BOOL)placeTabIDs:(NSArray<NSString *> *)tabIDs pinnedIDs:(NSArray<NSString *> *)pinnedIDs
         profileID:(NSString *)profileID { return NO; }
- (NSView *)viewForTabID:(NSString *)tabID { return nil; }
- (void)activateTabID:(NSString *)tabID {}
- (void)focusTabID:(NSString *)tabID {}
- (void)activateProfileID:(NSString *)profileID {}
- (void)clearActiveTab {}
- (void)closeTabID:(NSString *)tabID {}
- (void)resolveDeviceChooserRequestID:(NSString *)requestID optionID:(NSString *)optionID {}
- (void)goBackInTabID:(NSString *)tabID {}
- (void)goForwardInTabID:(NSString *)tabID {}
- (void)reloadTabID:(NSString *)tabID {}
- (BOOL)reloadTabID:(NSString *)tabID profileID:(NSString *)profileID { return NO; }
- (BOOL)reloadTabID:(NSString *)tabID profileID:(NSString *)profileID
              mode:(ARCPageReloadMode)mode { return NO; }

- (BOOL)openPrivateTabID:(NSString *)tabID windowID:(NSString *)windowID
               contextID:(NSString *)contextID url:(NSString *)url error:(NSError **)error {
  if (error) *error = ARCBridgeError(@"Shaar engine unavailable.");
  return NO;
}

- (NSView *)viewForPrivateTabID:(NSString *)tabID windowID:(NSString *)windowID
                     contextID:(NSString *)contextID { return nil; }
- (NSView *)hostViewForPrivateWindowID:(NSString *)windowID contextID:(NSString *)contextID {
  return nil;
}
- (NSWindow *)windowForPrivateWindowID:(NSString *)windowID contextID:(NSString *)contextID {
  return nil;
}

- (NSNumber *)thirdPartyCookiesBlockedForProfileID:(NSString *)profileID { return nil; }

- (void)setThirdPartyCookiesBlocked:(BOOL)blocked profileID:(NSString *)profileID
                         completion:(void (^)(NSError *))completion {
  if (completion) completion(ARCBridgeError(@"Shaar engine unavailable."));
}

- (void)deleteEngineProfileID:(NSString *)profileID completion:(void (^)(NSError *))completion {
  if (completion) completion(ARCBridgeError(@"Shaar engine unavailable."));
}

@end
