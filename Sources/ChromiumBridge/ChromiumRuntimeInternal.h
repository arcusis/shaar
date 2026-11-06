// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#import "include/ChromiumBridge.h"
#import "ChromiumWebStoreFit.h"

NSError *ARCBridgeError(NSString *message);
BOOL ARCIsCanonicalID(NSString *value);
NSString *ARCValidatedProfileID(NSString *profileID);

// The verification target may observe a PiP window before the app uses it.
// The shipping bridge never interprets probe arguments or changes window visibility.
typedef void (*ARCPictureInPictureWindowObserver)(NSWindow *window);
void ARCSetPictureInPictureWindowObserver(ARCPictureInPictureWindowObserver observer);

@interface ARCShaarRuntime (DevToolsTransport)
- (BOOL)shaarPrivateDevToolsSubmit:(NSUInteger)operation tabID:(NSString *)tabID
                        windowID:(NSString *)windowID contextID:(NSString *)contextID
                         payload:(NSDictionary *)payload
                      completion:(void (^)(NSDictionary *, NSError *))completion;
- (nullable NSString *)shaarDevToolsProfileIDForTabID:(NSString *)tabID;
- (BOOL)shaarDevToolsOwnsTabID:(NSString *)tabID profileID:(NSString *)profileID
                    windowID:(NSString *)windowID;
- (BOOL)shaarDevToolsSubmit:(NSUInteger)operation tabID:(NSString *)tabID
                 profileID:(NSString *)profileID windowID:(NSString *)windowID
                   payload:(NSDictionary *)payload
                completion:(void (^)(NSDictionary *, NSError *))completion;
- (void)shaarDevToolsCall:(NSString *)method params:(NSDictionary *)params
              capability:(NSUInteger)capability tabID:(NSString *)tabID
               profileID:(NSString *)profileID windowID:(NSString *)windowID
              completion:(void (NS_SWIFT_UI_ACTOR ^)(NSDictionary<NSString *, id> *, NSError *))completion;
- (void)shaarPrivateDevToolsCall:(NSString *)method params:(NSDictionary *)params
                     capability:(NSUInteger)capability tabID:(NSString *)tabID
                       windowID:(NSString *)windowID contextID:(NSString *)contextID
                     completion:(void (NS_SWIFT_UI_ACTOR ^)(NSDictionary<NSString *, id> *, NSError *))completion;
@end
