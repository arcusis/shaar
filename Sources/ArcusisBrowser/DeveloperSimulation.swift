// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

struct DeveloperSimulation: Codable, Equatable, Sendable {
  enum Device: String, Codable, CaseIterable { case desktop, phone, tablet }
  enum Network: String, Codable, CaseIterable { case normal, slow3G, offline }
  enum CPU: Int, Codable, CaseIterable {
    case normal = 1
    case four = 4
    case six = 6
  }
  enum Location: String, Codable, CaseIterable { case actual, sanFrancisco, london }
  enum Timezone: String, Codable, CaseIterable { case system, newYork, tokyo }
  enum Language: String, Codable, CaseIterable { case system, english, french, hebrew }

  var device = Device.desktop
  var network = Network.normal
  var cpu = CPU.normal
  var location = Location.actual
  var timezone = Timezone.system
  var language = Language.system
  var darkMode = false
  var reducedMotion = false
  var isActive: Bool { self != Self() }

  var locale: String {
    switch language {
    case .system: ""
    case .english: "en-US"
    case .french: "fr-FR"
    case .hebrew: "he-IL"
    }
  }

  /// Every apply includes clear operations, so a tab never carries another site's overrides.
  func commands(userAgent: String) -> [(String, [String: Any])] {
    var calls: [(String, [String: Any])] = []
    if device == .desktop {
      calls.append(("Emulation.clearDeviceMetricsOverride", [:]))
    } else {
      let phone = device == .phone
      calls.append(
        (
          "Emulation.setDeviceMetricsOverride",
          [
            "width": phone ? 390 : 820, "height": phone ? 844 : 1180,
            "deviceScaleFactor": phone ? 3 : 2, "mobile": true,
          ]
        ))
    }
    calls += [
      ("Network.enable", [:]),
      (
        "Network.emulateNetworkConditions",
        [
          "offline": network == .offline, "latency": network == .slow3G ? 400 : 0,
          "downloadThroughput": network == .slow3G ? 50_000 : -1,
          "uploadThroughput": network == .slow3G ? 50_000 : -1,
        ]
      ),
      ("Emulation.setCPUThrottlingRate", ["rate": cpu.rawValue]),
    ]
    switch location {
    case .actual: calls.append(("Emulation.clearGeolocationOverride", [:]))
    case .sanFrancisco:
      calls.append(
        (
          "Emulation.setGeolocationOverride",
          ["latitude": 37.7749, "longitude": -122.4194, "accuracy": 1]
        ))
    case .london:
      calls.append(
        (
          "Emulation.setGeolocationOverride",
          ["latitude": 51.5074, "longitude": -0.1278, "accuracy": 1]
        ))
    }
    let zone =
      switch timezone {
      case .system: ""
      case .newYork: "America/New_York"
      case .tokyo: "Asia/Tokyo"
      }
    calls += [
      ("Emulation.setTimezoneOverride", ["timezoneId": zone]),
      ("Emulation.setLocaleOverride", ["locale": locale]),
      (
        "Emulation.setUserAgentOverride",
        locale.isEmpty ? ["userAgent": ""] : ["userAgent": userAgent, "acceptLanguage": locale]
      ),
      (
        "Emulation.setEmulatedMedia",
        [
          "features": [
            ["name": "prefers-color-scheme", "value": darkMode ? "dark" : ""],
            ["name": "prefers-reduced-motion", "value": reducedMotion ? "reduce" : ""],
          ]
        ]
      ),
    ]
    return calls
  }
}
