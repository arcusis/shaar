// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import XCTest

@testable import ArcusisBrowser

@MainActor
final class FirstRunVisualTests: XCTestCase {
  func testProgressIndicatorAnnouncesCurrentStep() {
    XCTAssertEqual(
      FirstRunSetupView.progressAccessibilityLabel(for: .space),
      SettingsL10n.format("Step %d of %d", .integer(4), .integer(FirstRunStep.allCases.count)))
  }

  func testEveryStepRendersOffscreenInLightAndDark() throws {
    let output = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: output) }

    for appearance in [NSAppearance.Name.aqua, .darkAqua] {
      for step in FirstRunStep.allCases {
        let destination = output.appending(path: "\(step.rawValue)-\(appearance.rawValue).png")
        let image = try VisualCapture.renderOffscreen(
          FirstRunSetupView(
            store: BrowserStore.preview(showCommand: false), location: .installed,
            initialStep: step, onFinish: {}),
          size: NSSize(width: 760, height: 500), appearance: appearance, to: destination)
        XCTAssertEqual(image.pixelsWide, 760)
        XCTAssertEqual(image.pixelsHigh, 500)
        XCTAssertGreaterThan(try Data(contentsOf: destination).count, 50_000)
      }
    }
  }

  func testDiskImageGuidanceRendersOffscreen() throws {
    let destination = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: destination) }
    let image = try VisualCapture.renderOffscreen(
      FirstRunSetupView(
        store: BrowserStore.preview(showCommand: false), location: .diskImage,
        onFinish: {}),
      size: NSSize(width: 760, height: 500), appearance: .aqua, to: destination)
    XCTAssertEqual(image.pixelsWide, 760)
    XCTAssertGreaterThan(try Data(contentsOf: destination).count, 50_000)
  }
}
