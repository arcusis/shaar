// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#import <AppKit/AppKit.h>
@class ArdiaCoreTab;
@class ARCShaarRuntime;

/// Stable page-card content. Chromium owns the inspector's splitter and saved dock settings.
@interface ARCDevToolsPageView : NSView
- (instancetype)initWithTab:(ArdiaCoreTab *)tab;
- (void)refreshDevTools;
- (void)setDevToolsView:(NSView *)view;
- (void)invalidate;
@end

// Private transport shared by the Shaar DevTools, Inspector, and Developer Mode routes.
@interface ARCShaarRuntime (DevToolsTransport)
- (BOOL)shaarDevToolsOwnsTabID:(NSString *)tabID profileID:(NSString *)profileID
                    windowID:(NSString *)windowID;
- (BOOL)shaarDevToolsSubmit:(NSUInteger)operation tabID:(NSString *)tabID
                 profileID:(NSString *)profileID windowID:(NSString *)windowID
                   payload:(NSDictionary *)payload
                completion:(void (^)(NSDictionary *, NSError *))completion;
- (void)shaarDevToolsCall:(NSString *)method params:(NSDictionary *)params
              capability:(NSUInteger)capability tabID:(NSString *)tabID
               profileID:(NSString *)profileID windowID:(NSString *)windowID
              completion:(void (NS_SWIFT_UI_ACTOR ^)(NSDictionary<NSString *, id> *,
                                                    NSError *))completion;
@end
