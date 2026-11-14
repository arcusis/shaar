// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import Foundation
import SwiftUI
import Testing

@testable import BrowserCore
@testable import ArcusisBrowser

@Test @MainActor func selectedResultRowShowsItsTitleSubtitleAndActionHint() throws {
  let result = CommandResult(
    title: "Research", subtitle: "research.example", symbol: "globe",
    action: .open(URL(string: "https://research.example")!))
  let view = CommandResultRow(
    result: result, subtitle: result.subtitle, favicon: nil, actionHint: "Open in New Tab")
  let imageURL = FileManager.default.temporaryDirectory.appending(
    path: "command-result-row-\(UUID().uuidString).png")
  defer { try? FileManager.default.removeItem(at: imageURL) }
  let capturedView = view
    .frame(width: 560, height: BrowserChromeLayout.resultRowHeight)
    .background(Color.white)
    .environment(\.colorScheme, .light)

  _ = try VisualCapture.renderOffscreen(
    capturedView, size: NSSize(width: 560, height: BrowserChromeLayout.resultRowHeight),
    appearance: .aqua, to: imageURL)
  let visibleText = try VisualTextRecognition.lines(in: imageURL).joined(separator: " ")
  #expect(visibleText.contains("Research"), "\(visibleText)")
  #expect(visibleText.contains("research.example"), "\(visibleText)")
  #expect(visibleText.contains("Open in New Tab"), "\(visibleText)")
}
