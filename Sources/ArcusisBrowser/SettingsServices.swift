import AppKit
import ChromiumBridge
import Foundation

@MainActor
enum BrowserSettingsAppearance {
  /// Needs the application object, which the Chromium runtime creates.
  static func apply(_ value: String) {
    guard let app = NSApp else { return }
    switch value {
    case "light": app.appearance = NSAppearance(named: .aqua)
    case "dark": app.appearance = NSAppearance(named: .darkAqua)
    default: app.appearance = nil
    }
  }
}

@MainActor
enum SettingsHistory {
  static func clear(runtime: ARCChromiumRuntime, profileID: UUID) async throws {
    var previous: Set<String>?
    while true {
      let rows = try await runtime.history(forProfileID: profileID.uuidString, limit: 500)
      guard !rows.isEmpty else { return }
      let urls = try rows.map { row -> String in
        guard let url = row["url"] as? String, !url.isEmpty else {
          throw CocoaError(.coderInvalidValue)
        }
        return url
      }
      let batch = Set(urls)
      guard batch != previous else { throw CocoaError(.fileWriteUnknown) }
      previous = batch
      for url in batch {
        try await runtime.deleteHistoryURL(url, profileID: profileID.uuidString)
      }
    }
  }
}
