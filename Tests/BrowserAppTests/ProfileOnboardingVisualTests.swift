// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import SwiftUI
import XCTest

@testable import ArcusisBrowser

@MainActor
final class ProfileOnboardingVisualTests: XCTestCase {
  func testEveryStepRendersInLightAndDark() throws {
    let output = URL(filePath: "/tmp/shaar-profile-onboarding")
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    for (schemeName, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
      for step in ProfileOnboardingStep.allCases {
        let model = Self.model(at: step)
        XCTAssertEqual(model.step, step)
        let url = output.appending(path: "\(step.rawValue + 1)-\(step)-\(schemeName).png")
        try VisualCapture.renderOffscreen(
          ProfileOnboardingView(model: model), size: ProfileOnboardingView.size,
          appearance: appearance, to: url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
      }
    }
  }

  /// The summary uses an authored session-photo fixture; no external account is accessed.
  private static func model(at step: ProfileOnboardingStep) -> ProfileOnboardingModel {
    var pendingSignIn: ((ConnectedAccount?) -> Void)?
    let model = ProfileOnboardingModel(
      actions: ProfileOnboardingActions(
        connect: { _, _, completion in pendingSignIn = completion },
        stopConnecting: {}, create: { $0.id }, close: { _ in }))
    model.name = "Acme Work"
    model.color = ProfileColorChoice(tint: .ocean)
    model.symbol = "briefcase.fill"
    while model.step != step {
      if model.step == .account {
        model.connect(.google)
        pendingSignIn?(
          ConnectedAccount(
            provider: .google, email: "alex@example.test", name: "Alex Example",
            photoData: try? AccountPhotoFixture.data()))
      }
      model.continueToNext()
    }
    return model
  }
}
