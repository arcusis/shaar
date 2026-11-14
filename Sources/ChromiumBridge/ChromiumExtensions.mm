// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#import "ChromiumRuntimeInternal.h"
#import "ChromiumShaarExtensionsInternal.h"
#import <CoreFoundation/CoreFoundation.h>

static NSString *const ARCExtensionManagerID = @"bphhlegomeaogfihjcipdbcfbgkcfafp";
// Chromium 155 extensions/common/mojom/manifest.mojom ManifestLocation values.
static const NSInteger ARCComponentExtensionLocation = 5;
static const NSInteger ARCExternalComponentExtensionLocation = 10;

static BOOL ARCExtensionIDIsValid(NSString *extensionID) {
  if (![extensionID isKindOfClass:NSString.class] || extensionID.length != 32) return NO;
  for (NSUInteger index = 0; index < extensionID.length; index++) {
    unichar character = [extensionID characterAtIndex:index];
    if (character < 'a' || character > 'p') return NO;
  }
  return YES;
}

static NSString *ARCJSONLiteral(id value) {
  NSError *error = nil;
  NSData *data = [NSJSONSerialization dataWithJSONObject:value options:NSJSONWritingFragmentsAllowed error:&error];
  return data && !error ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
}

@interface ARCShaarExtensionState : NSObject
@property(strong) NSMutableDictionary<NSString *, NSArray<NSDictionary *> *> *lists;
@property(strong) NSMutableSet<NSString *> *loading;
@property(strong) NSMutableDictionary<NSString *, NSString *> *popupIDs;
@property(strong) NSMutableDictionary<NSString *, NSDictionary *> *popupInfo;
@property(strong) NSMutableDictionary<NSString *, id> *popupObservers;
@property(strong) NSMutableDictionary<NSString *, NSString *> *actionTitles;
@property(strong) NSMutableSet<NSString *> *actionLoading;
@property(strong) ARCWebStoreFit *webStoreFit;
@end

@implementation ARCShaarExtensionState
- (instancetype)init {
  if (!(self = [super init])) return nil;
  _lists = [NSMutableDictionary dictionary];
  _loading = [NSMutableSet set];
  _popupIDs = [NSMutableDictionary dictionary];
  _popupInfo = [NSMutableDictionary dictionary];
  _popupObservers = [NSMutableDictionary dictionary];
  _actionTitles = [NSMutableDictionary dictionary];
  _actionLoading = [NSMutableSet set];
  _webStoreFit = [[ARCWebStoreFit alloc] initWithTesting:NO];
  return self;
}
@end

static ARCShaarExtensionState *ShaarExtensionState(ARCShaarRuntime *runtime) {
  static NSMapTable<ARCShaarRuntime *, ARCShaarExtensionState *> *states;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ states = [NSMapTable weakToStrongObjectsMapTable]; });
  ARCShaarExtensionState *state = [states objectForKey:runtime];
  if (!state) {
    state = [ARCShaarExtensionState new];
    [states setObject:state forKey:runtime];
  }
  return state;
}

static NSString *ShaarJSONString(id value) {
  NSData *data = [NSJSONSerialization dataWithJSONObject:value
                                                options:NSJSONWritingFragmentsAllowed error:nil];
  return data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
}

