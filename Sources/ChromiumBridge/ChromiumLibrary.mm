#import "ChromiumLibrary.h"
#include <limits.h>

static NSError *LibraryError(NSString *message) {
  return [NSError errorWithDomain:@"com.arcusis.browser.library" code:1 userInfo:@{NSLocalizedDescriptionKey: message}];
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
      if (![result[@"ok"] isEqual:@YES] && self->_onError) self->_onError(profileID, section, @"Library updates are unavailable for this profile.");
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
@end
