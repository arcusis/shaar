// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#import "ChromiumDownloads.h"

static NSError *DownloadError(NSString *message) {
  return [NSError errorWithDomain:@"com.arcusis.browser.downloads" code:1
                        userInfo:@{NSLocalizedDescriptionKey: message}];
}

@implementation ARCDownloadService {
  ARCEngineServices *_services;
}

- (instancetype)initWithServices:(ARCEngineServices *)services {
  if (!(self = [super init])) return nil;
  _services = services;
  return self;
}

- (void)watchProfileID:(NSString *)profileID
           completion:(void (^)(NSArray<NSDictionary *> *, NSError *))completion {
  [self call:@"list" profileID:profileID args:@{} completion:^(NSDictionary *result) {
    NSArray *rows = result[@"downloads"];
    if ([result[@"error"] isKindOfClass:NSString.class] || ![rows isKindOfClass:NSArray.class]) {
      completion(nil, DownloadError(@"Downloads could not be restored for this profile."));
    } else {
      for (id row in rows) {
        if (![row isKindOfClass:NSDictionary.class]) {
          completion(nil, DownloadError(@"Invalid download history response."));
          return;
        }
      }
      completion(rows, nil);
    }
  }];
}

- (void)command:(NSString *)command downloadID:(NSString *)downloadID profileID:(NSString *)profileID
     completion:(void (^)(NSError *))completion {
  if (![@[@"pause", @"resume", @"cancel", @"remove"] containsObject:command] ||
      ![[NSUUID alloc] initWithUUIDString:downloadID]) {
    completion(DownloadError(@"Invalid download action."));
    return;
  }
  [self call:command profileID:profileID args:@{@"id": downloadID} completion:^(NSDictionary *result) {
    NSString *message = result[@"error"];
    if ([message isKindOfClass:NSString.class]) {
      completion(DownloadError([message isEqualToString:@"can't resume"]
        ? @"This download cannot be resumed." : @"The download action could not be completed."));
    } else if (![result[@"ok"] isEqual:@YES]) {
      completion(DownloadError(@"The engine did not confirm the download action."));
    } else {
      completion(nil);
    }
  }];
}

- (void)call:(NSString *)name profileID:(NSString *)profileID args:(NSDictionary *)args
  completion:(void (^)(NSDictionary *))completion {
  [_services call:[@"downloads." stringByAppendingString:name] profileID:profileID args:args completion:completion];
}

- (void)receiveTopic:(NSString *)topic profileID:(NSString *)profileID payload:(NSDictionary *)payload {
  if ([topic isEqualToString:@"downloads.changed"]) {
    NSDictionary *item = payload[@"download"];
    if ([item isKindOfClass:NSDictionary.class] && _onChanged) _onChanged(profileID, item);
  } else if ([topic isEqualToString:@"downloads.removed"]) {
    NSString *identity = payload[@"id"];
    if ([identity isKindOfClass:NSString.class] && _onRemoved) _onRemoved(profileID, identity);
  }
}
@end
