// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import BrowserCore
import SwiftUI
import XCTest

@testable import ArcusisBrowser

@MainActor final class DevelopmentModeVisualTests: XCTestCase {
  func testToolbarComponentBeforeAfterCapture() throws {
    guard ProcessInfo.processInfo.environment["SHAAR_DEVMODE_CAPTURE"] == "1" else {
      throw XCTSkip("Offscreen capture requires explicit opt-in")
    }
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appending(path: "Evidence/1086")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let url = URL(string: "http://localhost:3000/dashboard")!
    let page = DevelopmentPage.detect(
      url: url, markers: .init(resourcePaths: ["/_next/static/chunk.js"]))
    let size = NSSize(width: 760, height: 60)
    for enabled in [false, true] {
      let view = HStack(spacing: 4) {
        Image(systemName: "arrow.left").frame(width: 28, height: 28)
        Image(systemName: "arrow.right").frame(width: 28, height: 28)
        Spacer()
        Text(enabled ? url.absoluteString : "localhost:3000")
          .font(.system(size: 13)).foregroundStyle(.secondary)
        Spacer()
        if enabled { DevelopmentModeLabel(page: page) }
        Image(systemName: "slider.horizontal.3").frame(width: 28, height: 28)
      }
      .padding(.horizontal, 6)
      .frame(height: 34)
      .frame(width: size.width, height: size.height)
      .background(Color(nsColor: .windowBackgroundColor))
      _ = try VisualCapture.renderOffscreen(
        view, size: size, appearance: .aqua,
        to: root.appending(path: enabled ? "toolbar-after.png" : "toolbar-before.png"))
    }
  }
}
