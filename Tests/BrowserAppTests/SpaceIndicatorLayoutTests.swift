// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import BrowserCore
import SwiftUI
import Testing
import XCTest

@testable import ArcusisBrowser

struct SpaceIndicatorLayoutTests {
  @Test func stripAlwaysFitsAndRetainsSelection() {
    for count in [1, 3, 8, 15, 100] {
      for selected in 0..<count {
        for width: CGFloat in [22, 44, 60, 96, 120, 172] {
          let layout = SpaceIndicatorLayout(count: count, selectedIndex: selected, width: width)
          #expect(layout.visible.contains(selected))
          let used =
            layout.selectedWidth + CGFloat(layout.visible.count - 1) * layout.dotWidth
            + layout.overflowWidth
          #expect(used <= width + 0.001)
          #expect(layout.visible.lowerBound >= 0 && layout.visible.upperBound <= count)
          #expect(layout.visible.count == count || layout.overflowWidth > 0 || width <= 22)
        }
      }
    }
  }
}

@MainActor
final class SpaceIndicatorVisualTests: XCTestCase {
  private final class Measurements {
    var frames = SidebarRevealFrames()
  }

  func testFooterAtThreeEightAndFifteenSpacesInBothAppearances() throws {
    let root = URL(fileURLWithPath: "/tmp/shaar-space-indicators", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    for count in [3, 8, 15] {
      let store = BrowserStore()
      while store.session.spaces.count < count {
        XCTAssertTrue(
          store.createSpace(
            name: "Space \(store.session.spaces.count + 1)",
            sharingProfile: store.session.selectedSpace.profileID, tint: .ocean))
      }
      let spaces = store.session.spaces
      for index in [0, count / 2, count - 1] {
        store.perform(.space(spaces[index].id))
        for (appearance, scheme, name) in [
          (NSAppearance.Name.aqua, ColorScheme.light, "light"),
          (.darkAqua, .dark, "dark"),
        ] {
          let measurements = Measurements()
          let bitmap = try VisualCapture.renderOffscreen(
            BrowserSidebar(store: store).environment(\.colorScheme, scheme)
              .frame(width: 200, height: 520)
              .background(Color(nsColor: .windowBackgroundColor))
              .onPreferenceChange(SidebarSpaceRevealFramesPreferenceKey.self) {
                measurements.frames = $0
              },
            size: NSSize(width: 200, height: 520), appearance: appearance,
            to: root.appending(path: "spaces-\(count)-selected-\(index)-\(name).png"))
          XCTAssertEqual(bitmap.pixelsWide, 200)
          XCTAssertEqual(bitmap.pixelsHigh, 520)
          XCTAssertEqual(measurements.frames.selectedID, spaces[index].id)
          XCTAssertTrue(measurements.frames.viewport.contains(measurements.frames.selected))
        }
      }
    }
  }
}
