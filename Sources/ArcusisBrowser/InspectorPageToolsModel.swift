// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Observation

@MainActor @Observable
final class InspectorPageToolsModel {
  enum Tool: String, CaseIterable {
    case overview = "Tech stack"
    case vitals = "Vitals"
    case network = "Network"
    case console = "Console"
    case storage = "Storage"
    case simulations = "Simulations"
    case report = "Bug report"
    var symbol: String {
      switch self {
      case .overview: "shippingbox"
      case .vitals: "waveform.path.ecg"
      case .network: "network"
      case .console: "terminal"
      case .storage: "externaldrive"
      case .simulations: "slider.horizontal.3"
      case .report: "ladybug"
      }
    }
  }
  struct StackSignal: Decodable, Identifiable {
    let name: String
    let version: String?
    let source: String
    var id: String { name }
  }
  struct ConsoleRow: Decodable {
    let level: String
    let message: String
    let time: Double
  }
  struct RequestRow: Identifiable {
    let id: Int
    let url: String
    let method: String
    let status: Int
    let duration: Double?
    let bytes: Double?
    let kind: String
  }
  struct StorageRow: Decodable, Identifiable {
    let key: String
    let preview: String
    let length: Int
    var id: String { key }
  }
  struct Cookie: Identifiable {
    let raw: [String: Any]
    var name: String { raw["name"] as? String ?? "" }
    var value: String { raw["value"] as? String ?? "" }
    var domain: String { raw["domain"] as? String ?? "" }
    var path: String { raw["path"] as? String ?? "/" }
    var id: String {
      name + "|" + domain + "|" + path + "|"
        + ((try? JSONSerialization.data(
          withJSONObject: raw["partitionKey"] ?? [:], options: [.sortedKeys])).flatMap {
            String(data: $0, encoding: .utf8)
          } ?? "")
    }
    var editable: Bool { raw["partitionKeyOpaque"] as? Bool != true }
  }
  @ObservationIgnored weak var inspector: InspectorModel?
  let developer: DeveloperPageModel
  var tool = Tool.overview
  var storageArea = "local"
  private(set) var signals: [StackSignal] = []
  private(set) var console: [ConsoleRow] = []
  private(set) var requests: [RequestRow] = []
  private(set) var storage: [StorageRow] = []
  private(set) var cookies: [Cookie] = []
  private(set) var storageLimited = false
  private(set) var active = false
  private(set) var failure: String?
  private(set) var cpu: Double?
  private(set) var startedAt: Date?
  @ObservationIgnored private let owner = UUID().uuidString
  private var recordingScript: String {
    InspectorDiagnosticsScript.install.replacingOccurrences(
      of: "__SHAAR_DIAGNOSTICS_OWNER__", with: owner)
  }
  @ObservationIgnored private var bootstrapID: String?
  @ObservationIgnored private var bootstrapTarget: SiteControlTarget?
  @ObservationIgnored private var busy = false
  @ObservationIgnored private var previousCPU: (Double, Double)?
  @ObservationIgnored private var epoch = -1
  @ObservationIgnored private var storageUpdated = Date.distantPast
  @ObservationIgnored private var pollTask: Task<Void, Never>?

  init(inspector: InspectorModel, developer: DeveloperPageModel) {
    self.inspector = inspector
    self.developer = developer
  }

  func start() {
    guard !active else { return }
    active = true
    pollTask = Task { [weak self] in
      while !Task.isCancelled {
        if let self, self.active { await self.refresh() } else { return }
        do { try await Task.sleep(for: .seconds(1)) } catch { return }
      }
    }
  }

  func documentChanged() {
    signals = []
    console = []
    requests = []
    cookies = []
    storage = []
    cpu = nil
    previousCPU = nil
    startedAt = nil
    storageUpdated = .distantPast
    failure = nil
  }

