// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#import "ChromiumLibrary.h"
#import "include/ChromiumBridge.h"
#import <CoreFoundation/CoreFoundation.h>
#include <limits.h>
#include <math.h>

static NSError *LibraryError(NSString *message) {
  return [NSError errorWithDomain:@"com.arcusis.browser.library" code:1 userInfo:@{NSLocalizedDescriptionKey: ARCBridgeLocalizedString(message)}];
}

static BOOL LibraryURL(id value, BOOL webOnly) {
  if (![value isKindOfClass:NSString.class] || [value length] > 32768 || [value rangeOfString:@"\0"].location != NSNotFound) return NO;
  NSURL *url = [NSURL URLWithString:value];
  return url.scheme.length && (!webOnly || ([@[@"http", @"https"] containsObject:url.scheme.lowercaseString] && url.host.length));
}

@implementation ARCLibraryService {
  ARCEngineServices *_services;
}

- (instancetype)initWithServices:(ARCEngineServices *)services {
  if (!(self = [super init])) return nil;
  _services = services;
  return self;
}

- (void)watchProfileID:(NSString *)profileID {
  for (NSString *section in @[@"bookmarks", @"history"]) {
    [_services call:[section stringByAppendingString:@".watch"] profileID:profileID args:@{} completion:^(NSDictionary *result) {
      if (![result[@"ok"] isEqual:@YES] && self->_onError) self->_onError(profileID, section, ARCBridgeLocalizedString(@"Library updates are unavailable for this profile."));
    }];
  }
}

- (void)bookmarksForProfileID:(NSString *)profileID completion:(void (^)(NSDictionary *, NSError *))completion {
  [_services call:@"bookmarks.tree" profileID:profileID args:@{} completion:^(NSDictionary *result) {
    if (result[@"error"] || ![result[@"bar"] isKindOfClass:NSDictionary.class] || ![result[@"other"] isKindOfClass:NSDictionary.class]) {
      completion(nil, LibraryError(@"Bookmarks could not be loaded for this profile."));
    } else { completion(result, nil); }
  }];
}

- (void)applyBookmarkOperation:(NSDictionary *)operation profileID:(NSString *)profileID completion:(void (^)(NSError *))completion {
  NSString *kind = operation[@"op"];
  NSString *identity = operation[@"id"];
  NSString *parent = operation[@"parent"];
  BOOL parentValid = [parent isKindOfClass:NSString.class] && ([@[@"bar", @"other"] containsObject:parent] || [[NSUUID alloc] initWithUUIDString:parent]);
  BOOL adding = [kind isEqual:@"add"];
  BOOL urlKind = [operation[@"k"] isEqual:@"u"];
  id title = operation[@"t"];
  if (![kind isKindOfClass:NSString.class] || ![@[@"add", @"update", @"move", @"remove"] containsObject:kind] ||
      ![identity isKindOfClass:NSString.class] || ![[NSUUID alloc] initWithUUIDString:identity] ||
      (parent && !parentValid) ||
      (title && (![title isKindOfClass:NSString.class] || [title length] > 4096)) ||
      (operation[@"u"] && !LibraryURL(operation[@"u"], YES)) ||
      ((adding || [kind isEqual:@"move"]) && !parentValid) ||
      (adding && (![@[@"u", @"f"] containsObject:operation[@"k"]] || (urlKind && !LibraryURL(operation[@"u"], YES))))) {
    completion(LibraryError(@"Invalid bookmark action.")); return;
  }
  NSMutableDictionary *op = [operation mutableCopy];
  op[@"id"] = identity.lowercaseString;
  if (parent && ![@[@"bar", @"other"] containsObject:parent]) op[@"parent"] = parent.lowercaseString;
  [_services call:@"bookmarks.apply" profileID:profileID args:@{@"ops": @[op]} completion:^(NSDictionary *result) {
    NSArray *invalid = result[@"invalid"];
    if (result[@"error"] || ![result[@"applied"] isEqual:@1] || ![result[@"skipped"] isEqual:@0] ||
        ![invalid isKindOfClass:NSArray.class] || invalid.count) {
      completion(LibraryError(@"The bookmark action was not confirmed."));
    } else { completion(nil); }
  }];
}

- (void)historyForProfileID:(NSString *)profileID limit:(NSInteger)limit completion:(void (^)(NSArray<NSDictionary *> *, NSError *))completion {
  if (limit < 1 || limit > INT_MAX) { completion(nil, LibraryError(@"Invalid history limit.")); return; }
  [_services call:@"history.query" profileID:profileID args:@{@"maxUrls": @(limit), @"maxVisits": @1} completion:^(NSDictionary *result) {
    NSArray *entries = result[@"entries"];
    if (result[@"error"] || ![entries isKindOfClass:NSArray.class]) {
      completion(nil, LibraryError(@"History could not be loaded for this profile.")); return;
    }
    for (id entry in entries) {
      if (![entry isKindOfClass:NSDictionary.class]) { completion(nil, LibraryError(@"Invalid history response.")); return; }
    }
    completion(entries, nil);
  }];
}

- (void)deleteHistoryURL:(NSString *)url profileID:(NSString *)profileID completion:(void (^)(NSError *))completion {
  if (!LibraryURL(url, NO)) { completion(LibraryError(@"Invalid history address.")); return; }
  [_services call:@"history.delete_urls" profileID:profileID args:@{@"urls": @[url]} completion:^(NSDictionary *result) {
    completion([result[@"ok"] isEqual:@YES] ? nil : LibraryError(@"History deletion was not confirmed."));
  }];
}

- (void)importHistoryRows:(NSArray<NSDictionary *> *)rows source:(NSString *)source
  profileID:(NSString *)profileID completion:(void (^)(NSError *))completion {
  NSSet *sources = [NSSet setWithArray:@[@"chrome", @"edge", @"brave", @"arc", @"safari", @"firefox"]];
  if (![sources containsObject:source] || !rows.count || rows.count > 10000) {
    completion(LibraryError(@"Invalid browser history import.")); return;
  }
  for (id value in rows) {
    if (![value isKindOfClass:NSDictionary.class]) {
      completion(LibraryError(@"Invalid browser history import.")); return;
    }
    NSDictionary *row = value;
    id url = row[@"u"], title = row[@"t"], count = row[@"n"], last = row[@"l"];
    if (!LibraryURL(url, YES) || ![title isKindOfClass:NSString.class] || [title length] > 4096 ||
        ![count isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)count) == CFBooleanGetTypeID() ||
        !isfinite([count doubleValue]) || [count doubleValue] >= (double)LLONG_MAX ||
        [count longLongValue] < 1 || [count doubleValue] != (double)[count longLongValue] ||
        ![last isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)last) == CFBooleanGetTypeID() ||
        !isfinite([last doubleValue]) || [last doubleValue] <= 0) {
      completion(LibraryError(@"Invalid browser history import row.")); return;
    }
  }
  [_services call:@"history.import" profileID:profileID args:@{@"source": source, @"rows": rows}
    completion:^(NSDictionary *result) {
      completion([result[@"ok"] isEqual:@YES] ? nil :
        LibraryError(@"Browser history could not be imported into this profile."));
    }];
}
@end
