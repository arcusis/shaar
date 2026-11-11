// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

enum ShaarDevToolsMetrics {
  static let bottomHeight: CGFloat = 380
  static let sideWidth: CGFloat = 420
}

enum ShaarDevToolsOpening: Equatable {
  case last
  case panel(ShaarDevToolsSection)

  static let key = "shaar.devtools.openingPanel"
  static let lastSectionKey = "shaar.devtools.lastSection"

  var storageValue: String {
    switch self {
    case .last: "Last panel"
    case .panel(let section): section.rawValue
    }
  }

  static func load(_ defaults: UserDefaults) -> Self {
    guard let raw = defaults.string(forKey: key) else { return .panel(.elements) }
    if raw == "Last panel" { return .last }
    if let section = ShaarDevToolsSection(rawValue: raw) { return .panel(section) }
    return .panel(.elements)
  }
}
