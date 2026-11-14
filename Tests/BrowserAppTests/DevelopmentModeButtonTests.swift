// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import BrowserCore
import Foundation
import SwiftUI
import Testing

@testable import ArcusisBrowser

@Test @MainActor func developmentLabelShowsDetectedFrameworkAndPort() throws {
  let page = DevelopmentPage.detect(
    url: URL(string: "http://localhost:5173/dashboard")!,
    markers: .init(resourcePaths: ["/@vite/client"]))
  let view = DevelopmentModeLabel(page: page)
    .frame(width: 200, height: 36)
    .background(Color.white)
    .environment(\.colorScheme, .light)
  let imageURL = FileManager.default.temporaryDirectory.appending(
    path: "development-mode-label-\(UUID().uuidString).png")
  defer { try? FileManager.default.removeItem(at: imageURL) }

  _ = try VisualCapture.renderOffscreen(
    view, size: NSSize(width: 200, height: 36), appearance: .aqua, to: imageURL)
  let visibleText = try VisualTextRecognition.lines(in: imageURL).joined(separator: " ")
  #expect(visibleText.contains("Vite"), "\(visibleText)")
  #expect(visibleText.contains("5173"), "\(visibleText)")
}
