// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#import "ChromiumRuntimeInternal.h"
#import "ChromiumShaarExtensionsInternal.h"

static NSString *const ARCExtensionManagerID = @"bphhlegomeaogfihjcipdbcfbgkcfafp";

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

@implementation ARCChromiumRuntime (Extensions)

- (NSArray<NSDictionary<NSString *, id> *> *)extensionsForProfileID:(NSString *)profileID {
  NSMutableArray *result = [NSMutableArray arrayWithArray:_profiles[profileID].extensions ?: @[]];
  if (_testing) [result addObjectsFromArray:_probeExtensions[profileID] ?: @[]];
  return result;
}

- (BOOL)showPopupForExtension:(NSString *)extensionID tabID:(NSString *)tabID error:(NSError **)error {
  ArdiaCoreTab *owner = _tabs[tabID];
  ARCNativeWindowState *state = [self stateForTabID:tabID];
  if (!ARCExtensionIDIsValid(extensionID) || !owner || owner.closed || ![self isSelectedTabID:tabID]) {
    if (error) *error = ARCBridgeError(@"Extension actions require the selected tab in its owning profile.");
    return NO;
  }
  NSDictionary *action = [owner actionStatesForExtensions:@[extensionID]][extensionID];
  NSURL *url = [NSURL URLWithString:action[@"popup"] ?: @""];
  if (![[url scheme] isEqualToString:@"chrome-extension"] || ![url.host isEqualToString:extensionID] ||
      url.user || url.password || url.port) {
    if (error) *error = ARCBridgeError(@"The extension has no valid popup for this tab and profile.");
    return NO;
  }
  if (state.popup && [state.popupOwnerTabID isEqualToString:tabID] && [state.popupExtensionID isEqualToString:extensionID]) return YES;
  [self closeExtensionPopupForWindowID:state.identity];
  ArdiaCoreTab *popup = [state.native openExtensionView:url.absoluteString profile:owner.profile kind:@"popup"];
  if (!popup || popup.profile != owner.profile) {
    [popup closeNow];
    if (error) *error = ARCBridgeError(@"The extension popup could not be opened in its owning profile.");
    return NO;
  }
  state.popup = popup;
  state.popupID = NSUUID.UUID.UUIDString;
  state.popupOwnerTabID = tabID;
  state.popupExtensionID = extensionID;
  popup.delegate = self;
  if (self.onExtensionPopup) self.onExtensionPopup(@{
    @"id": state.popupID, @"tabID": tabID, @"profileID": _owners[tabID], @"extensionID": extensionID, @"windowID": state.identity
  });
  return YES;
}

- (NSString *)extensionActionTitleForID:(NSString *)extensionID tabID:(NSString *)tabID {
  ArdiaCoreTab *tab = _tabs[tabID];
  if (!ARCExtensionIDIsValid(extensionID) || !tab || tab.closed || ![self isSelectedTabID:tabID]) return nil;
  id title = [tab actionStatesForExtensions:@[extensionID]][extensionID][@"title"];
  return [title isKindOfClass:NSString.class] ? title : nil;
}

- (BOOL)executeExtensionID:(NSString *)extensionID tabID:(NSString *)tabID error:(NSError **)error {
  ArdiaCoreTab *tab = _tabs[tabID];
  NSDictionary *state = ARCExtensionIDIsValid(extensionID) && tab ? [tab actionStatesForExtensions:@[extensionID]][extensionID] : nil;
  if (!ARCExtensionIDIsValid(extensionID) || !tab || tab.closed || ![self isSelectedTabID:tabID] ||
      ![state[@"enabled"] boolValue]) {
    if (error) *error = ARCBridgeError(@"This extension action is unavailable in the selected profile.");
    return NO;
  }
  NSString *route = [tab executeExtensionAction:extensionID];
  if ([route isEqualToString:@"popup"]) return [self showPopupForExtension:extensionID tabID:tabID error:error];
  if ([route isEqualToString:@"sidePanel"]) {
    if (error) *error = ARCBridgeError(@"Extension side panels are not available yet.");
    return NO;
  }
  return YES;
}

