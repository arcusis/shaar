// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#import "ChromiumRuntimeInternal.h"

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
