import AppKit
import BrowserCore
import ChromiumBridge
import SwiftUI

/// Exercises Chromium's real download manager with authored, authenticated loopback responses.
@MainActor
final class DownloadProbe {
  let runtime: ARCChromiumRuntime
  let engine: BrowserEngine
  let store: BrowserStore
  let root: URL
  let phase: String
  private var checks: [String] = []
  private var previewWindow: NSWindow?

  init(
    runtime: ARCChromiumRuntime, engine: BrowserEngine, store: BrowserStore, root: URL,
    phase: String
  ) {
    self.runtime = runtime
    self.engine = engine
    self.store = store
    self.root = root
    self.phase = phase
  }

  func run() async throws -> [String] {
    do {
      let result = try await exercise()
      try report(error: nil)
      return result
    } catch {
      for profile in store.session.profiles {
        for item in engine.downloads.items(in: profile.id) where item.state == .downloading {
          let _: Error? = await withCheckedContinuation { continuation in
            runtime.downloadCommand("cancel", downloadID: item.id, profileID: profile.id.uuidString)
            {
              continuation.resume(returning: $0)
            }
          }
        }
      }
      try? report(error: error)
      throw error
    }
  }

  private func exercise() async throws -> [String] {
    let a = store.session.spaces[0]
    let b = store.session.spaces[1]
    let tabA = a.selectedTabID!
    let tabB = b.selectedTabID!
    if phase == "restart" {
      let saved = try String(
        contentsOf: root.appending(path: "initial-download-id"), encoding: .utf8)
      let restored = try await wait(
        a.profileID, "completed download history restores in its original profile"
      ) {
        $0.id == saved && $0.state == .finished
      }
      try verifyBytes(restored, account: "alpha", large: true)
      try expect(
        !engine.downloads.items(in: b.profileID).contains { $0.id == saved },
        "profile B does not inherit A's download history")
    }
    store.perform(.space(a.id))
    let priorA = Set(engine.downloads.items(in: a.profileID).map(\.id))
    try await begin(tabA, name: "slow.txt")
    let active = try await wait(a.profileID, "profile A receives a live authenticated download") {
      !priorA.contains($0.id) && $0.state == .downloading && $0.receivedBytes > 0
    }
    try expect(!active.dangerous, "authored text download does not bypass a safety warning")
    try expect(
      engine.downloads.perform(
        .pause, id: active.id, profileID: a.profileID,
        selectedProfileID: store.session.selectedSpace.profileID),
      "native pause targets A's download")
    _ = try await wait(a.profileID, "engine confirms paused transfer") {
      $0.id == active.id && $0.paused
    }
    try await Task.sleep(for: .milliseconds(300))
    let pausedBytes = engine.downloads.records[a.profileID]?[active.id]?.receivedBytes
    try await Task.sleep(for: .milliseconds(400))
    try expect(
      engine.downloads.records[a.profileID]?[active.id]?.receivedBytes == pausedBytes,
      "paused download stops receiving bytes")
    store.showDownloads()
    try await capture(profile: a.profileID, name: "\(phase)-downloads.png")
    store.sheet = nil
    store.sheetDidDismiss()
    try expect(
      engine.downloads.perform(
        .resume, id: active.id, profileID: a.profileID,
        selectedProfileID: a.profileID), "native resume targets the same download")
    _ = try await wait(a.profileID, "engine confirms resumed transfer") {
      $0.id == active.id && !$0.paused
    }
    store.perform(.space(b.id))
    try expect(
      !engine.downloads.perform(
        .cancel, id: active.id, profileID: a.profileID,
        selectedProfileID: b.profileID), "stale controls cannot cancel another profile's transfer")
    let wrongProfile: Error? = await withCheckedContinuation { continuation in
      runtime.downloadCommand("cancel", downloadID: active.id, profileID: b.profileID.uuidString) {
        continuation.resume(returning: $0)
      }
    }
    try expect(wrongProfile != nil, "engine service refuses a GUID from a different profile")
    let priorB = Set(engine.downloads.items(in: b.profileID).map(\.id))
    try await begin(tabB, name: "profile.txt")
    let beta = try await wait(b.profileID, "profile B completes its own authenticated download") {
      !priorB.contains($0.id) && $0.state == .finished
    }
    try verifyBytes(beta, account: "beta", large: false)
    let complete = try await wait(a.profileID, "A's transfer finishes while B remains selected") {
      $0.id == active.id && $0.state == .finished
    }
    try expect(
      store.session.selectedSpace.profileID == b.profileID,
      "background completion does not switch the user's profile")
    try verifyBytes(complete, account: "alpha", large: true)
    try expect(
      engine.downloads.fileToOpen(
        id: complete.id, profileID: a.profileID,
        selectedProfileID: b.profileID) == nil, "file actions reject the wrong selected profile")
    try expect(
      engine.downloads.perform(
        .remove, id: beta.id, profileID: b.profileID,
        selectedProfileID: b.profileID), "remove-from-list targets only B's completed record")
    for _ in 0..<50 {
      if engine.downloads.records[b.profileID]?[beta.id] == nil { break }
      try await Task.sleep(for: .milliseconds(100))
    }
    try expect(
      engine.downloads.records[b.profileID]?[beta.id] == nil, "engine removal event clears B's list"
    )
    try verifyBytes(beta, account: "beta", large: false)
    store.perform(.space(a.id))
    let beforeCancel = Set(engine.downloads.items(in: a.profileID).map(\.id))
    try await begin(tabA, name: "cancel.txt")
    let cancellable = try await wait(
      a.profileID, "another live transfer is available for cancellation"
    ) {
      !beforeCancel.contains($0.id) && $0.state == .downloading && $0.receivedBytes > 0
    }
    try expect(
      engine.downloads.perform(
        .cancel, id: cancellable.id, profileID: a.profileID,
        selectedProfileID: a.profileID), "native cancel targets the selected profile's transfer")
    _ = try await wait(a.profileID, "engine confirms cancellation") {
      $0.id == cancellable.id && $0.state == .cancelled
    }
    try expect(
      engine.downloads.items(in: a.profileID).allSatisfy { $0.state != .downloading },
      "probe leaves no active transfers before shutdown")
    try expect(
      engine.notice == nil, "user-driven downloads do not bypass unsupported website permissions")
    if phase == "initial" {
      try complete.id.write(
        to: root.appending(path: "initial-download-id"), atomically: true, encoding: .utf8)
    }
    return checks
  }

