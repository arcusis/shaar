// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import BrowserCore
import Foundation
import SwiftUI
import Testing

@testable import ArcusisBrowser

@Test @MainActor func oomFailureShowsRecoveryMessageAndReloadAction() throws {
  let failure = RendererFailure(
    profileID: UUID(), tabID: UUID(), pageURL: URL(string: "https://research.example/page")!,
    status: "oom", exitCode: 9)
  let view = FailedPageView(store: BrowserStore(), failure: failure)
    .frame(width: 500, height: 300)
    .background(Color.white)
    .environment(\.colorScheme, .light)
  let imageURL = FileManager.default.temporaryDirectory.appending(
    path: "failed-page-\(UUID().uuidString).png")
  defer { try? FileManager.default.removeItem(at: imageURL) }

  _ = try VisualCapture.renderOffscreen(
    view, size: NSSize(width: 500, height: 300), appearance: .aqua, to: imageURL)
  let visibleText = try VisualTextRecognition.lines(in: imageURL).joined(separator: " ")
  #expect(visibleText.contains("This page stopped working"), "\(visibleText)")
  #expect(visibleText.contains("research example"), "\(visibleText)")
  #expect(visibleText.contains("ran out of memory"), "\(visibleText)")
  #expect(visibleText.contains("Reload page"), "\(visibleText)")
}