NSArray<NSDictionary<NSString *, id> *> *ARCVisibleShaarExtensionRows(NSString *json) {
  NSData *data = [json dataUsingEncoding:NSUTF8StringEncoding];
  NSDictionary *object = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
  if (![object isKindOfClass:NSDictionary.class] ||
      ![object[@"schemaVersion"] isKindOfClass:NSNumber.class] ||
      CFGetTypeID((__bridge CFTypeRef)object[@"schemaVersion"]) == CFBooleanGetTypeID() ||
      ![object[@"schemaVersion"] isEqual:@1] ||
      ![object[@"extensions"] isKindOfClass:NSArray.class]) return nil;
  NSMutableArray *rows = [NSMutableArray array];
  for (id entry in object[@"extensions"]) {
    if (![entry isKindOfClass:NSDictionary.class]) return nil;
    NSNumber *location = entry[@"source"];
    if (![location isKindOfClass:NSNumber.class] ||
        CFGetTypeID((__bridge CFTypeRef)location) == CFBooleanGetTypeID() ||
        location.integerValue == ARCComponentExtensionLocation ||
        location.integerValue == ARCExternalComponentExtensionLocation) continue;
    NSString *identity = entry[@"id"];
    if (!ARCExtensionIDIsValid(identity) || ![entry[@"name"] isKindOfClass:NSString.class] ||
        ![entry[@"version"] isKindOfClass:NSString.class]) return nil;
    [rows addObject:@{
      @"id": identity, @"name": entry[@"name"], @"version": entry[@"version"],
      @"description": [entry[@"description"] isKindOfClass:NSString.class] ? entry[@"description"] : @"",
      @"enabled": entry[@"enabled"] ?: @NO, @"mayDisable": entry[@"mayDisable"] ?: @NO,
      @"permissions": [entry[@"permissions"] isKindOfClass:NSArray.class] ? entry[@"permissions"] : @[],
      @"hostPermissions": [entry[@"hostPermissions"] isKindOfClass:NSArray.class] ? entry[@"hostPermissions"] : @[]
    }];
  }
  return rows;
}

@implementation ARCShaarRuntime (Extensions)

- (NSArray<NSDictionary<NSString *, id> *> *)extensionsForProfileID:(NSString *)profileID {
  NSString *validated = ARCValidatedProfileID(profileID);
  if (!validated) return @[];
  ARCShaarExtensionState *state = ShaarExtensionState(self);
  if (![state.loading containsObject:validated]) {
    [state.loading addObject:validated];
    [self manageExtensionsForProfileID:validated operation:ARCExtensionManagementOperationList
                           extensionID:nil enabled:NO completion:^(NSString *json) {
      [state.loading removeObject:validated];
    }];
  }
  return state.lists[validated] ?: @[];
}

