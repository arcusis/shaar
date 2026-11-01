// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing

@testable import BrowserCore

@Test func siteOriginKeepsSchemeHostAndPortOfWebPagesOnly() {
  #expect(
    SiteOrigin.string(for: URL(string: "https://Mail.Example.com/inbox?x=1#y")!)
      == "https://mail.example.com")
  #expect(
    SiteOrigin.string(for: URL(string: "http://localhost:8080/path")!)
      == "http://localhost:8080")
  #expect(SiteOrigin.string(for: URL(string: "file:///tmp/page.html")!) == nil)
  #expect(SiteOrigin.string(for: URL(string: "chrome://settings")!) == nil)
  #expect(SiteOrigin.string(for: URL(string: "about:blank")!) == nil)
}

@Test func siteSecurityTreatsEveryEngineWarningAsNotSecure() {
  #expect(SiteSecurity(engineLevel: "secure") == .secure)
  for level in ["insecure", "certificateError", "mixed"] {
    #expect(SiteSecurity(engineLevel: level) == .notSecure)
  }
  for level in ["local", "none", nil] {
    #expect(SiteSecurity(engineLevel: level) == .unavailable)
  }
}

@Test func sitePermissionValuesReadOnlyShownEngineSettings() {
  let parsed = SitePermissionValues.parse([
    "camera": ["value": "ask", "isDefault": true],
    "microphone": ["value": "block", "isDefault": false],
    "popups": ["value": "allow", "isDefault": false],
    "sound": ["value": "unexpected"],
    "javascript": ["value": "allow"],
    "location": "allow",
  ])
  #expect(parsed == [.camera: .ask, .microphone: .block, .popups: .allow])
}

@Test func automaticPictureInPictureHasNoEngineSiteSetting() {
  #expect(SitePermission.autoPictureInPicture.engineSettingName == nil)
  let engineNames = SitePermission.allCases.compactMap(\.engineSettingName)
  #expect(engineNames == ["microphone", "camera", "location", "notifications", "popups", "sound"])
}
