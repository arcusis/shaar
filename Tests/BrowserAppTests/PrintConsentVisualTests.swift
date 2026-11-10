// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import BrowserCore
import SwiftUI
import XCTest

@testable import ArcusisBrowser

@MainActor final class PrintConsentVisualTests: XCTestCase {
  func testPrintConsentBeforeAndAfterOffscreen() throws {
    guard ProcessInfo.processInfo.environment["SHAAR_PRINT_EVIDENCE"] == "1" else {
      throw XCTSkip("Print consent evidence capture requires explicit opt-in")
    }
    _ = NSApplication.shared
    let previousKeyWindow = NSApp.keyWindow
    let evidence = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appending(path: "Evidence/issue-1508")
    try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
    let request = try XCTUnwrap(
      PrintRequest(payload: [
        "id": UUID().uuidString,
        "profileID": UUID().uuidString,
        "tabID": UUID().uuidString,
        "pageURL": "https://example.com/research/print-preview",
        "origin": "https://example.com",
        "frameID": "0123456789abcdef0123456789abcdef",
        "title": "A research article",
      ]))
    let size = NSSize(width: 900, height: 580)
    let before = PrintEvidencePage(request: nil).frame(width: size.width, height: size.height)
    let beforeImage = try VisualCapture.renderOffscreen(
      before, size: size, appearance: .aqua, to: evidence.appending(path: "before.png"))
    XCTAssertEqual(beforeImage.pixelsWide, 900)

    let after = PrintEvidencePage(request: request).frame(width: size.width, height: size.height)
    let afterImage = try VisualCapture.renderOffscreen(
      after, size: size, appearance: .aqua, to: evidence.appending(path: "after.png"))
    XCTAssertEqual(afterImage.pixelsWide, 900)
    XCTAssertTrue(NSApp.keyWindow === previousKeyWindow)
  }
}

private struct PrintEvidencePage: View {
  let request: PrintRequest?

  var body: some View {
    ZStack {
      VStack(alignment: .leading, spacing: 16) {
        Text("example.com")
          .font(.system(size: 12, design: .monospaced))
          .foregroundStyle(.secondary)
        Divider()
        Text("A research article")
          .font(.system(size: 30, weight: .semibold))
        Text("The article is open in the browser.")
          .font(.system(size: 15))
          .foregroundStyle(.secondary)
        Spacer()
      }
      .padding(36)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .background(Color(nsColor: .textBackgroundColor))

      if let request {
        PrintConsentContent(request: request, onCancel: {}, onPrint: {})
          .background {
            RoundedRectangle(cornerRadius: 12)
              .fill(Color(nsColor: .windowBackgroundColor))
              .shadow(color: .black.opacity(0.22), radius: 24, y: 12)
          }
      }
    }
  }
}