  func stop() {
    active = false
    pollTask?.cancel()
    pollTask = nil
    developer.setPerformanceEnabled(false)
    let script = bootstrapID
    let owner = owner
    let destination = bootstrapTarget
    bootstrapID = nil
    bootstrapTarget = nil
    if let engine = inspector?.engine, let destination {
      let window = engine.windowID
      Task { [weak runtime = engine.runtime] in
        if let script {
          _ = try? await runtime?.developerCall(
            "Page.removeScriptToEvaluateOnNewDocument", params: ["identifier": script],
            tabID: destination.tabID.uuidString, profileID: destination.profileID.uuidString,
            windowID: window)
        }
        _ = try? await runtime?.developerCall(
          "Runtime.evaluate",
          params: [
            "expression":
              InspectorDiagnosticsScript.dispose(owner: owner)
          ], tabID: destination.tabID.uuidString, profileID: destination.profileID.uuidString,
          windowID: window)
      }
    }
    documentChanged()
  }

  private func recording() async throws {
    guard let inspector, let engine = inspector.engine else {
      throw InspectorFailure("The page is no longer available.")
    }
    if bootstrapID == nil {
      let target = developer.target
      let window = engine.windowID
      let result = try await engine.runtime.developerCall(
        "Page.addScriptToEvaluateOnNewDocument", params: ["source": recordingScript],
        tabID: target.tabID.uuidString, profileID: target.profileID.uuidString, windowID: window)
      guard let id = result["identifier"] as? String else {
        throw InspectorFailure("Chromium did not install the page diagnostics bootstrap.")
      }
      if active {
        bootstrapID = id
        bootstrapTarget = target
      } else {
        _ = try? await engine.runtime.developerCall(
          "Page.removeScriptToEvaluateOnNewDocument", params: ["identifier": id],
          tabID: target.tabID.uuidString, profileID: target.profileID.uuidString, windowID: window)
        // A navigation can execute the bootstrap before its registration reply arrives.
        _ = try? await engine.runtime.developerCall(
          "Runtime.evaluate",
          params: ["expression": InspectorDiagnosticsScript.dispose(owner: owner)],
          tabID: target.tabID.uuidString, profileID: target.profileID.uuidString, windowID: window)
        throw CancellationError()
      }
    }
    guard try await developer.evaluate(recordingScript) as? Bool == true else {
      throw InspectorFailure("Page diagnostics are unavailable in this document.")
    }
  }

  func refresh() async {
    guard !busy, active, let inspector, inspector.isOpen, let engine = inspector.engine,
      engine.pages[inspector.target.tabID]?.loading == false
    else { return }
    guard inspector.target.origin != nil else {
      failure = "Page tools require an HTTP or HTTPS page."
      return
    }
    busy = true
    defer { busy = false }
    let generation = inspector.documentGeneration
    let destination = inspector.target
    do {
      try await recording()
      guard active, generation == inspector.documentGeneration, destination == inspector.target
      else { return }
      if epoch != generation {
        epoch = generation
        documentChanged()
      }
      guard
        let snapshot = try await developer.evaluate("globalThis.__shaarBugReportV1.snapshot()")
          as? [String: Any]
      else { throw InspectorFailure("Page diagnostics are unavailable.") }
      if tool == .overview {
        let value = try await developer.evaluate("globalThis.__shaarBugReportV1.tech()") ?? []
        try receiveTechnologies(value, generation: generation)
      }
      if tool == .vitals {
        if !developer.performanceEnabled { developer.setPerformanceEnabled(true) }
        try await developer.refreshPerformance()
        let metrics =
          try await developer.call("Performance.getMetrics")["metrics"] as? [[String: Any]] ?? []
        guard active, generation == inspector.documentGeneration else { return }
        if let task = metrics.first(where: { $0["name"] as? String == "TaskDuration" })?["value"]
          as? Double,
          let clock = metrics.first(where: { $0["name"] as? String == "Timestamp" })?["value"]
            as? Double, task.isFinite, clock.isFinite
        {
          if let previousCPU, clock > previousCPU.1 {
            cpu = min(100, max(0, (task - previousCPU.0) / (clock - previousCPU.1) * 100))
          }
          previousCPU = (task, clock)
        }
      }
      if tool == .storage && Date().timeIntervalSince(storageUpdated) > 10 {
        try await loadStorage()
      }
      guard active, inspector.isOpen, generation == inspector.documentGeneration,
        destination == inspector.target
      else { return }
      try receive(snapshot, generation: generation)
    } catch {
      if active, generation == inspector.documentGeneration, !(error is CancellationError) {
        failure = error.localizedDescription
      }
    }
  }

