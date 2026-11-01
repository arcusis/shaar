// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import BrowserCore
import ChromiumBridge.Verification
import Foundation
import SwiftUI

@testable import ArcusisBrowser

/// Offscreen developer features on a separate loopback site and disposable profile.
@MainActor
final class DeveloperModeProbe {
  let engine: BrowserEngine
  let store: BrowserStore
  let root: URL
  let fixture: URL
  let phase: String
  private var checks: [String] = []
  private var previewWindow: NSWindow?

  init(engine: BrowserEngine, store: BrowserStore, root: URL, fixture: URL, phase: String) {
    self.engine = engine
    self.store = store
    self.root = root
    self.fixture = fixture
    self.phase = phase
  }

  func run() async throws -> [String] {
    do {
      try await exercise()
      try report(error: nil)
      return checks
    } catch {
      try? report(error: error)
      throw error
    }
  }

  private func exercise() async throws {
    let originalPreferences = store.preferences
    store.usePreferences(
      BrowserPreferencesStore(fileURL: root.appending(path: "developer-preferences.json")))
    defer { store.usePreferences(originalPreferences) }
    let returning = store.session.selectedSpaceID
    let profile = store.session.spaces[0].profileID
    try expect(
      store.createSpace(name: "Developer fixture", sharingProfile: profile, tint: .forest),
      "developer fixture space opens")
    let space = store.session.selectedSpaceID
    var url = URLComponents(url: fixture, resolvingAgainstBaseURL: false)!
    url.host = "developer.localhost"
    url.path = "/developer"
    url.query = nil
    store.perform(.open(url.url!))
    var model: SiteControlsDeveloperModel?
    for _ in 0..<100 {
      if let candidate = engine.selectedDeveloperModel,
        candidate.target.origin?.contains("developer.localhost") == true,
        engine.pages[candidate.target.tabID]?.loading == false,
        (try? await candidate.evaluate("document.documentElement.dataset.developerFixture"))
          as? String == "v1"
      {
        model = candidate
        break
      }
      try await Task.sleep(for: .milliseconds(100))
    }
    guard let model else { throw DeveloperModeFailure("Developer fixture did not load.") }
    try await settled(model)
    if phase == "restart" {
      try expect(model.simulation.reducedMotion, "simulation persists across engine restart")
      try expect(
        try await model.evaluate("matchMedia('(prefers-reduced-motion: reduce)').matches") as? Bool
          == true, "persisted simulation reapplies on navigation")
    }
    model.set(DeveloperSimulation())
    try await settled(model)
    try await simulations(model)
    try await Task.sleep(for: .seconds(36))
    try expect(
      try await model.evaluate("navigator.language") as? String == "fr-FR",
      "session renewal preserves overrides beyond the first lease timeout")
    try await capture(model, feature: "simulations")
    model.set(DeveloperSimulation())
    try await settled(model)
    try expect(
      try await model.evaluate("navigator.language") as? String != "fr-FR",
      "reset restores browser language")
    var remembered = DeveloperSimulation()
    remembered.reducedMotion = phase == "initial"
    model.set(remembered)
    try await settled(model)
    store.perform(.space(returning))
    try expect(store.removeSpace(space), "developer fixture space closes")
  }

