// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import BrowserCore
import ChromiumBridge
import ChromiumBridgeVerification
import CoreFoundation
import Darwin
import Foundation
import SwiftUI

@testable import ArcusisBrowser

enum DeviceChooserProbePolicy {
  static func missingChooserError(transport: String) -> String? {
    transport == "usb" ? "The WebUSB request settled without a native device chooser." : nil
  }
}

/// Hidden proof that Web Serial, Web Bluetooth, Web USB, and Web HID call the real navigator
/// APIs and return without freezing the main thread. A sheet appears only when the engine
/// sends a device-chooser permission event. Serial, Bluetooth, and USB reject with
/// NotFoundError when Chromium closes the chooser. Web HID resolves with an empty list.
@MainActor
final class DeviceChooserProbe {
  private let runtime: ARCShaarRuntime
  private let host: NativeBrowserHost
  private let output: URL
  private let baseURL: URL
  private let tabID: UUID
  private let watchdog = MainThreadStallWatch()
  private var finished = false
  private var passed = false
  private var rows: [[String: Any]] = []
  private var screenshots: [String] = []
  private var pageSettlements: [String: PageSettlement] = [:]

  private init(arguments: [String]) throws {
    func value(after flag: String) throws -> String {
      guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1)
      else { throw Failure("Missing \(flag).") }
      return arguments[index + 1]
    }
    let framework = URL(filePath: try value(after: "--probe-framework"))
    guard let executable = Bundle.main.executableURL,
      ShaarFirstTabProbe.isBundledFramework(framework, for: executable)
    else {
      throw Failure(
        "The device chooser probe requires Shaar Verification.app. Build it with scripts/bundle-app.sh --with-engine --verification."
      )
    }
    output = URL(filePath: try value(after: "--probe-output"))
    let dataRoot = URL(filePath: try value(after: "--probe-data-dir"), directoryHint: .isDirectory)
    guard let page = URL(string: try value(after: "--probe-base-url")),
      page.scheme == "http", page.host == "127.0.0.1"
    else { throw Failure("The device chooser probe requires an authored loopback base URL.") }
    baseURL = page
    let selected = try NativeBrowserHost.makeRuntime(frameworkURL: framework)
    guard let selected = selected as? ARCShaarRuntime else {
      throw Failure("The backend selector did not construct the Shaar runtime.")
    }
    runtime = selected
    let workspace = try BrowserWorkspaceStore(
      file: WorkspaceFile(
        url: dataRoot.appending(path: "workspace.json"),
        legacySessionURL: dataRoot.appending(path: "session.json")))
    guard let window = workspace.workspace.windows.first,
      let store = workspace.stores[window.id]
    else { throw Failure("The fresh workspace has no browser window.") }
    store.perform(.open(page.appending(path: "serial")))
    guard let id = store.session.selectedSpace.selectedTabID else {
      throw Failure("The fresh workspace did not create its first tab.")
    }
    tabID = id
    host = NativeBrowserHost(
      events: BrowserRuntimeEvents(runtime: runtime), workspace: workspace,
      presentation: .hiddenProbe)
  }

  static func run(arguments: [String]) -> Int32 {
    let probe: DeviceChooserProbe
    do {
      probe = try DeviceChooserProbe(arguments: arguments)
    } catch {
      FileHandle.standardError.write(Data("Device chooser probe: \(error)\n".utf8))
      return 1
    }
    return probe.run()
  }

  private func run() -> Int32 {
    let dataRoot = output.deletingLastPathComponent()
    runtime.onReady = { [weak self] in
      guard let self else { return }
      NSApp.setActivationPolicy(.prohibited)
      do {
        try self.host.restore()
      } catch {
        self.finish(error: "Browser host restore failed: \(error)")
        return
      }
      self.watchdog.start()
      Task { @MainActor in await self.exercise() }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 90) { [weak self] in
      self?.finish(error: "Timed out waiting for the device choosers.")
    }
    let code = runtime.run(
      withDataDirectory: dataRoot.appending(path: "Chromium"), testing: true)
    host.detach()
    return passed && code == 0 ? 0 : 1
  }

  private func exercise() async {
    let transports = ["serial", "bluetooth", "usb", "hid"]
    for (index, transport) in transports.enumerated() {
      if index > 0 {
        guard let context = host.contexts.values.first,
          context.engine.navigateCurrentPage(to: baseURL.appending(path: transport))
        else {
          finish(error: "Could not open \(transport).")
          return
        }
      }
      guard let context = host.contexts.values.first else {
        finish(error: "The hidden browser window is missing.")
        return
      }
      guard await ready(context, transport: transport) else {
        finish(error: "\(transport) did not finish loading.")
        return
      }
      let before = watchdog.maxStall
      watchdog.beginChooser { [output] seconds in
        let report: [String: Any] = [
          "schemaVersion": 1, "probeMode": "device-choosers", "passed": false,
          "maxStallSeconds": seconds, "chooserStallSeconds": seconds,
          "allWindowsHidden": true, "rows": [], "screenshots": [],
          "error": "The main thread stalled for \(seconds) seconds inside a device chooser.",
        ]
        if let data = try? JSONSerialization.data(
          withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        {
          try? data.write(to: output, options: .atomic)
        }
        Darwin._exit(1)
      }
      let clicked = await click()
      guard clicked else {
        watchdog.endChooser()
        finish(error: "The trusted click on \(transport) did not land.")
        return
      }
      Task { @MainActor [weak self] in
        guard let self else { return }
        if let result = await self.evaluateChooserCall(transport) {
          self.pageSettlements[transport] = result
        }
      }
      let (engineSheet, pageSettlement) = await outcome(context.store, transport: transport)
      watchdog.endChooser()
      let stall = watchdog.maxStall - before
      guard windowsHidden else {
        finish(error: "A window became visible during \(transport).")
        return
      }
      guard stall < 1.5 else {
        finish(error: "\(transport) stalled the main thread for \(stall) seconds.")
        return
      }
      if engineSheet == nil,
        let error = DeviceChooserProbePolicy.missingChooserError(
          transport: transport)
      {
        finish(error: error)
        return
      }
      let unavailable: Bool
      let canGrant: Bool
      let settled: PageSettlement?
      if let engineSheet {
        unavailable = engineSheet.bluetoothUnavailable
        canGrant = engineSheet.canGrant
        do {
          let name = "\(transport)-chooser.png"
          try render(engineSheet, store: context.store, name: name)
          screenshots.append(name)
        } catch {
          finish(error: "Could not render the \(transport) chooser: \(error)")
          return
        }
        context.store.resolveDeviceChooser(engineSheet.id, optionID: nil)
        context.store.sheetDidDismiss()
        settled = await waitForSettlement(transport)
        guard settled?.isChooserDismissal(for: transport) == true else {
          finish(error: mismatch(transport, settled))
          return
        }
      } else {
        settled = pageSettlement
        guard pageSettlement?.isChooserDismissal(for: transport) == true else {
          finish(error: mismatch(transport, pageSettlement))
          return
        }
        guard let tab = context.store.session.selectedSpace.selectedTab,
          let profile = context.store.session.profileID(forTabID: tab.id),
          let kind = DeviceChooserTransport(rawValue: transport)
        else {
          finish(error: "The page disappeared before the \(transport) chooser preview.")
          return
        }
        unavailable = false
        canGrant = false
        let preview = DeviceChooserRequest(
          id: "shot-\(transport)", tabID: tab.id, profileID: profile, pageURL: tab.url,
          origin: tab.url, transport: kind, options: [], bluetoothUnavailable: unavailable,
          canGrant: false)
        do {
          let name = "\(transport)-chooser.png"
          try render(preview, store: context.store, name: name)
          screenshots.append(name)
        } catch {
          finish(error: "Could not render the \(transport) chooser: \(error)")
          return
        }
      }
      rows.append([
        "transport": transport, "passed": true, "stallSeconds": stall,
        "engineSheet": engineSheet != nil,
        "canGrant": canGrant, "pageResult": settled?.summary ?? "",
      ])
    }
    guard let context = host.contexts.values.first,
      let tab = context.store.session.selectedSpace.selectedTab,
      let profile = context.store.session.profileID(forTabID: tab.id)
    else {
      finish(error: "The page disappeared before the populated chooser preview.")
      return
    }
    let preview = DeviceChooserRequest(
      id: "preview", tabID: tab.id, profileID: profile, pageURL: tab.url, origin: tab.url,
      transport: .usb,
      options: [
        DeviceChooserOption(
          optionID: "preview-a", title: "USB serial adapter", detail: "Example vendor"),
        DeviceChooserOption(
          optionID: "preview-b", title: "Keyboard", detail: "Example vendor"),
      ],
      bluetoothUnavailable: false, canGrant: true)
    do {
      try render(
        preview, store: context.store, name: "usb-populated.png", selection: "preview-a")
      screenshots.append("usb-populated.png")
    } catch {
      finish(error: "Could not render the populated chooser: \(error)")
      return
    }
    finish(error: nil)
  }

  private func ready(_ context: NativeBrowserContext, transport: String) async -> Bool {
    for _ in 0..<120 {
      let path = await evaluate("location.pathname")
      let loading = context.engine.pages[tabID]?.loading == true
      if path?.contains("/\(transport)") == true, !loading {
        return windowsHidden
      }
      try? await Task.sleep(for: .milliseconds(100))
    }
    return false
  }

  private func outcome(
    _ store: BrowserStore, transport: String
  ) async -> (DeviceChooserRequest?, PageSettlement?) {
    for _ in 0..<80 {
      if case .deviceChooser(let request) = store.sheet, request.transport.rawValue == transport {
        return (request, nil)
      }
      if let found = pageSettlements[transport] { return (nil, found) }
      try? await Task.sleep(for: .milliseconds(100))
    }
    return (nil, nil)
  }

  private func waitForSettlement(_ transport: String) async -> PageSettlement? {
    for _ in 0..<50 {
      if let found = pageSettlements[transport] { return found }
      try? await Task.sleep(for: .milliseconds(100))
    }
    return nil
  }

  private func evaluateChooserCall(_ transport: String) async -> PageSettlement? {
    let calls = [
      "serial": "navigator.serial.requestPort()",
      "bluetooth": "navigator.bluetooth.requestDevice({acceptAllDevices:true})",
      "usb": "navigator.usb.requestDevice({filters:[]})",
      "hid": "navigator.hid.requestDevice({filters:[]})",
    ]
    guard let call = calls[transport] else { return nil }
    let expression = """
      (async () => {
        if (!navigator.userActivation.isActive) {
          return {error: "NotAllowedError", message: "The trusted chooser click did not activate the page."};
        }
        try {
          const value = await \(call);
          let count = 0;
          if (Array.isArray(value)) count = value.length;
          else if (value != null) count = 1;
          return {ok: true, count};
        } catch (error) {
          return {error: error && error.name ? error.name : "Error",
                  message: String(error && error.message || error)};
        }
      })()
      """
    return await withCheckedContinuation { continuation in
      runtime.evaluateDeviceChooserProbe(inTabID: tabID.uuidString, expression: expression) {
        raw in
        continuation.resume(returning: raw.flatMap(PageSettlement.init(raw:)))
      }
    }
  }

  private func mismatch(_ transport: String, _ seen: PageSettlement?) -> String {
    let actual = seen?.summary ?? "pending"
    if transport == "hid" {
      return
        "hid settled as \(actual). Chromium resolves requestDevice with an empty list when no device is selected."
    }
    return
      "\(transport) settled as \(actual). Chromium rejects this call with NotFoundError when no device is selected."
  }

  private func click() async -> Bool {
    await withCheckedContinuation { continuation in
      runtime.submitTrustedProbeClick(inTabID: tabID.uuidString, elementID: "parity-action") {
        continuation.resume(returning: $0)
      }
    }
  }

  private func evaluate(_ script: String) async -> String? {
    await withCheckedContinuation { continuation in
      runtime.evaluate(inTabID: tabID.uuidString, script: script) {
        continuation.resume(returning: $0)
      }
    }
  }

  private func render(
    _ request: DeviceChooserRequest, store: BrowserStore, name: String, selection: String? = nil
  ) throws {
    let size = NSSize(width: 440, height: 460)
    let host = NSHostingView(
      rootView: DeviceChooserConsent(store: store, request: request, initialSelection: selection)
        .frame(width: size.width, height: size.height))
    host.frame = NSRect(origin: .zero, size: size)
    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered,
      defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    defer { window.close() }
    guard !window.isVisible, let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)
    else { throw Failure("The chooser image was empty.") }
    host.cacheDisplay(in: host.bounds, to: bitmap)
    guard let png = bitmap.representation(using: .png, properties: [:]), png.count > 1000 else {
      throw Failure("The chooser image was empty.")
    }
    try png.write(to: output.deletingLastPathComponent().appending(path: name), options: .atomic)
  }

  private var windowsHidden: Bool {
    NSApp.windows.allSatisfy { !$0.isVisible }
  }

  private func finish(error: String?) {
    guard !finished else { return }
    finished = true
    watchdog.stop()
    let hidden = windowsHidden
    let rowsPassed = rows.count == 4 && rows.allSatisfy { $0["passed"] as? Bool == true }
    let chooserStall = rows.compactMap { $0["stallSeconds"] as? TimeInterval }.max() ?? 99
    // Lifetime stall includes engine startup. The chooser window is the hang signal.
    passed = error == nil && rowsPassed && hidden && chooserStall < 1.5
    let report: [String: Any] = [
      "schemaVersion": 1, "probeMode": "device-choosers", "passed": passed,
      "maxStallSeconds": watchdog.maxStall,
      "chooserStallSeconds": chooserStall, "allWindowsHidden": hidden,
      "rows": rows, "screenshots": screenshots, "error": error ?? "",
    ]
    do {
      let data = try JSONSerialization.data(
        withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
      try data.write(to: output, options: .atomic)
    } catch {
      passed = false
      FileHandle.standardError.write(Data("Device chooser report failed: \(error)\n".utf8))
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
      guard let self else { return }
      for context in self.host.contexts.values {
        _ = self.runtime.closeWindowID(context.nativeID)
      }
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
        self?.runtime.quit()
      }
    }
  }

  struct PageSettlement {
    var errorName: String? = nil
    var message: String? = nil
    var resolvedCount: Int? = nil
    var raw: String

    init?(raw: String) {
      guard let data = raw.data(using: .utf8),
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
      else { return nil }
      self.raw = raw
      if let error = object["error"] as? String, !error.isEmpty {
        errorName = error
        message = object["message"] as? String
      } else if let ok = object["ok"] as? NSNumber,
        CFGetTypeID(ok) == CFBooleanGetTypeID(), ok.boolValue,
        let countValue = object["count"] as? NSNumber,
        CFGetTypeID(countValue) != CFBooleanGetTypeID(),
        let count = object["count"] as? Int
      {
        resolvedCount = count
      }
    }

    var summary: String {
      if let errorName {
        let detail = message.map { ": \($0)" } ?? ""
        return "\(errorName)\(detail)"
      }
      if let resolvedCount {
        return "resolved \(resolvedCount)"
      }
      return raw
    }

    func isChooserDismissal(for transport: String) -> Bool {
      transport == "hid" ? resolvedCount == 0 : errorName == "NotFoundError"
    }
  }

  private struct Failure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
  }
}