- (NSString *)extensionActionTitleForID:(NSString *)extensionID tabID:(NSString *)tabID {
  NSString *profileID = [self shaarProfileIDForTabID:tabID];
  if (!ARCExtensionIDIsValid(extensionID) || !profileID ||
      ![self shaarOwnsSelectedTabID:tabID profileID:profileID]) return nil;
  ARCShaarExtensionState *state = ShaarExtensionState(self);
  NSString *key = [tabID stringByAppendingFormat:@":%@", extensionID];
  if (![state.actionLoading containsObject:key]) {
    [state.actionLoading addObject:key];
    BOOL accepted = [self shaarSubmitExtensionOperation:SHAAR_OP_EXTENSION_ACTION_STATE
        profileID:profileID tabID:tabID allowsProfileOnly:NO
        payload:@{@"schemaVersion": @1, @"extensionId": extensionID}
        completion:^(NSString *json, shaar_error_code code) {
          [state.actionLoading removeObject:key];
          if (code != SHAAR_OK || !json) return;
          NSDictionary *reply = [NSJSONSerialization JSONObjectWithData:
              [json dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
          NSString *title = reply[@"title"];
          if ([reply[@"schemaVersion"] isEqual:@1] &&
              [title isKindOfClass:NSString.class]) state.actionTitles[key] = title;
        }];
    if (!accepted) [state.actionLoading removeObject:key];
  }
  return state.actionTitles[key];
}

- (BOOL)showPopupForExtension:(NSString *)extensionID tabID:(NSString *)tabID error:(NSError **)error {
  return [self executeExtensionID:extensionID tabID:tabID error:error];
}

- (BOOL)executeExtensionID:(NSString *)extensionID tabID:(NSString *)tabID error:(NSError **)error {
  NSString *profileID = [self shaarProfileIDForTabID:tabID];
  if (!ARCExtensionIDIsValid(extensionID) || !profileID ||
      ![self shaarOwnsSelectedTabID:tabID profileID:profileID]) {
    if (error) *error = ARCBridgeError(@"This extension action is unavailable in the selected profile.");
    return NO;
  }
  BOOL accepted = [self shaarSubmitExtensionOperation:SHAAR_OP_EXTENSION_ACTION
      profileID:profileID tabID:tabID allowsProfileOnly:NO
      payload:@{@"schemaVersion": @1, @"extensionId": extensionID}
      completion:^(NSString *json, shaar_error_code code) {
        if (code != SHAAR_OK) {
          if (self.onNotice)
            self.onNotice(@"This extension action is unavailable in the selected profile.");
          return;
        }
        NSDictionary *reply = json ? [NSJSONSerialization JSONObjectWithData:
            [json dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil] : nil;
        if (![reply isKindOfClass:NSDictionary.class] || ![reply[@"schemaVersion"] isEqual:@1]) return;
        if ([reply[@"route"] isEqualToString:@"popup"])
          [self shaarPresentExtensionPopup:reply extensionID:extensionID
                                    tabID:tabID profileID:profileID];
      }];
  if (!accepted && error) *error = ARCBridgeError(@"This extension action is unavailable in the selected profile.");
  return accepted;
}

- (void)manageExtensionsForProfileID:(NSString *)profileID
                           operation:(ARCExtensionManagementOperation)operation
                         extensionID:(NSString *)extensionID enabled:(BOOL)enabled
                          completion:(void (^)(NSString *))completion {
  NSString *validated = ARCValidatedProfileID(profileID);
  if (!validated || (operation != ARCExtensionManagementOperationList &&
                     !ARCExtensionIDIsValid(extensionID))) { completion(nil); return; }
  if (operation == ARCExtensionManagementOperationDetails) {
    [self manageExtensionsForProfileID:validated operation:ARCExtensionManagementOperationList
                           extensionID:nil enabled:NO completion:^(NSString *json) {
      NSArray *rows = json ? [NSJSONSerialization JSONObjectWithData:
          [json dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil] : nil;
      NSDictionary *match = nil;
      for (NSDictionary *row in rows) {
        if ([row[@"id"] isEqualToString:extensionID]) { match = row; break; }
      }
      completion(match ? ShaarJSONString(match) : nil);
    }];
    return;
  }
  shaar_operation nativeOperation = operation == ARCExtensionManagementOperationList ?
      SHAAR_OP_EXTENSION_LIST : SHAAR_OP_EXTENSION_MANAGE;
  NSMutableDictionary *payload = [@{@"schemaVersion": @1} mutableCopy];
  if (operation == ARCExtensionManagementOperationSetEnabled) {
    payload[@"action"] = @"setEnabled";
    payload[@"extensionId"] = extensionID;
    payload[@"enabled"] = @(enabled);
  } else if (operation == ARCExtensionManagementOperationUninstall) {
    payload[@"action"] = @"uninstall";
    payload[@"extensionId"] = extensionID;
  } else if (operation != ARCExtensionManagementOperationList) { completion(nil); return; }
  BOOL accepted = [self shaarSubmitExtensionOperation:nativeOperation profileID:validated
      tabID:nil allowsProfileOnly:YES payload:payload
      completion:^(NSString *json, shaar_error_code code) {
        if (code != SHAAR_OK) { completion(nil); return; }
        if (operation == ARCExtensionManagementOperationList) {
          NSArray *rows = ARCVisibleShaarExtensionRows(json);
          if (rows) ShaarExtensionState(self).lists[validated] = rows;
          completion(rows ? ShaarJSONString(rows) : nil);
        } else {
          [ShaarExtensionState(self).lists removeObjectForKey:validated];
          completion(@"true");
        }
      }];
  if (!accepted) completion(nil);
}

- (void)submitExtensionManageForProfileID:(NSString *)profileID
                                    tabID:(NSString *)tabID
                                  payload:(NSDictionary<NSString *, id> *)payload
                               completion:(void (^)(NSString *, NSInteger))completion {
  NSString *validated = ARCValidatedProfileID(profileID);
  if (!validated || ![payload isKindOfClass:NSDictionary.class]) {
    completion(nil, SHAAR_INVALID_ARGUMENT);
    return;
  }
  NSString *tab = nil;
  if ([tabID isKindOfClass:NSString.class] && tabID.length) tab = tabID;
  shaar_error_code syncCode = SHAAR_OK;
  BOOL accepted = [self shaarSubmitExtensionOperation:SHAAR_OP_EXTENSION_MANAGE
      profileID:validated tabID:tab payload:payload
      completion:^(NSString *json, shaar_error_code code) {
        if (code == SHAAR_OK) [ShaarExtensionState(self).lists removeObjectForKey:validated];
        completion(json, (NSInteger)code);
      } syncCode:&syncCode];
  if (!accepted) completion(nil, syncCode == SHAAR_OK ? SHAAR_CHROMIUM_ERROR : syncCode);
}

- (void)shaarForgetExtensionListForProfileID:(NSString *)profileID {
  NSString *validated = ARCValidatedProfileID(profileID);
  if (validated) [ShaarExtensionState(self).lists removeObjectForKey:validated];
}

- (NSURL *)extensionsDirectoryForProfileID:(NSString *)profileID {
  NSString *validated = ARCValidatedProfileID(profileID);
  NSURL *directory = validated ? [self shaarProfileDirectoryForID:validated] : nil;
  return directory ? [directory URLByAppendingPathComponent:@"Extensions" isDirectory:YES] : nil;
}

- (void)shaarPresentExtensionPopup:(NSDictionary *)reply
                     extensionID:(NSString *)extensionID tabID:(NSString *)tabID
                       profileID:(NSString *)profileID {
  NSString *popupID = [reply[@"popupId"] isKindOfClass:NSString.class] ? reply[@"popupId"] : nil;
  NSString *windowID = [self shaarWindowIDForTabID:tabID];
  if (!popupID.length || !windowID ||
      ![self shaarOwnsSelectedTabID:tabID profileID:profileID]) {
    if (popupID.length) [self shaarSubmitExtensionOperation:SHAAR_OP_EXTENSION_POPUP_CLOSE
        profileID:profileID tabID:tabID allowsProfileOnly:NO
        payload:@{@"schemaVersion": @1, @"popupId": popupID}
        completion:^(NSString *json, shaar_error_code code) {}];
    return;
  }
  NSView *view = [self shaarExtensionPopupViewForID:popupID windowID:windowID];
  if (!view) {
    [self shaarSubmitExtensionOperation:SHAAR_OP_EXTENSION_POPUP_CLOSE
        profileID:profileID tabID:tabID allowsProfileOnly:NO
        payload:@{@"schemaVersion": @1, @"popupId": popupID}
        completion:^(NSString *json, shaar_error_code code) {}];
    return;
  }
  [self closeExtensionPopupForWindowID:windowID];
  ARCShaarExtensionState *state = ShaarExtensionState(self);
  state.popupIDs[windowID] = popupID;
  state.popupInfo[popupID] = @{@"windowID": windowID, @"tabID": tabID,
                              @"profileID": profileID, @"extensionID": extensionID};
  view.postsFrameChangedNotifications = YES;
  __weak ARCShaarRuntime *weakSelf = self;
  state.popupObservers[popupID] = [NSNotificationCenter.defaultCenter
      addObserverForName:NSViewFrameDidChangeNotification object:view
      queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *notification) {
        ARCShaarRuntime *owner = weakSelf;
        if (owner && ShaarExtensionState(owner).popupInfo[popupID])
          [owner shaarReportPopupSizeForID:popupID view:view];
      }];
  if (self.onExtensionPopup) self.onExtensionPopup(@{
    @"id": popupID, @"windowID": windowID, @"tabID": tabID,
    @"profileID": profileID, @"extensionID": extensionID});
  [self shaarReportPopupSizeForID:popupID view:view];
}

- (void)shaarReportPopupSizeForID:(NSString *)popupID view:(NSView *)view {
  if (view.frame.size.width > 0 && view.frame.size.height > 0 && self.onExtensionPopupSize)
    self.onExtensionPopupSize(popupID, view.frame.size);
}

- (NSView *)viewForExtensionPopupID:(NSString *)popupID {
  NSDictionary *info = ShaarExtensionState(self).popupInfo[popupID];
  return info ? [self shaarExtensionPopupViewForID:popupID windowID:info[@"windowID"]] : nil;
}

- (NSDictionary *)shaarExtensionPopupOwnerForID:(NSString *)popupID {
  NSDictionary *info = ShaarExtensionState(self).popupInfo[popupID];
  if (![info isKindOfClass:NSDictionary.class]) return nil;
  NSString *windowID = info[@"windowID"];
  NSString *tabID = info[@"tabID"];
  NSString *profileID = info[@"profileID"];
  if (![windowID isKindOfClass:NSString.class] || ![tabID isKindOfClass:NSString.class] ||
      ![profileID isKindOfClass:NSString.class]) return nil;
  if (![self shaarDevToolsOwnsTabID:tabID profileID:profileID windowID:windowID]) return nil;
  if (![self viewForExtensionPopupID:popupID]) return nil;
  return @{@"windowID": windowID, @"tabID": tabID, @"profileID": profileID};
}
- (void)closeExtensionPopup { [self closeExtensionPopupForWindowID:self.primaryWindowID]; }
- (void)closeExtensionPopupForWindowID:(NSString *)windowID {
  ARCShaarExtensionState *state = ShaarExtensionState(self);
  NSString *popupID = state.popupIDs[windowID];
  if (!popupID) return;
  NSDictionary *info = state.popupInfo[popupID];
  id observer = state.popupObservers[popupID];
  if (observer) [NSNotificationCenter.defaultCenter removeObserver:observer];
  [state.popupObservers removeObjectForKey:popupID];
  [state.popupIDs removeObjectForKey:windowID];
  [state.popupInfo removeObjectForKey:popupID];
  NSString *profileID = info[@"profileID"];
  NSString *tabID = info[@"tabID"];
  if (profileID && tabID) [self shaarSubmitExtensionOperation:SHAAR_OP_EXTENSION_POPUP_CLOSE
      profileID:profileID tabID:tabID allowsProfileOnly:NO
      payload:@{@"schemaVersion": @1, @"popupId": popupID}
      completion:^(NSString *json, shaar_error_code code) {}];
  if (self.onExtensionPopupClosed) self.onExtensionPopupClosed(popupID);
}

- (void)shaarExtensionEvent:(const shaar_event *)event payload:(NSDictionary *)payload {
  NSString *tabID = [[NSString alloc] initWithBytes:event->tab_id.data length:event->tab_id.size
                                            encoding:NSUTF8StringEncoding];
  ARCShaarExtensionState *state = ShaarExtensionState(self);
  if (!tabID.length) return;
  ARCWebStoreFit *fit = state.webStoreFit;
  if (event->kind == SHAAR_EVENT_NAVIGATION &&
      [payload[@"phase"] isEqualToString:@"started"]) {
    NSString *prefix = [tabID stringByAppendingString:@":"];
    for (NSString *key in state.actionTitles.allKeys)
      if ([key hasPrefix:prefix]) [state.actionTitles removeObjectForKey:key];
  }
  if (event->kind == SHAAR_EVENT_TAB && [payload[@"kind"] isEqualToString:@"closed"])
    [fit shaarTabWillCloseID:tabID];
  if ((event->kind == SHAAR_EVENT_TAB && [payload[@"kind"] isEqualToString:@"closed"]) ||
      (event->kind == SHAAR_EVENT_NAVIGATION && [payload[@"phase"] isEqualToString:@"started"])) {
    for (NSString *popupID in state.popupInfo.allKeys) {
      NSDictionary *info = state.popupInfo[popupID];
      if ([info[@"tabID"] isEqualToString:tabID])
        [self closeExtensionPopupForWindowID:info[@"windowID"]];
    }
  }
  if (event->kind == SHAAR_EVENT_NAVIGATION)
    [fit shaarTabDidReceiveEvent:payload tabID:tabID runtime:self];
}

@end