/// Shaar's bundled manager extension holds the management APIs. Its page opens as an extension
/// view, not a tab, so it never joins the tab strip or the session model.
- (ArdiaCoreTab *)extensionManagerForProfileID:(NSString *)profileID {
  ArdiaCoreProfile *profile = _profiles[profileID];
  ARCNativeWindowState *window = _windows[_primaryWindowID];
  if (!profile || profile.destroyed || profile.offTheRecord || !window || window.closed) return nil;
  ArdiaCoreTab *manager = _extensionManagers[profileID];
  if (manager && !manager.closed && manager.profile == profile) return manager;
  NSString *path = [NSBundle.mainBundle pathForResource:@"ExtensionManager" ofType:nil];
  NSString *identity = path ? [profile loadComponentExtension:path] : nil;
  if (![identity isEqualToString:ARCExtensionManagerID]) return nil;
  NSString *url = [NSString stringWithFormat:@"chrome-extension://%@/manager.html", identity];
  manager = [window.native openExtensionView:url profile:profile kind:@"popup"];
  if (!manager || manager.profile != profile) {
    [manager closeNow];
    return nil;
  }
  _extensionManagers[profileID] = manager;
  return manager;
}

- (void)manageExtensionsForProfileID:(NSString *)profileID
                           operation:(ARCExtensionManagementOperation)operation
                         extensionID:(NSString *)extensionID
                             enabled:(BOOL)enabled
                          completion:(void (^)(NSString *))completion {
  NSString *validatedProfileID = ARCValidatedProfileID(profileID);
  BOOL needsExtensionID = operation != ARCExtensionManagementOperationList;
  if (!validatedProfileID || (needsExtensionID && !ARCExtensionIDIsValid(extensionID))) {
    completion(nil);
    return;
  }
  NSString *script = nil;
  switch (operation) {
    case ARCExtensionManagementOperationList:
      script = @"chrome.management.getAll().then(all=>all.filter(e=>e.type==='extension').map(e=>({id:e.id,name:e.name,version:e.version,description:e.description||'',enabled:e.enabled,mayDisable:e.mayDisable,permissions:e.permissions||[],hostPermissions:e.hostPermissions||[]})))";
      break;
    case ARCExtensionManagementOperationSetEnabled: {
      NSString *literal = ARCJSONLiteral(extensionID);
      if (literal) script = [NSString stringWithFormat:@"chrome.management.setEnabled(%@,%@).then(()=>true)", literal, enabled ? @"true" : @"false"];
      break;
    }
    case ARCExtensionManagementOperationUninstall: {
      NSString *literal = ARCJSONLiteral(extensionID);
      if (literal) script = [NSString stringWithFormat:@"chrome.management.uninstall(%@,{showConfirmDialog:false}).then(()=>true)", literal];
      break;
    }
    case ARCExtensionManagementOperationDetails: {
      NSString *literal = ARCJSONLiteral(extensionID);
      if (literal) script = [NSString stringWithFormat:@"chrome.management.get(%@)", literal];
      break;
    }
    default:
      completion(nil);
      return;
  }
  if (!script) { completion(nil); return; }
  ArdiaCoreProfile *profile = _profiles[validatedProfileID];
  ArdiaCoreTab *manager = [self extensionManagerForProfileID:validatedProfileID];
  if (!profile || profile.destroyed || profile.offTheRecord || !manager || manager.profile != profile) {
    completion(nil);
    return;
  }
  BOOL mutates = operation == ARCExtensionManagementOperationSetEnabled ||
    operation == ARCExtensionManagementOperationUninstall;
  [self runExtensionManagementScript:script mutates:mutates profileID:validatedProfileID
                             profile:profile manager:manager attempts:50 completion:completion];
}

