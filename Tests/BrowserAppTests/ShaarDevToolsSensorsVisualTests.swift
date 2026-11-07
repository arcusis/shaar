// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import SwiftUI
import XCTest

@testable import ArcusisBrowser

@MainActor final class ShaarDevToolsSensorsVisualTests: XCTestCase {
  func testSensorsPanelRendersOffscreenInBothAppearances() throws {
    guard ProcessInfo.processInfo.environment["SHAAR_DEVTOOLS_SENSORS_CAPTURE"] == "1" else {
      throw XCTSkip("Offscreen sensors capture requires explicit opt-in")
    }
    _ = NSApplication.shared
    let previous = NSApp.keyWindow
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appending(path: "Evidence/issue-1313")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    for scheme in [ColorScheme.light, .dark] {
      let suffix = scheme == .dark ? "dark" : "light"
      let appearance: NSAppearance.Name = scheme == .dark ? .darkAqua : .aqua
      try render(
        populated: false, name: "after-empty-\(suffix)", appearance: appearance, scheme: scheme,
        root: root)
      try render(
        populated: true, name: "after-sensors-\(suffix)", appearance: appearance, scheme: scheme,
        root: root)
    }
    XCTAssertTrue(NSApp.keyWindow === previous)
  }

  private func render(
    populated: Bool, name: String, appearance: NSAppearance.Name, scheme: ColorScheme, root: URL
  ) throws {
    let defaults = UserDefaults(suiteName: "ShaarDevToolsSensorsCapture.\(UUID().uuidString)")!
    let target = SiteControlTarget(
      tabID: UUID(), profileID: UUID(), url: URL(string: "http://localhost:3000/")!)
    let inspector = InspectorModel(target: target, engine: nil)
    let shell = ShaarDevToolsModel(target: target, layoutDefaults: defaults)
    shell.open(inspector: inspector)
    shell.section = .sensors
    if populated {
      shell.sensorLocation = .sanFrancisco
      shell.sensorTimezone = .newYork
      shell.sensorLocale = .french
      shell.sensorIdleReady = true
      shell.sensorIdle = .idle
    }
    let panel = ShaarDevToolsPanel(model: shell, inspector: inspector, openChromium: {})
      .frame(width: 850, height: 760)
      .environment(\.colorScheme, scheme)
    try VisualCapture.renderOffscreen(
      panel, size: NSSize(width: 850, height: 760), appearance: appearance,
      to: root.appending(path: "\(name).png"))
    shell.close()
  }
}
