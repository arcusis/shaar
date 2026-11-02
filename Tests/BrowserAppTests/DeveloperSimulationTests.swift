// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing

@testable import ArcusisBrowser

@MainActor @Test func simulationsPersistAndStayIsolated() throws {
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let file = root.appending(path: "preferences.json")
  let profile = UUID()
  let other = UUID()
  let preferences = BrowserPreferencesStore(fileURL: file)
  var value = DeveloperSimulation()
  value.device = .phone
  value.language = .french
  preferences.setDeveloperSimulation(value, on: "https://example.com", for: profile)
  let loaded = BrowserPreferencesStore(fileURL: file)
  #expect(loaded.developerSimulation(on: "https://example.com", for: profile) == value)
  #expect(!loaded.developerSimulation(on: "https://example.com", for: other).isActive)
  #expect(!loaded.developerSimulation(on: "https://other.com", for: profile).isActive)
  loaded.setDeveloperSimulation(DeveloperSimulation(), on: "https://example.com", for: profile)
  #expect(
    !BrowserPreferencesStore(fileURL: file).developerSimulation(
      on: "https://example.com", for: profile
    ).isActive)
}

@Test func simulationResetClearsEveryOverride() {
  let commands = DeveloperSimulation().commands(userAgent: "fixture")
  #expect(commands.contains { $0.0 == "Emulation.clearDeviceMetricsOverride" })
  #expect(commands.contains { $0.0 == "Emulation.clearGeolocationOverride" })
  #expect(commands.first { $0.0 == "Emulation.setCPUThrottlingRate" }?.1["rate"] as? Int == 1)
  #expect(
    commands.first { $0.0 == "Emulation.setTimezoneOverride" }?.1["timezoneId"] as? String == "")
  #expect(
    commands.first { $0.0 == "Emulation.setUserAgentOverride" }?.1["userAgent"] as? String == "")
}