  private func simulations(_ model: SiteControlsDeveloperModel) async throws {
    var value = DeveloperSimulation()
    for (device, width) in [(DeveloperSimulation.Device.phone, 390), (.tablet, 820)] {
      value.device = device
      model.set(value)
      try await settled(model)
      try await Task.sleep(for: .milliseconds(300))
      let viewport =
        try await model.evaluate(
          "({width:innerWidth,screen:screen.width,scale:visualViewport.scale})") as? [String: Any]
      try JSONSerialization.data(withJSONObject: viewport ?? [:], options: [.prettyPrinted]).write(
        to: root.appending(path: "\(phase)-viewport-\(device).json"))
      try expect(
        viewport?["width"] as? Int == width,
        "\(device) viewport has expected CSS width")
    }
    value.device = .desktop
    value.darkMode = true
    value.reducedMotion = true
    value.timezone = .newYork
    value.language = .french
    value.location = .sanFrancisco
    model.set(value)
    try await settled(model)
    let page =
      try await model.evaluate(
        "({dark:matchMedia('(prefers-color-scheme: dark)').matches,motion:matchMedia('(prefers-reduced-motion: reduce)').matches,language:navigator.language,zone:Intl.DateTimeFormat().resolvedOptions().timeZone})"
      ) as? [String: Any]
    try expect(
      page?["dark"] as? Bool == true && page?["motion"] as? Bool == true,
      "dark mode and reduced motion affect matchMedia")
    try expect(
      page?["language"] as? String == "fr-FR" && page?["zone"] as? String == "America/New_York",
      "language and timezone affect page APIs")
    try await engine.runtime.setSiteSetting(
      "location", value: "allow", origin: model.target.origin!,
      profileID: model.target.profileID.uuidString)
    try await engine.runtime.grantProbeGeolocation(inTabID: model.target.tabID.uuidString)
    let locationResult =
      try await model.evaluate(
        "new Promise(async resolve=>{const permission=await navigator.permissions.query({name:'geolocation'});navigator.geolocation.getCurrentPosition(p=>resolve({latitude:p.coords.latitude,permission:permission.state}),e=>resolve({error:e.message,code:e.code,permission:permission.state}),{timeout:5000})})"
      ) as? [String: Any]
    try JSONSerialization.data(withJSONObject: locationResult ?? [:], options: [.prettyPrinted])
      .write(to: root.appending(path: "\(phase)-geolocation.json"))
    let latitude = locationResult?["latitude"] as? Double
    try expect(
      latitude.map { abs($0 - 37.7749) < 0.001 } == true,
      "location override reaches geolocation API")
    let benchmark =
      "(()=>{let t=performance.now(),s=0;for(let i=0;i<3000000;i++)s+=Math.sqrt(i);return performance.now()-t+s*0})()"
    _ = try await model.evaluate(benchmark)
    let normal = try await model.evaluate(benchmark) as? Double ?? 0
    for cpu in [DeveloperSimulation.CPU.four, .six] {
      value.cpu = cpu
      model.set(value)
      try await settled(model)
      let slow = try await model.evaluate(benchmark) as? Double ?? 0
      try expect(
        slow > normal * 1.2, "\(cpu.rawValue)× CPU slowdown increases authored loop timing")
    }
    value.network = .slow3G
    model.set(value)
    try await settled(model)
    let elapsed =
      try await model.evaluate(
        "(async()=>{let t=performance.now();await fetch('/developer?slow='+Math.random(),{cache:'no-store'});return performance.now()-t})()"
      ) as? Double ?? 0
    try expect(elapsed >= 250, "slow 3G delays loopback request")
    value.network = .offline
    model.set(value)
    try await settled(model)
    try expect(
      try await model.evaluate(
        "fetch('/developer?offline='+Math.random()).then(()=>false,()=>true)") as? Bool == true,
      "offline makes page request fail")
    let other = UUID()
    try expect(
      !store.preferences.developerSimulation(on: model.target.origin!, for: other).isActive
        && !store.preferences.developerSimulation(
          on: "http://other.localhost", for: model.target.profileID
        ).isActive, "simulations stay isolated by site and profile")
  }

  private func settled(_ model: SiteControlsDeveloperModel) async throws {
    for _ in 0..<300 {
      if !model.applying {
        if let failure = model.failure { throw DeveloperModeFailure(failure) }
        return
      }
      try await Task.sleep(for: .milliseconds(50))
    }
    throw DeveloperModeFailure("Simulation did not settle.")
  }

  private func capture(_ model: SiteControlsDeveloperModel, feature: String) async throws {
    for (name, scheme) in [("light", ColorScheme.light), ("dark", .dark)] {
      let content = SiteControlsDeveloperSection(model: model, expanded: true)
        .frame(width: 340).background(Color(nsColor: .windowBackgroundColor))
        .environment(\.colorScheme, scheme)
      let host = NSHostingView(rootView: content)
      let window = NSWindow(
        contentRect: NSRect(origin: .zero, size: host.fittingSize), styleMask: .borderless,
        backing: .buffered, defer: false)
      window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
      window.contentView = host
      previewWindow = window
      try await Task.sleep(for: .milliseconds(150))
      host.layoutSubtreeIfNeeded()
      guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
        throw DeveloperModeFailure("Developer section could not render.")
      }
      host.cacheDisplay(in: host.bounds, to: bitmap)
      guard let data = bitmap.representation(using: .png, properties: [:]) else {
        throw DeveloperModeFailure("Developer screenshot could not encode.")
      }
      try data.write(to: root.appending(path: "\(phase)-developer-\(feature)-\(name).png"))
    }
    checks.append("developer \(feature) section renders offscreen in light and dark")
  }

  private func expect(_ condition: Bool, _ message: String) throws {
    guard condition else { throw DeveloperModeFailure(message) }
    checks.append(message)
  }

  private func report(error: Error?) throws {
    try JSONSerialization.data(
      withJSONObject: [
        "passed": error == nil, "phase": phase, "checks": checks,
        "error": error?.localizedDescription as Any? ?? NSNull(),
        "scope":
          "Authored loopback developer features in disposable profiles; native UI captures are offscreen.",
      ], options: [.prettyPrinted, .sortedKeys]
    )
    .write(to: root.appending(path: "\(phase)-developer.json"), options: .atomic)
  }
}
