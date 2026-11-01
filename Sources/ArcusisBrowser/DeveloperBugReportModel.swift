// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

extension SiteControlsDeveloperModel {
  @discardableResult
  func createBugReport() async -> URL? {
    guard !creatingBugReport else { return nil }
    creatingBugReport = true
    reportFailure = nil
    defer { creatingBugReport = false }
    let destination = target
    let generation = documentGeneration
    let includeHeaders = includeSensitiveHeaders
    let simulations = simulation
    do {
      guard let engine,
        let directory = engine.runtime.downloadsDirectory(
          forProfileID: destination.profileID.uuidString),
        let snapshot = try await evaluate("globalThis.__shaarBugReportV1?.snapshot()")
          as? [String: Any]
      else {
        throw DeveloperModeFailure(
          "Page diagnostics are unavailable. Reload this page and try again.")
      }
      let capture = try await call(
        "Page.captureScreenshot", params: ["format": "png", "captureBeyondViewport": false])
      guard let encoded = capture["data"] as? String, encoded.utf8.count <= 44 * 1024 * 1024,
        let png = Data(base64Encoded: encoded),
        png.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]),
        destination == target, generation == documentGeneration
      else {
        throw DeveloperModeFailure("The page changed or its screenshot could not be captured.")
      }
      let version =
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        ?? "development"
      let console: [[String: Any]] = (snapshot["console"] as? [[String: Any]] ?? []).suffix(300).map
      { row in
        let time = row["time"] as? Double ?? 0
        return [
          "level": String((row["level"] as? String ?? "log").prefix(32)),
          "message": String((row["message"] as? String ?? "").prefix(4096)),
          "time": time.isFinite ? time : 0,
        ]
      }
      var viewport: [String: Double] = [:]
      for key in ["width", "height", "devicePixelRatio"] {
        if let value = (snapshot["viewport"] as? [String: Any])?[key] as? Double, value.isFinite,
          value >= 0
        {
          viewport[key] = min(value, 1_000_000)
        }
      }
      let metadata: [String: Any] = [
        "url": String((snapshot["url"] as? String ?? destination.url.absoluteString).prefix(8192)),
        "title": String((snapshot["title"] as? String ?? "").prefix(4096)), "shaarVersion": version,
        "engineVersion": engine.runtime.chromiumVersion,
        "macOSVersion": ProcessInfo.processInfo.operatingSystemVersionString,
        "viewport": viewport,
        "createdAt": ISO8601DateFormatter().string(from: Date()),
        "activeSimulations": try JSONSerialization.jsonObject(
          with: JSONEncoder().encode(simulations)),
        "sensitiveHeadersIncluded": includeHeaders, "captureScope": BugReportArchive.scope,
      ]
      let options: JSONSerialization.WritingOptions = [.prettyPrinted, .sortedKeys]
      let files = [
        "screenshot.png": png,
        "metadata.json": try JSONSerialization.data(withJSONObject: metadata, options: options),
        "console.json": try JSONSerialization.data(
          withJSONObject: console, options: options),
        "network.har": try JSONSerialization.data(
          withJSONObject: BugReportArchive.har(
            snapshot: snapshot, includeSensitiveHeaders: includeHeaders, version: version),
          options: options),
        "README.txt": Data(
          (BugReportArchive.scope + "\nSensitive HAR headers included: \(includeHeaders).\n").utf8),
      ]
      let file = try await BugReportArchive.save(files: files, directory: directory)
      reportURL = file
      engine.downloads.registerGeneratedFile(file, profileID: destination.profileID)
      if engine.store?.session.selectedSpace.profileID == destination.profileID {
        engine.store?.showLibraryDrawer(.downloads)
      }
      return file
    } catch {
      reportFailure = error.localizedDescription
      return nil
    }
  }
}
