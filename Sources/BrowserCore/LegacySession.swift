// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Decode v1 separately so v2 requires its folder arrays and older apps reject v2 files.
struct LegacySpace: Decodable {
  let value: BrowserSpace
  private enum CodingKeys: String, CodingKey {
    case id, profileID, name, symbol, tint, tabs, selectedTabID, folders
  }

  init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    guard try c.decodeIfPresent([BrowserFolder].self, forKey: .folders)?.isEmpty != false else {
      throw SessionError.invalidState
    }
    let selected = try c.decodeIfPresent(UUID.self, forKey: .selectedTabID)
    var migrated = BrowserSpace(
      id: try c.decode(UUID.self, forKey: .id),
      profileID: try c.decode(UUID.self, forKey: .profileID),
      name: try c.decode(String.self, forKey: .name),
      symbol: try c.decode(String.self, forKey: .symbol),
      tint: try c.decode(SpaceTint.self, forKey: .tint),
      tabs: try c.decode([LegacyTab].self, forKey: .tabs).map(\.value), selectedTabID: selected)
    migrated.selectedTabID = selected
    value = migrated
  }
}

private struct LegacyTab: Decodable {
  let value: BrowserTab
  private enum CodingKeys: String, CodingKey { case id, url, title, isPinned, folderID }

  init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    guard try c.decodeIfPresent(UUID.self, forKey: .folderID) == nil else {
      throw SessionError.invalidState
    }
    value = BrowserTab(
      id: try c.decode(UUID.self, forKey: .id), url: try c.decode(URL.self, forKey: .url),
      title: try c.decode(String.self, forKey: .title),
      isPinned: try c.decode(Bool.self, forKey: .isPinned))
  }
}
