// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Native notifications may arrive inside a TabStripModel mutation. Only those
// callbacks need to defer activation; host actions can select synchronously.
FOUNDATION_EXPORT void ARCPerformShaarEventCallback(
    void (NS_NOESCAPE ^callback)(void)) NS_SWIFT_UI_ACTOR;
FOUNDATION_EXPORT void ARCDispatchShaarTabActivation(
    void (NS_SWIFT_UI_ACTOR ^activation)(void)) NS_SWIFT_UI_ACTOR;

// A host-tagged event is suppressible only when it matches the host's latest
// requested target. A nested extension activation can inherit the host tag.
FOUNDATION_EXPORT BOOL ARCShouldIgnoreHostTabActivation(
    NSString * _Nullable source, NSString *tabID,
    NSString * _Nullable hostTargetTabID);

NS_ASSUME_NONNULL_END