  private func begin(_ tab: UUID, name: String) async throws {
    let literal = String(data: try JSONEncoder().encode("/download/\(name)"), encoding: .utf8)!
    let result: String? = await withCheckedContinuation { continuation in
      runtime.evaluate(
        inTabID: tab.uuidString,
        script: """
          (()=>{if(document.documentElement.dataset.arcusisFixture!=='v1')return false;
          document.getElementById('arcusis-download-probe')?.remove();
          const link=document.createElement('a');link.href=\(literal);link.id='arcusis-download-probe';
          link.textContent='Download fixture';link.style.cssText='position:fixed;top:4px;left:4px;padding:12px;background:white;z-index:99';
          document.body.append(link);return true;})()
          """
      ) { continuation.resume(returning: $0) }
    }
    guard result == "true" else { throw DownloadProbeFailure("Could not start authored download.") }
    let clicked: Bool = await withCheckedContinuation { continuation in
      runtime.clickProbeElement(inTabID: tab.uuidString, elementID: "arcusis-download-probe") {
        continuation.resume(returning: $0)
      }
    }
    guard clicked else { throw DownloadProbeFailure("Could not click the authored download link.") }
  }

  private func wait(_ profile: UUID, _ message: String, predicate: (BrowserDownload) -> Bool)
    async throws -> BrowserDownload
  {
    for _ in 0..<180 {
      if let item = engine.downloads.items(in: profile).first(where: predicate) {
        checks.append(message)
        return item
      }
      runtime.refreshDownloads(forProfileID: profile.uuidString)
      try await Task.sleep(for: .milliseconds(100))
    }
    throw DownloadProbeFailure(message)
  }

  private func verifyBytes(_ item: BrowserDownload, account: String, large: Bool) throws {
    let destination = root.appending(path: "Downloads").standardizedFileURL
      .resolvingSymlinksInPath()
    guard let path = item.fileURL?.standardizedFileURL.resolvingSymlinksInPath(),
      path.path.hasPrefix(destination.path + "/")
    else { throw DownloadProbeFailure("Download escaped its disposable destination.") }
    let expected =
      Data("account=\(account)\narcusis-download-fixture\n".utf8)
      + Data(repeating: 120, count: large ? 4 * 1024 * 1024 : 1024)
    try expect(
      try Data(contentsOf: path) == expected,
      "downloaded bytes match \(account)'s authenticated response in the temporary destination")
  }

  private func capture(profile: UUID, name: String) async throws {
    let host = NSHostingView(
      rootView: DownloadsPanel(store: store, engine: engine, profileID: profile))
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 560, height: 440),
      styleMask: .borderless, backing: .buffered, defer: false)
    window.contentView = host
    previewWindow = window
    try await Task.sleep(for: .milliseconds(100))
    host.layoutSubtreeIfNeeded()
    guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
      throw DownloadProbeFailure("Native downloads layout could not be rendered.")
    }
    host.cacheDisplay(in: host.bounds, to: bitmap)
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
      throw DownloadProbeFailure("Native downloads layout could not be encoded.")
    }
    try png.write(to: root.appending(path: name), options: .atomic)
  }

  private func expect(_ condition: Bool, _ message: String) throws {
    guard condition else { throw DownloadProbeFailure(message) }
    checks.append(message)
  }

  private func report(error: Error?) throws {
    try JSONSerialization.data(
      withJSONObject: [
        "passed": error == nil, "phase": phase, "checks": checks,
        "error": error?.localizedDescription as Any? ?? NSNull(),
        "engineNotice": engine.notice as Any? ?? NSNull(),
        "scope":
          "Real engine downloads from authored loopback fixtures into a marked temporary directory. No files opened, Finder launched, or native dialog shown.",
      ],
      options: [.prettyPrinted, .sortedKeys]
    ).write(to: root.appending(path: "\(phase)-downloads.json"), options: .atomic)
  }
}

private struct DownloadProbeFailure: LocalizedError {
  let message: String
  init(_ message: String) { self.message = message }
  var errorDescription: String? { message }
}
