// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import Foundation
import Testing

@testable import ArcusisBrowser

@Suite
struct SidebarLayoutKeyTests {
  @Test func tracksOnlyFavoriteFolderAndTabLayoutFields() {
    let fixture = makeFixture(count: 300)
    let initial = key(fixture)
    #expect(initial == key(fixture))

    var changed = fixture
    changed.folders[0].isCollapsed.toggle()
    #expect(initial != key(changed))

    changed = fixture
    changed.tabs[0].isPinned.toggle()
    #expect(initial != key(changed))

    changed = fixture
    changed.favorites[0] = BrowserFavorite(
      id: uuid(90_000), profileID: uuid(1), originalURL: URL(string: "https://other.test")!)
    #expect(initial != key(changed))
  }

  @Test func sidebarLayoutKeyFocusedBenchmark() {
    let fixture = makeFixture(count: 1_000)
    let iterations = 25

    let legacyStart = ContinuousClock.now
    var legacyCount = 0
    for _ in 0..<iterations {
      legacyCount &+= makeLegacyKey(fixture).count
    }
    let legacySeconds = legacyStart.duration(to: .now).seconds

    let indexedStart = ContinuousClock.now
    var typedCount = 0
    for _ in 0..<iterations {
      let layoutKey = key(fixture)
      typedCount &+= layoutKey.favoriteIDs.count + layoutKey.folders.count + layoutKey.tabs.count
    }
    let typedSeconds = indexedStart.duration(to: .now).seconds

    #expect(legacyCount == typedCount)
    print("sidebarLayoutKeyLegacyFocusedBenchmark: \(legacySeconds) seconds")
    print("sidebarLayoutKeyTypedFocusedBenchmark: \(typedSeconds) seconds")
  }

  private struct Fixture {
    var favorites: [BrowserFavorite]
    var folders: [BrowserFolder]
    var tabs: [BrowserTab]
  }

  private func key(_ fixture: Fixture) -> SidebarLayoutKey {
    SidebarLayoutKey(
      favorites: fixture.favorites, folders: fixture.folders, tabs: fixture.tabs)
  }

  private func makeLegacyKey(_ fixture: Fixture) -> [String] {
    fixture.favorites.map { $0.id.uuidString }
      + fixture.folders.map {
        "\($0.id):\($0.parentID?.uuidString ?? "root"):\($0.isPinned):\($0.isCollapsed)"
      }
      + fixture.tabs.map {
        "\($0.id):\($0.isPinned):\($0.folderID?.uuidString ?? "root")"
      }
  }

  private func makeFixture(count: Int) -> Fixture {
    let profileID = uuid(count + 1)
    let favorites = (0..<count).map { index in
      BrowserFavorite(
        id: uuid(index + 1), profileID: profileID,
        originalURL: URL(string: "https://example.com/favorite/\(index)")!)
    }
    let folders = (0..<count / 10).map { index in
      BrowserFolder(
        id: uuid(count + 2_000 + index), name: "Folder \(index)",
        parentID: index.isMultiple(of: 2) ? nil : uuid(count + 2_000 + index / 2),
        isCollapsed: index.isMultiple(of: 3), isPinned: index.isMultiple(of: 2))
    }
    let tabs = (0..<count).map { index in
      BrowserTab(
        id: uuid(count + 4_000 + index),
        url: URL(string: "https://example.com/tab/\(index)")!,
        isPinned: index.isMultiple(of: 2),
        folderID: index.isMultiple(of: 3) ? uuid(count + 2_000 + index / 10) : nil)
    }
    return Fixture(favorites: favorites, folders: folders, tabs: tabs)
  }

  private func uuid(_ value: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-0000-0000-%012X", value))!
  }
}

private extension Duration {
  var seconds: Double {
    let components = components
    return Double(components.seconds) + Double(components.attoseconds) / 1e18
  }
}
