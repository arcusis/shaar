// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import BrowserCore
import ChromiumBridge
import Foundation
import SwiftUI

@testable import ArcusisBrowser

/// Hidden proof that Web Serial and Web Bluetooth return without freezing the main thread,
/// and that USB, Serial, Bluetooth, and HID each present the device chooser.
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
        "The device chooser probe requires Shaar Verification.app. Build it with scripts/bundle-app.sh --with-engine --verification.")
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
        finish(error: "\(transport) did not install the chooser hook.")
        return
      }
      let before = watchdog.maxStall
      let clicked = await click()
      guard clicked else {
        finish(error: "The trusted click on \(transport) did not land.")
        return
      }
      guard let request = await waitForChooser(context.store, transport: transport) else {
        finish(error: "\(transport) did not present a device chooser.")
        return
      }
      let stall = watchdog.maxStall - before
      do {
        let name = "\(transport)-chooser.png"
        try render(request, store: context.store, name: name)
        screenshots.append(name)
      } catch {
        finish(error: "Could not render the \(transport) chooser: \(error)")
        return
      }
      guard windowsHidden else {
        finish(error: "A window became visible during \(transport).")
        return
      }
      guard stall < 1.5 else {
        finish(error: "\(transport) stalled the main thread for \(stall) seconds.")
        return
      }
      context.store.resolveDeviceChooser(request.id, optionIndex: nil)
      context.store.sheetDidDismiss()
      guard await rejected() else {
        finish(error: "\(transport) did not reject with NotFoundError.")
        return
      }
      rows.append([
        "transport": transport, "passed": true, "stallSeconds": stall,
        "bluetoothUnavailable": request.bluetoothUnavailable, "canGrant": request.canGrant,
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
      id: "preview", signalID: "9-90", tabID: tab.id, profileID: profile, pageURL: tab.url,
      transport: .usb,
      options: [
        DeviceChooserOption(index: 0, title: "USB serial adapter", detail: "Example vendor"),
        DeviceChooserOption(index: 1, title: "Keyboard", detail: "Example vendor"),
      ],
      bluetoothUnavailable: false, canGrant: true)
    do {
      try render(preview, store: context.store, name: "usb-populated.png", selection: 0)
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
      let installed = await evaluate("window.__shaarChooserInstalled === true")
      let loading = context.engine.pages[tabID]?.loading == true
      if path?.contains("/\(transport)") == true, installed == "true", !loading {
        _ = await evaluate("window.__shaarChooserResult = null; true")
        return windowsHidden
      }
      try? await Task.sleep(for: .milliseconds(100))
    }
    return false
  }

  private func waitForChooser(_ store: BrowserStore, transport: String) async -> DeviceChooserRequest? {
    for _ in 0..<80 {
      if case .deviceChooser(let request) = store.sheet, request.transport.rawValue == transport {
        return request
      }
      try? await Task.sleep(for: .milliseconds(100))
    }
    return nil
  }

  private func rejected() async -> Bool {
    for _ in 0..<50 {
      if await evaluate("window.__shaarChooserResult && window.__shaarChooserResult.error")?
        .contains("NotFoundError") == true
      {
        return true
      }
      try? await Task.sleep(for: .milliseconds(100))
    }
    return false
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
      runtime.evaluate(inTabID: tabID.uuidString, script: script) { continuation.resume(returning: $0) }
    }
  }

  private func render(
    _ request: DeviceChooserRequest, store: BrowserStore, name: String, selection: Int? = nil
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
    let blocked = ShaarBluetoothIOIsBlocked()
    let hidden = windowsHidden
    let rowsPassed = rows.count == 4 && rows.allSatisfy { $0["passed"] as? Bool == true }
    let chooserStall = rows.compactMap { $0["stallSeconds"] as? TimeInterval }.max() ?? 99
    // Lifetime stall includes engine startup. The chooser window is the hang signal.
    passed = error == nil && rowsPassed && hidden && blocked && chooserStall < 1.5
    let report: [String: Any] = [
      "schemaVersion": 1, "probeMode": "device-choosers", "passed": passed,
      "bluetoothIOBlocked": blocked, "maxStallSeconds": watchdog.maxStall,
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
      lock.unlock()
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
