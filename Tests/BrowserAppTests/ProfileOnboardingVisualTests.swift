// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import BrowserCore
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
        try Self.capture(
          ProfileOnboardingView(model: model), size: ProfileOnboardingView.size,
          appearance: appearance, to: url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
      }
    }
  }

  func testSettingsProfilesShowAndEditTheProfileColor() throws {
    let output = URL(filePath: "/tmp/shaar-profile-onboarding")
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    let workID = UUID()
    let profiles = [
      BrowserSettingsProfile(
        id: UUID(), name: "Personal", color: ProfileColorChoice(tint: .rose),
        spaces: [BrowserSettingsSpace(id: UUID(), name: "Home", symbol: "house")]),
      BrowserSettingsProfile(
        id: workID, name: "Acme Work", color: ProfileColorChoice(tint: .ocean),
        spaces: [BrowserSettingsSpace(id: UUID(), name: "Research", symbol: "book")],
        accounts: [ConnectedAccount(provider: .microsoft, email: "alex@acme.onmicrosoft.com")]),
      BrowserSettingsProfile(id: UUID(), name: "Uncolored", spaces: []),
    ]
    for (schemeName, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
      let view = BrowserSettingsView(
        profiles: profiles, searchEngines: [BrowserSettingsChoice(id: "google", title: "Google")],
        selectedProfileID: .constant(workID), sidebarInitiallyVisible: .constant(true),
        selectedSearchEngine: .constant("google"), initialSection: .profiles)
      let url = output.appending(path: "settings-profiles-\(schemeName).png")
      try Self.capture(view, size: NSSize(width: 720, height: 560), appearance: appearance, to: url)
      XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }
  }

  /// Google is captured connected and Microsoft waiting on its sign-in window, so both account
  /// states appear across the set.
  private static func model(at step: ProfileOnboardingStep) -> ProfileOnboardingModel {
    var pendingSignIn: ((ConnectedAccount?) -> Void)?
    let model = ProfileOnboardingModel(
      actions: ProfileOnboardingActions(
        connect: { _, _, completion in pendingSignIn = completion },
        stopConnecting: {}, create: { $0.id }, close: { _ in }))
    model.name = "Acme Work"
    model.color = ProfileColorChoice(tint: .ocean)
    guard step != .details else { return model }
    model.continueToNext()
    model.connect(.google)
    pendingSignIn?(
      ConnectedAccount(provider: .google, email: "alex@acme.test", name: "Alex Example"))
    guard step != .google else { return model }
    model.continueToNext()
    model.connect(.microsoft)
    guard step != .microsoft else { return model }
    pendingSignIn?(ConnectedAccount(provider: .microsoft, email: "alex@acme.onmicrosoft.com"))
    model.continueToNext()
    return model
  }

  private static func capture<V: View>(
    _ view: V, size: NSSize, appearance: NSAppearance.Name, to url: URL
  ) throws {
    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: size), styleMask: [], backing: .buffered,
      defer: false)
    window.isReleasedWhenClosed = false
    window.appearance = NSAppearance(named: appearance)
    defer { window.close() }
    let host = NSHostingView(rootView: view)
    window.contentView = host
    host.frame = NSRect(origin: .zero, size: size)
    host.layoutSubtreeIfNeeded()
    window.displayIfNeeded()
    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    host.layoutSubtreeIfNeeded()
    _ = try VisualCapture.render(host, to: url)
  }
}