  /// Accept one bounded page snapshot only while its requesting document remains open.
  func receive(_ snapshot: [String: Any], generation: Int) throws {
    guard active, let inspector, inspector.isOpen, generation == inspector.documentGeneration else {
      throw CancellationError()
    }
    let encoded = try JSONSerialization.data(withJSONObject: snapshot)
    guard encoded.count <= 8_388_608 else {
      throw InspectorFailure("Page diagnostics exceed the supported size.")
    }
    if let time = snapshot["startedAt"] as? Double, time.isFinite,
      (0...253_402_300_799_000).contains(time)
    {
      startedAt = Date(timeIntervalSince1970: time / 1000)
    }
    let rows = snapshot["console"] as? [[String: Any]] ?? []
    let nextConsole: [ConsoleRow] = rows.suffix(300).compactMap { row in
      guard let level = row["level"] as? String, let message = row["message"] as? String,
        let time = row["time"] as? Double, time.isFinite, (0...253_402_300_799_000).contains(time)
      else { return nil }
      return .init(
        level: String(level.prefix(32)), message: String(message.prefix(4096)), time: time)
    }
    let har = BugReportArchive.har(
      snapshot: snapshot, includeSensitiveHeaders: false, version: "diagnostics")
    let entries = (har["log"] as? [String: Any])?["entries"] as? [[String: Any]] ?? []
    let nextRequests: [RequestRow] = entries.suffix(500).enumerated().map { index, entry in
      let request = entry["request"] as? [String: Any] ?? [:]
      let response = entry["response"] as? [String: Any] ?? [:]
      let bytes = entry["_transferSize"] as? Double
      return .init(
        id: index, url: String((request["url"] as? String ?? "").prefix(8192)),
        method: String((request["method"] as? String ?? "UNKNOWN").prefix(32)),
        status: response["status"] as? Int ?? 0,
        duration: (entry["time"] as? Double).flatMap { $0.isFinite && $0 >= 0 ? $0 : nil },
        bytes: bytes.flatMap { $0.isFinite && $0 > 0 ? $0 : nil },
        kind: String((entry["_initiator"] as? String ?? "").prefix(32)))
    }
    console = nextConsole
    requests = nextRequests
    failure = nil
  }

  func receiveTechnologies(_ value: Any, generation: Int) throws {
    guard active, let inspector, inspector.isOpen, generation == inspector.documentGeneration else {
      throw CancellationError()
    }
    let data = try JSONSerialization.data(withJSONObject: value)
    guard data.count < 65_536 else {
      throw InspectorFailure("Page markers exceed the supported size.")
    }
    let rows = try JSONDecoder().decode([StackSignal].self, from: data)
    guard rows.count <= 20,
      rows.allSatisfy({
        !$0.name.isEmpty && $0.name.count <= 160 && ($0.version?.count ?? 0) <= 64
          && $0.source.count <= 512
      })
    else { throw InspectorFailure("Technology markers exceed the supported size.") }
    var names = Set<String>()
    signals = rows.filter { names.insert($0.name).inserted }
  }

  func loadStorage() async throws {
    guard active, let inspector, inspector.isOpen else { throw CancellationError() }
    let generation = inspector.documentGeneration
    let area = storageArea
    if area == "cookies" {
      let result = try await developer.call(
        "Network.getCookies", params: ["urls": [developer.target.url.absoluteString]])
      guard active, area == storageArea, generation == inspector.documentGeneration else {
        throw CancellationError()
      }
      let rows = (result["cookies"] as? [[String: Any]]) ?? []
      storageLimited = rows.count > 200
      cookies = rows.prefix(200).compactMap { row in
        guard let name = row["name"] as? String, name.count <= 4096,
          let value = row["value"] as? String, value.count <= 8192
        else { return nil }
        return Cookie(raw: row)
      }
    } else {
      let value = try await expression("storage", arguments: [storageArea])
      try receiveStorage(value, area: area, generation: generation)
    }
    storageUpdated = Date()
  }

