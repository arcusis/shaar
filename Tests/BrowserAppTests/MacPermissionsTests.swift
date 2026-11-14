// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Testing

@testable import ArcusisBrowser

@Test func macPermissionsExposeStableIdentityAndPresentation() {
  #expect(
    MacPermission.allCases.map(\.id) == [
      "camera", "microphone", "location", "notifications", "screenRecording",
    ])
  #expect(
    MacPermission.allCases.map(\.symbol) == [
      "camera", "mic", "location", "bell.badge", "rectangle.dashed.badge.record",
    ])
  #expect(
    MacPermission.allCases.map(\.title) == [
      "Camera", "Microphone", "Location", "Notifications", "Screen Recording",
    ])
}

@Test func macPermissionsLinkToTheirSystemSettingsPrivacyPanes() throws {
  let expected: [(MacPermission, String)] = [
    (.camera, "Privacy_Camera"),
    (.microphone, "Privacy_Microphone"),
    (.location, "Privacy_LocationServices"),
    (.screenRecording, "Privacy_ScreenCapture"),
  ]
  for (permission, anchor) in expected {
    let url = try #require(permission.settingsURL)
    #expect(url.scheme == "x-apple.systempreferences")
    #expect(url.absoluteString.hasSuffix(anchor))
  }

  let notifications = try #require(MacPermission.notifications.settingsURL)
  #expect(notifications.scheme == "x-apple.systempreferences")
  #expect(notifications.absoluteString.contains("com.apple.Notifications-Settings.extension?id="))
}
