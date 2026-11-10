// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import SwiftUI
import XCTest

@testable import ArcusisBrowser

@MainActor final class HttpsOnlySettingsVisualTests: XCTestCase {
  func testPrivacySettingsRenderTheSecureConnectionsSwitchOffscreen() async throws {
    guard ProcessInfo.processInfo.environment["SHAAR_HTTPS_ONLY_CAPTURE"] == "1" else {
      throw XCTSkip("Offscreen settings capture requires SHAAR_HTTPS_ONLY_CAPTURE=1")
    }
    _ = NSApplication.shared
    let previous = NSApp.keyWindow
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appending(path: "Evidence/issue-1510")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let profileID = UUID()
    let size = NSSize(width: 720, height: 640)
    for scheme in [ColorScheme.light, .dark] {
      let suffix = scheme == .dark ? "dark" : "light"
      let appearance: NSAppearance.Name = scheme == .dark ? .darkAqua : .aqua
      let view = BrowserSettingsView(
        profiles: [
          BrowserSettingsProfile(
            id: profileID, name: "Personal",
            spaces: [
              BrowserSettingsSpace(id: UUID(), name: "Personal", symbol: "square.stack.3d.up")
            ])
        ],
        searchEngines: [BrowserSettingsChoice(id: "google", title: "Google")],
        selectedProfileID: .constant(profileID), sidebarInitiallyVisible: .constant(true),
        selectedSearchEngine: .constant("google"),
        httpsOnlyModeEnabled: { _ in true },
        onSetHttpsOnlyMode: { _, _ in true },
        initialSection: .privacy
      )
      .environment(\.colorScheme, scheme)
      let url = root.appending(path: "after-privacy-\(suffix).png")
      let image = try VisualCapture.renderOffscreen(
        view, size: size, appearance: appearance, to: url)
      XCTAssertEqual(image.pixelsWide, Int(size.width))
      XCTAssertEqual(image.pixelsHigh, Int(size.height))
      let visible = try VisualTextRecognition.lines(in: url).joined(separator: " ")
      XCTAssertTrue(
        visible.range(of: "Always use secure connections", options: .caseInsensitive) != nil,
        visible)
      XCTAssertTrue(visible.range(of: "Private Windows", options: .caseInsensitive) != nil, visible)
    }
    XCTAssertTrue(NSApp.keyWindow === previous)
  }
}