private final class MainThreadStallWatch: @unchecked Sendable {
  private let lock = NSLock()
  private var ticket = 0
  private var acked = 0
  private var sentAt = Date()
  private var stall: TimeInterval = 0
  private var timer: DispatchSourceTimer?
  private var chooserArmed = false
  private var chooserFired = false
  private var onChooserStall: ((TimeInterval) -> Void)?

  func beginChooser(_ handler: @escaping (TimeInterval) -> Void) {
    lock.lock()
    chooserArmed = true
    chooserFired = false
    onChooserStall = handler
    lock.unlock()
  }

  func endChooser() {
    lock.lock()
    chooserArmed = false
    onChooserStall = nil
    lock.unlock()
  }

  func start() {
    let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .userInitiated))
    timer.schedule(deadline: .now() + .milliseconds(100), repeating: .milliseconds(100))
    timer.setEventHandler { [weak self] in self?.pulse() }
    timer.resume()
    self.timer = timer
  }

  func stop() {
    timer?.cancel()
    timer = nil
  }

  var maxStall: TimeInterval {
    lock.lock()
    defer { lock.unlock() }
    return stall
  }

  private func pulse() {
    let now = Date()
    lock.lock()
    if ticket != acked {
      let age = now.timeIntervalSince(sentAt)
      if age > stall { stall = age }
      let armed = chooserArmed
      let fired = chooserFired
      let handler = onChooserStall
      if armed && !fired && age >= 1.5 {
        chooserFired = true
      }
      lock.unlock()
      if armed && !fired && age >= 1.5 {
        handler?(age)
      }
      return
    }
    ticket += 1
    let mine = ticket
    sentAt = now
    lock.unlock()
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.lock.lock()
      if mine >= self.acked { self.acked = mine }
      self.lock.unlock()
    }
  }
}
