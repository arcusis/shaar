// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

enum TabMaterializationPolicy {
  enum Decision: Equatable {
    case keepLive
    case materialize
    case deferred
  }

  static func decision(isSelected: Bool, isLive: Bool, lazy: Bool) -> Decision {
    if isLive { return .keepLive }
    if !lazy || isSelected { return .materialize }
    return .deferred
  }
}