  func receiveStorage(_ value: [String: Any], area: String, generation: Int) throws {
    guard active, let inspector, inspector.isOpen, area == storageArea, area != "cookies",
      generation == inspector.documentGeneration
    else { throw CancellationError() }
    let data = try JSONSerialization.data(withJSONObject: value["items"] ?? [])
    guard data.count < 1_048_576 else {
      throw InspectorFailure("Storage snapshot exceeds its supported size.")
    }
    let rows = try JSONDecoder().decode([StorageRow].self, from: data)
    guard rows.count <= 200,
      rows.allSatisfy({
        $0.key.count <= 4096 && $0.preview.count <= 256 && (0...Int(Int32.max)).contains($0.length)
      })
    else { throw InspectorFailure("Storage entries exceed the supported size.") }
    storage = rows
    storageLimited = value["truncated"] as? Bool == true
  }

  func storageValue(key: String) async throws -> String {
    let result = try await expression("readStorage", arguments: [storageArea, key])
    return result["value"] as? String ?? ""
  }

  func writeStorage(key: String, value: String?) async {
    do {
      _ = try await expression(
        "writeStorage", arguments: [storageArea, key, value as Any? ?? NSNull()])
      try await loadStorage()
      failure = nil
    } catch { failure = error.localizedDescription }
  }

  func writeCookie(_ cookie: Cookie?, name: String, value: String) async {
    guard name.utf8.count <= 4096, value.utf8.count <= 4096, !name.isEmpty else {
      failure = "Cookie name or value exceeds the editor limit."
      return
    }
    do {
      var params: [String: Any] = [
        "name": name, "value": value, "url": developer.target.url.absoluteString,
      ]
      if let cookie {
        guard cookies.contains(where: { $0.id == cookie.id }), cookie.editable else {
          throw InspectorFailure("This cookie cannot be edited in its current partition.")
        }
        params["path"] = cookie.path
        if cookie.domain.hasPrefix(".") { params["domain"] = cookie.domain }
        for key in ["secure", "httpOnly", "sameSite", "partitionKey"] {
          if let value = cookie.raw[key] { params[key] = value }
        }
        if let expires = cookie.raw["expires"] as? Double, expires.isFinite, expires > 0 {
          params["expires"] = expires
        }
      }
      let result = try await developer.call("Network.setCookie", params: params)
      guard result["success"] as? Bool == true else {
        throw InspectorFailure("Chromium rejected this cookie.")
      }
      try await loadStorage()
      failure = nil
    } catch { failure = error.localizedDescription }
  }

  func deleteCookie(_ cookie: Cookie) async {
    guard cookies.contains(where: { $0.id == cookie.id }), cookie.editable else { return }
    do {
      var params: [String: Any] = [
        "name": cookie.name, "domain": cookie.domain, "path": cookie.path,
      ]
      if let key = cookie.raw["partitionKey"] { params["partitionKey"] = key }
      _ = try await developer.call("Network.deleteCookies", params: params)
      try await loadStorage()
      failure = nil
    } catch { failure = error.localizedDescription }
  }

  private func expression(_ method: String, arguments: [Any]) async throws -> [String: Any] {
    guard ["storage", "readStorage", "writeStorage"].contains(method) else {
      throw CancellationError()
    }
    let data = try JSONSerialization.data(withJSONObject: arguments)
    let literal = String(data: data, encoding: .utf8)!
    guard active, inspector?.isOpen == true, let origin = developer.target.origin else {
      throw CancellationError()
    }
    let expectedOrigin = String(
      data: try JSONSerialization.data(withJSONObject: [origin]), encoding: .utf8)!
    let expectedGeneration = inspector?.documentGeneration
    guard
      let value = try await developer.evaluate(
        "(()=>{if(location.origin!==\(expectedOrigin)[0])throw Error('The page changed.');return globalThis.__shaarBugReportV1.\(method)(...\(literal));})()"
      ) as? [String: Any]
    else { throw InspectorFailure("Page storage is unavailable.") }
    guard active, expectedGeneration == inspector?.documentGeneration else {
      throw CancellationError()
    }
    if let error = value["error"] as? String { throw InspectorFailure(String(error.prefix(256))) }
    return value
  }

  isolated deinit { pollTask?.cancel() }
}
