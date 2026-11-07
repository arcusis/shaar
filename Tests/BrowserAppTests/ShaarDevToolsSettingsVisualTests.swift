// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import SwiftUI
import XCTest

@testable import ArcusisBrowser

@MainActor final class ShaarDevToolsSettingsVisualTests: XCTestCase {
  func testSettingsSheetRendersOffscreenInBothAppearances() throws {
    guard ProcessInfo.processInfo.environment["SHAAR_DEVTOOLS_SETTINGS_CAPTURE"] == "1" else {
      throw XCTSkip("Offscreen settings capture requires explicit opt-in")
    }
    _ = NSApplication.shared
    let previous = NSApp.keyWindow
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appending(path: "Evidence/issue-1309")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let defaults = UserDefaults(suiteName: "ShaarDevToolsSettingsCapture.\(UUID().uuidString)")!
    let target = SiteControlTarget(
      tabID: UUID(), profileID: UUID(), url: URL(string: "http://localhost:3000/")!)
    let inspector = InspectorModel(target: target, engine: nil)
    let shell = ShaarDevToolsModel(target: target, layoutDefaults: defaults)
    shell.open(inspector: inspector)
    shell.section = .console
    shell.dock = .bottom
    shell.chooseOpening(.panel(.console))
    shell.showSettings()

    for scheme in [ColorScheme.light, .dark] {
      let suffix = scheme == .dark ? "dark" : "light"
      let appearance: NSAppearance.Name = scheme == .dark ? .darkAqua : .aqua
      let panel = ShaarDevToolsPanel(model: shell, inspector: inspector, openChromium: {})
        .frame(width: 850, height: 620)
        .environment(\.colorScheme, scheme)
      try VisualCapture.renderOffscreen(
        panel, size: NSSize(width: 850, height: 620), appearance: appearance,
        to: root.appending(path: "after-settings-\(suffix).png"))
    }
    shell.close()
    XCTAssertTrue(NSApp.keyWindow === previous)
  }
}
