// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#import "ChromiumShaarActivation.h"

namespace {
thread_local unsigned eventDepth = 0;
struct EventScope {
  EventScope() { ++eventDepth; }
  ~EventScope() { --eventDepth; }
};
}

void ARCPerformShaarEventCallback(void (NS_NOESCAPE ^callback)(void)) {
  EventScope scope;
  callback();
}

void ARCDispatchShaarTabActivation(void (^activation)(void)) {
  if (eventDepth) {
    dispatch_async(dispatch_get_main_queue(), activation);
  } else {
    activation();
  }
}
