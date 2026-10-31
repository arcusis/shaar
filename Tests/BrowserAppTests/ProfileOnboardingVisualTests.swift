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

  /// Google is captured connected and Microsoft waiting on its sign-in window, so both account
  /// states appear across the set. Done follows the Google connection, which passes over the
  /// Microsoft step.
  private static func model(at step: ProfileOnboardingStep) -> ProfileOnboardingModel {
    var pendingSignIn: ((ConnectedAccount?) -> Void)?
    let model = ProfileOnboardingModel(
      actions: ProfileOnboardingActions(
        connect: { _, _, completion in pendingSignIn = completion },
        stopConnecting: {}, create: { $0.id }, close: { _ in }))
    model.name = "Acme Work"
    model.color = ProfileColorChoice(tint: .ocean)
    model.symbol = "briefcase.fill"
    guard step != .details else { return model }
    model.continueToNext()
    if step == .microsoft {
      model.skip()
      model.connect(.microsoft)
      return model
    }
    model.connect(.google)
    pendingSignIn?(
      ConnectedAccount(provider: .google, email: "alex@acme.test", name: "Alex Example"))
    guard step != .google else { return model }
    model.continueToNext()
    return model
  }
}