/// Mutating operations run with a user gesture, which chrome.management requires for them.
- (void)runExtensionManagementScript:(NSString *)script mutates:(BOOL)mutates profileID:(NSString *)profileID
                             profile:(ArdiaCoreProfile *)profile manager:(ArdiaCoreTab *)manager
                            attempts:(int)attempts completion:(void (^)(NSString *))completion {
  if (_profiles[profileID] != profile || profile.destroyed || manager.closed || manager.profile != profile) {
    completion(nil);
    return;
  }
  if (manager.loading) {
    if (attempts <= 0) { completion(nil); return; }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
      [self runExtensionManagementScript:script mutates:mutates profileID:profileID profile:profile
                                 manager:manager attempts:attempts - 1 completion:completion];
    });
    return;
  }
  __block BOOL answered = NO;
  void (^reply)(NSString *) = ^(NSString *json) {
    if (answered) return;
    answered = YES;
    completion(json);
  };
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
    reply(nil);
  });
  NSString *wrapped = [NSString stringWithFormat:
    @"(async()=>{for(let i=0;i<80&&!(window.chrome&&chrome.management);i++)"
     "await new Promise(r=>setTimeout(r,100));"
     "try{post('result',JSON.stringify(await (%@)));}catch(e){post('result',JSON.stringify({error:String(e&&e.message||e)}));}})();",
    script];
  [manager evaluate:wrapped userGesture:mutates completion:reply];
}

- (NSURL *)extensionsDirectoryForProfileID:(NSString *)profileID {
  ArdiaCoreProfile *profile = _profiles[profileID];
  if (!profile || profile.destroyed || profile.offTheRecord || !profile.path.length) return nil;
  return [[NSURL fileURLWithPath:profile.path isDirectory:YES] URLByAppendingPathComponent:@"Extensions" isDirectory:YES];
}

- (NSView *)viewForExtensionPopupID:(NSString *)popupID {
  ARCNativeWindowState *state = [self stateForPopupID:popupID];
  return state.closed ? nil : state.popup.view;
}

- (void)closeExtensionPopup {
  [self closeExtensionPopupForWindowID:_primaryWindowID];
}

- (void)closeExtensionPopupForWindowID:(NSString *)windowID {
  ARCNativeWindowState *state = _windows[windowID];
  ArdiaCoreTab *tab = state.popup;
  NSString *identity = state.popupID;
  state.popup = nil;
  state.popupID = nil;
  state.popupOwnerTabID = nil;
  state.popupExtensionID = nil;
  [tab closeNow];
  if (identity && self.onExtensionPopupClosed) self.onExtensionPopupClosed(identity);
}

@end

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
  _webStoreFit = [[ARCWebStoreFit alloc] initWithTesting:NO evaluator:nil];
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

static NSArray<NSDictionary *> *ShaarExtensionRows(NSString *json) {
  NSData *data = [json dataUsingEncoding:NSUTF8StringEncoding];
  NSDictionary *object = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
  if (![object isKindOfClass:NSDictionary.class] || ![object[@"schemaVersion"] isEqual:@1] ||
      ![object[@"extensions"] isKindOfClass:NSArray.class]) return nil;
  NSMutableArray *rows = [NSMutableArray array];
  for (id entry in object[@"extensions"]) {
    if (![entry isKindOfClass:NSDictionary.class]) return nil;
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
        profileID:profileID tabID:tabID
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
      profileID:profileID tabID:tabID
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
      tabID:nil payload:payload completion:^(NSString *json, shaar_error_code code) {
        if (code != SHAAR_OK) { completion(nil); return; }
        if (operation == ARCExtensionManagementOperationList) {
          NSArray *rows = ShaarExtensionRows(json);
          if (rows) ShaarExtensionState(self).lists[validated] = rows;
          completion(rows ? ShaarJSONString(rows) : nil);
        } else {
          [ShaarExtensionState(self).lists removeObjectForKey:validated];
          completion(@"true");
        }
      }];
  if (!accepted) completion(nil);
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
        profileID:profileID tabID:tabID
        payload:@{@"schemaVersion": @1, @"popupId": popupID}
        completion:^(NSString *json, shaar_error_code code) {}];
    return;
  }
  NSView *view = [self shaarExtensionPopupViewForID:popupID windowID:windowID];
  if (!view) {
    [self shaarSubmitExtensionOperation:SHAAR_OP_EXTENSION_POPUP_CLOSE
        profileID:profileID tabID:tabID
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
      profileID:profileID tabID:tabID payload:@{@"schemaVersion": @1, @"popupId": popupID}
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
