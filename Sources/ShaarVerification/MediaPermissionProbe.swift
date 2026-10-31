// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import BrowserCore
import ChromiumBridge.Verification
import Foundation
import SwiftUI

@testable import ArcusisBrowser

/// Uses only Chromium fake devices and its simulated system-media permission backend.
@MainActor
final class MediaPermissionProbe {
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
      try writeReport(error: nil)
      return result
    } catch {
      try? writeReport(error: error)
      throw error
    }
  }

  private func exercise() async throws -> [String] {
    let a = store.session.spaces[0]
    let b = store.session.spaces[1]
    let tabA = a.selectedTabID!
    let tabB = b.selectedTabID!
    store.perform(.space(a.id))
    try await start(tabA)
    var kinds: Set<WebsitePermissionKind> = []
    var capturedConsent = false
    var result: [String: Any] = [:]
    for _ in 0..<100 {
      if let request = store.websitePermissionRequests.first {
        try expect(
          request.profileID == a.profileID && request.tabID == tabA,
          "media request is bound to profile A and its selected tab")
        kinds.formUnion(request.kinds)
        if !capturedConsent {
          try await capture(
            WebsitePermissionConsent(store: store, request: request),
            size: NSSize(width: 496, height: 360), name: "\(phase)-media-consent.png")
          capturedConsent = true
        }
        store.resolveWebsitePermission(request.id, accepted: true)
        store.sheetDidDismiss()
      }
      result = await state(tabA) ?? [:]
      if result["allowed"] as? Bool == true { break }
      if result["error"] != nil { throw MediaProbeFailure("Fake media was denied: \(result)") }
      try await Task.sleep(for: .milliseconds(100))
    }
    try expect(
      kinds == Set([.camera, .microphone]), "camera and microphone both pass through native consent"
    )
    try expect(
      result["audio"] as? Int == 1 && result["video"] as? Int == 1,
      "allowing this visit creates fake audio and video tracks")
    try await waitForCapture(tabA, active: true)
    try expect(
      engine.mediaAccess[tabA]?.camera == true && engine.mediaAccess[tabA]?.microphone == true,
      "native capture state reports active camera and microphone")

    store.perform(.space(b.id))
    try await start(tabB)
    let denied = try await waitForRequest(tabB)
    try expect(
      denied.profileID == b.profileID, "profile B asks independently after profile A was allowed")
    store.resolveWebsitePermission(denied.id, accepted: false)
    store.sheetDidDismiss()
    let denial = try await waitForResult(tabB)
    try expect(
      denial["error"] as? String == "NotAllowedError",
      "denying B leaves its fake devices unavailable")
    try expect(engine.mediaAccess[tabB]?.isCapturing != true, "denying B does not begin capture")
    try expect(
      engine.mediaAccess[tabA]?.isCapturing == true, "switching spaces retains A's active call")

    // Keep the stale-request scenario separate from repeated denials. Chromium
    // intentionally quiets repeatedly dismissed permission prompts.
    if let space = store.session.spaces.first(where: { $0.name == "Media consent probe" }) {
      store.perform(.space(space.id))
    } else {
      guard store.createSpace(name: "Media consent probe", sharingProfile: nil, tint: .forest)
      else {
        throw MediaProbeFailure("Could not create an isolated stale-consent context.")
      }
      store.perform(.open(a.selectedTab!.url))
    }
    let staleSpace = store.session.selectedSpace
    let staleTab = staleSpace.selectedTabID!
    try expect(
      staleSpace.profileID != a.profileID && staleSpace.profileID != b.profileID,
      "stale-consent scenario uses a third independent profile")
    try await waitForFixture(staleTab)
    try await start(staleTab)
    let stale = try await waitForRequest(staleTab)
    store.perform(.space(a.id))
    store.resolveWebsitePermission(stale.id, accepted: true)
    store.sheetDidDismiss()
    let canceled = try await waitForResult(staleTab)
    try expect(
      canceled["error"] as? String == "NotAllowedError",
      "switching profile cancels the pending media grant")
    try expect(
      !store.websitePermissionRequests.contains { $0.id == stale.id },
      "late approval cannot revive stale media consent")

    try await capture(
      BrowserWindow(store: store), size: NSSize(width: 1200, height: 780),
      name: "\(phase)-media-active.png")
    _ = await evaluate(
      tabA, "(()=>{window.arcusisProbeStream?.getTracks().forEach(t=>t.stop());return {};})()")
    try await waitForCapture(tabA, active: false)
    try expect(
      engine.mediaAccess[tabA]?.isCapturing != true,
      "stopping fake tracks clears the capture indicator")
    return checks
  }

  private func start(_ tab: UUID) async throws {
    let started = await evaluate(
      tab,
      """
      (()=>{window.arcusisMediaResult=null;
        navigator.mediaDevices.getUserMedia({audio:true,video:true}).then(stream=>{
          window.arcusisProbeStream=stream;window.arcusisMediaResult={allowed:true,
            audio:stream.getAudioTracks().length,video:stream.getVideoTracks().length};
        }).catch(error=>window.arcusisMediaResult={error:error.name});return {started:true};})()
      """, userGesture: true)
    guard started?["started"] as? Bool == true else {
      throw MediaProbeFailure("Could not request fake media.")
    }
  }

  private func evaluate(_ tab: UUID, _ expression: String, userGesture: Bool = false) async
    -> [String: Any]?
  {
    let json: String? = await withCheckedContinuation { continuation in
      if userGesture {
        runtime.evaluateProbeUserGesture(inTabID: tab.uuidString, script: expression) {
          continuation.resume(returning: $0)
        }
      } else {
        runtime.evaluate(inTabID: tab.uuidString, script: expression) {
          continuation.resume(returning: $0)
        }
      }
    }
    guard let data = json?.data(using: .utf8) else { return nil }
    return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
  }

  private func state(_ tab: UUID) async -> [String: Any]? {
    await evaluate(tab, "window.arcusisMediaResult")
  }

  private func waitForRequest(_ tab: UUID) async throws -> WebsitePermissionRequest {
    for _ in 0..<80 {
      if let request = store.websitePermissionRequests.first(where: { $0.tabID == tab }) {
        return request
      }
      if let response = await state(tab), response["error"] != nil || response["allowed"] != nil {
        throw MediaProbeFailure("Media resolved without native consent: \(response)")
      }
      try await Task.sleep(for: .milliseconds(100))
    }
    throw MediaProbeFailure("Native media request did not arrive.")
  }

  private func waitForFixture(_ tab: UUID) async throws {
    for _ in 0..<80 {
      if await evaluate(tab, "({ready:document.documentElement.dataset.arcusisFixture==='v1'})")?[
        "ready"] as? Bool == true
      {
        return
      }
      try await Task.sleep(for: .milliseconds(100))
    }
    throw MediaProbeFailure("The isolated media fixture did not load.")
  }

  private func waitForResult(_ tab: UUID) async throws -> [String: Any] {
    for _ in 0..<80 {
      if let response = await state(tab) { return response }
      try await Task.sleep(for: .milliseconds(100))
    }
    throw MediaProbeFailure("Fake media request did not resolve.")
  }

  private func waitForCapture(_ tab: UUID, active: Bool) async throws {
    for _ in 0..<80 {
      if (engine.mediaAccess[tab]?.isCapturing == true) == active { return }
      try await Task.sleep(for: .milliseconds(100))
    }
    throw MediaProbeFailure("Capture indicator did not reach expected state \(active).")
  }

  private func capture<V: View>(_ view: V, size: NSSize, name: String) async throws {
    let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: size),
      styleMask: .borderless, backing: .buffered, defer: false)
    window.contentView = host
    previewWindow = window
    try await Task.sleep(for: .milliseconds(100))
    host.layoutSubtreeIfNeeded()
    guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
      throw MediaProbeFailure("Could not render native media UI.")
    }
    host.cacheDisplay(in: host.bounds, to: bitmap)
    guard let png = bitmap.representation(using: .png, properties: [.compressionFactor: 1]) else {
      throw MediaProbeFailure("Could not encode native media UI.")
    }
    try png.write(to: root.appending(path: name), options: .atomic)
  }

  private func expect(_ condition: Bool, _ message: String) throws {
    guard condition else { throw MediaProbeFailure(message) }
    checks.append(message)
  }

  private func writeReport(error: Error?) throws {
    let report: [String: Any] = [
      "passed": error == nil, "phase": phase, "checks": checks,
      "error": error?.localizedDescription as Any? ?? NSNull(),
      "scope":
        "Chromium fake camera/microphone and simulated system permission only. No physical hardware or real macOS permission changes.",
    ]
    try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
      .write(to: root.appending(path: "\(phase)-media.json"), options: .atomic)
  }
}

private struct MediaProbeFailure: LocalizedError {
  let message: String
  init(_ message: String) { self.message = message }
  var errorDescription: String? { message }
}
