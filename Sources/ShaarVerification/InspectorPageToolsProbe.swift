// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import BrowserCore
import ChromiumBridge.Verification
import Foundation
import SwiftUI

@testable import ArcusisBrowser

/// Native page tools on a disposable loopback site, with real protocol/renderer effects.
@MainActor final class InspectorPageToolsProbe {
  let engine: BrowserEngine
  let store: BrowserStore
  let root: URL
  let fixture: URL
  let phase: String
  private var checks: [String] = []
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
      try report(nil)
      return checks
    } catch {
      try? report(error)
      throw error
    }
  }
  private func exercise() async throws {
    let originalPreferences = store.preferences
    store.usePreferences(
      BrowserPreferencesStore(fileURL: root.appending(path: "page-tools-preferences.json")))
    defer { store.usePreferences(originalPreferences) }
    let returning = store.session.selectedSpaceID
    try expect(
      store.createSpace(
        name: "Page tools fixture", sharingProfile: store.session.spaces[0].profileID,
        tint: .forest), "page tools fixture space opens")
    let space = store.session.selectedSpaceID
    var address = URLComponents(url: fixture, resolvingAgainstBaseURL: false)!
    address.host = "inspector.localhost"
    address.path = "/inspector-tools"
    address.query = nil
    store.perform(.open(address.url!))
    try await wait("page tools fixture loads") {
      guard let target = self.engine.siteControlTarget, target.host == "inspector.localhost",
        self.engine.pages[target.tabID]?.loading == false
      else { return false }
      return self.engine.runtime.view(forTabID: target.tabID.uuidString)?.superview != nil
    }
    guard let target = engine.siteControlTarget else {
      throw InspectorFailure("Page tools target missing.")
    }
    let keyWindow = NSApp.keyWindow
    engine.toggleInspector(for: target)
    guard let inspector = engine.inspectors[target.tabID] else {
      throw InspectorFailure("Inspector missing.")
    }
    try await wait("element Inspector installs before page mode") {
      try await inspector.evaluate("!!globalThis.__shaarInspectorV2") as? Bool == true
    }
    inspector.setPanelMode(.page)
    guard let tools = inspector.pageTools else { throw InspectorFailure("Page tools missing.") }
    let model = tools.developer
    try await wait("page diagnostics install only after Page mode opens") {
      await tools.refresh()
      return tools.startedAt != nil
    }
    try await settled(model)
    if phase == "restart" {
      try expect(model.simulation.reducedMotion, "site simulation persists across engine restart")
    }
    model.set(DeveloperSimulation())
    try await settled(model)
    let baselineLanguage = try await model.evaluate("navigator.language") as? String
    try await performance(inspector, tools: tools)
    try await storage(tools)
    try await bugReport(model)
    for tool in [InspectorPageToolsModel.Tool.network, .console, .storage, .report] {
      tools.tool = tool
      await tools.refresh()
      try await capture(
        inspector, feature: tool.rawValue.lowercased().replacingOccurrences(of: " ", with: "-"))
    }
    try await simulations(model)
    var normalNetwork = model.simulation
    normalNetwork.network = .normal
    model.set(normalNetwork)
    try await settled(model)
    // Each bounded lease expires after 35 seconds. Two waits keep this fixture responsive.
    try await Task.sleep(for: .seconds(18))
    try await Task.sleep(for: .seconds(18))
    try expect(
      try await model.evaluate("navigator.language") as? String == "fr-FR",
      "developer lease renews beyond its first timeout")
    try await dockedDeveloperTools(model)
    tools.tool = .simulations
    try await capture(inspector, feature: "simulations")
    model.set(DeveloperSimulation())
    try await settled(model)
    try expect(
      try await model.evaluate("navigator.language") as? String == baselineLanguage,
      "one-click reset restores browser language")
    let collector = try await model.evaluate("globalThis.__shaarBugReportV1.owner") as? String
    inspector.close()
    try await wait("closing Inspector stops collectors and performance") {
      try await model.evaluate("!globalThis.__shaarBugReportV1 && !globalThis.__shaarPerformanceV1")
        as? Bool == true
    }
    try expect(
      !tools.active && !model.performanceEnabled && collector != nil,
      "closed page tools retain no active recording")
    let generation = model.documentGeneration
    store.reloadCurrentPage()
    try await wait("reload after close reaches a new document") {
      model.documentGeneration > generation && self.engine.pages[target.tabID]?.loading == false
    }
    try expect(
      try await model.evaluate("!globalThis.__shaarBugReportV1") as? Bool == true,
      "close removes the document-start bootstrap")
    var remembered = DeveloperSimulation()
    remembered.reducedMotion = phase == "initial"
    model.set(remembered)
    try await settled(model)
    try expect(
      NSApp.keyWindow === keyWindow
        && engine.runtime.window(forID: engine.windowID)?.isVisible == false,
      "page tools never order a window or steal desktop focus")
    store.perform(.space(returning))
    try expect(store.removeSpace(space), "page tools fixture tabs close")
    try await wait("closing tab retires developer model") {
      self.engine.developerModels[target.tabID] == nil
    }
  }

  private func simulations(_ model: DeveloperPageModel) async throws {
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
    try await cpuSimulations(model, value: value)
    value.cpu = .six
    value.network = .slow3G
    model.set(value)
    try await settled(model)
    let elapsed =
      try await model.evaluate(
        "(async()=>{let t=performance.now();await fetch('/inspector-tools?slow='+Math.random(),{cache:'no-store'});return performance.now()-t})()"
      ) as? Double ?? 0
    try expect(elapsed >= 250, "slow 3G delays loopback request")
    value.network = .offline
    model.set(value)
    try await settled(model)
    try expect(
      try await model.evaluate(
        "fetch('/inspector-tools?offline='+Math.random()).then(()=>false,()=>true)") as? Bool
        == true,
      "offline makes page request fail")
    let other = UUID()
    try expect(
      !store.preferences.developerSimulation(on: model.target.origin!, for: other).isActive
        && !store.preferences.developerSimulation(
          on: "http://other.localhost", for: model.target.profileID
        ).isActive, "simulations stay isolated by site and profile")
  }

  private func dockedDeveloperTools(_ model: DeveloperPageModel) async throws {
    let identity = model.target.tabID.uuidString
    let runtime = engine.runtime
    try expect(
      engine.showDeveloperTools(for: model.target),
      "built-in DevTools opens while simulations are active")
    for _ in 0..<100 {
      if let tools = runtime.devToolsView(forTabID: identity),
        tools.superview === runtime.view(forTabID: identity), tools.frame.height > 0
      {
        break
      }
      try await Task.sleep(for: .milliseconds(100))
    }
    try expect(
      runtime.devToolsView(forTabID: identity)?.superview === runtime.view(forTabID: identity)
        && runtime.devToolsView(forTabID: identity) != nil,
      "built-in DevTools stays docked beside the simulated page")
    try await settled(model)
    let retained =
      "navigator.language==='fr-FR' && matchMedia('(prefers-reduced-motion: reduce)').matches"
    for _ in 0..<100 {
      if try await model.evaluate(retained) as? Bool == true { break }
      try await Task.sleep(for: .milliseconds(100))
    }
    let state = try await model.evaluate(
      "({language:navigator.language,motion:matchMedia('(prefers-reduced-motion: reduce)').matches,dark:matchMedia('(prefers-color-scheme: dark)').matches,zone:Intl.DateTimeFormat().resolvedOptions().timeZone})"
    )
    try JSONSerialization.data(
      withJSONObject: state ?? [:], options: [.prettyPrinted, .sortedKeys]
    )
    .write(to: root.appending(path: "\(phase)-docked-simulation.json"), options: .atomic)
    try expect(
      try await model.evaluate(retained) as? Bool == true,
      "simulation protocol remains usable with docked DevTools open")
    try await Task.sleep(for: .seconds(1))
    try expect(
      try await model.evaluate(retained) as? Bool == true,
      "active simulations survive built-in DevTools initialization")
    try expect(
      runtime.window(forID: engine.windowID)?.isVisible == false,
      "coexisting developer tools keep the probe window offscreen")
    try expect(runtime.closeDevTools(forTabID: identity), "built-in DevTools closes independently")
    for _ in 0..<100 {
      if runtime.devToolsView(forTabID: identity) == nil { break }
      try await Task.sleep(for: .milliseconds(100))
    }
    try await wait("closing DevTools reapplies active media overrides") {
      try await model.evaluate(retained) as? Bool == true
    }
    try await settled(model)
    let retainedAfterClose = try await model.evaluate(retained) as? Bool == true
    try expect(
      runtime.devToolsView(forTabID: identity) == nil && retainedAfterClose,
      "closing built-in DevTools preserves active simulations")
  }

  private func cpuSimulations(
    _ model: DeveloperPageModel, value: DeveloperSimulation
  ) async throws {
    // Reuse a warmed function and observable checksum so JIT tier changes cannot dominate
    // a single short sample. Bracket each slowdown with unthrottled fixed-work samples.
    _ = try await model.evaluate(
      """
      (()=>{globalThis.__shaarCPUProbe=count=>{
        const start=performance.now();let checksum=0;
        for(let i=0;i<count;i++)checksum+=Math.sqrt(i);
        return {elapsed:performance.now()-start,checksum};
      };for(let i=0;i<10;i++)__shaarCPUProbe(3000000);return true})()
      """)
    func measure(_ count: Int) async throws -> [Double] {
      guard
        let rows = try await model.evaluate(
          "Array.from({length:5},()=>__shaarCPUProbe(\(count)))") as? [[String: Double]],
        rows.count == 5,
        rows.allSatisfy({
          ($0["elapsed"] ?? 0).isFinite && ($0["elapsed"] ?? 0) > 0
            && ($0["checksum"] ?? 0).isFinite && ($0["checksum"] ?? 0) > 0
        })
      else { throw DeveloperModeFailure("CPU benchmark samples are invalid.") }
      return rows.map { $0["elapsed"]! }
    }
    func median(_ samples: [Double]) -> Double { samples.sorted()[samples.count / 2] }
    var count = 3_000_000
    while median(try await measure(count)) < 40 && count < 96_000_000 { count *= 2 }
    var samples: [String: [Double]] = [:]
    for (label, cpu) in [
      ("normalBefore", DeveloperSimulation.CPU.normal), ("four", .four),
      ("normalBetween", .normal), ("six", .six), ("normalAfter", .normal),
    ] {
      var simulation = value
      simulation.cpu = cpu
      model.set(simulation)
      try await settled(model)
      samples[label] = try await measure(count)
      try JSONSerialization.data(
        withJSONObject: ["iterations": count, "milliseconds": samples],
        options: [.prettyPrinted, .sortedKeys]
      ).write(to: root.appending(path: "\(phase)-cpu-timings.json"), options: .atomic)
    }
    _ = try await model.evaluate("delete globalThis.__shaarCPUProbe")
    for (label, cpu, before, after) in [
      ("four", 4, "normalBefore", "normalBetween"),
      ("six", 6, "normalBetween", "normalAfter"),
    ] {
      let normal = median(samples[before]! + samples[after]!)
      try expect(
        median(samples[label]!) > normal * 1.2,
        "\(cpu)× CPU slowdown increases authored loop timing")
    }
  }

  private func bugReport(_ model: DeveloperPageModel) async throws {
    _ = try await model.evaluate(
      "console.error('shaar-report-fixture-error');fetch('/inspector-slow?report='+Math.random(),{headers:{Authorization:'Bearer fixture-report-secret'}}).then(r=>r.text()).then(()=>true)"
    )
    _ = try await model.evaluate(
      "new Promise((resolve,reject)=>{const request=new XMLHttpRequest();request.open('GET','/inspector-slow?xhr='+Math.random());request.setRequestHeader('Authorization','Bearer fixture-xhr-secret');request.onload=()=>resolve(true);request.onerror=()=>reject(Error('XHR fixture failed'));request.send();})"
    )
    try await Task.sleep(for: .milliseconds(200))
    try expect(
      !model.includeSensitiveHeaders, "bug report defaults to sensitive HAR header redaction")
    guard let file = await model.createBugReport() else {
      throw DeveloperModeFailure(model.reportFailure ?? "Bug report export failed.")
    }
    let members = try Self.readZip(file, member: nil)
    for name in ["screenshot.png", "metadata.json", "console.json", "network.har", "README.txt"] {
      try expect(
        String(decoding: members, as: UTF8.self).contains(name),
        "bug report archive includes \(name)")
    }
    let png = try Self.readZip(file, member: "screenshot.png")
    try expect(
      png.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]),
      "report screenshot contains a real page PNG")
    let console = String(decoding: try Self.readZip(file, member: "console.json"), as: UTF8.self)
    let har = String(decoding: try Self.readZip(file, member: "network.har"), as: UTF8.self)
    try expect(
      console.contains("shaar-report-fixture-error"),
      "active page collector preserves console errors")
    try expect(
      har.contains("inspector-slow") && har.lowercased().contains("authorization")
        && har.contains("[redacted]")
        && !har.contains("fixture-report-secret") && !har.contains("fixture-xhr-secret"),
      "default HAR contains requests with authorization value redacted")
    let metadata = try Self.reportMetadata(file)
    try expect(
      metadata["engineVersion"] as? String == engine.runtime.chromiumVersion
        && metadata["viewport"] != nil && metadata["activeSimulations"] != nil,
      "report includes versions, viewport and simulation metadata")
    try expect(
      engine.downloads.libraryItems(in: model.target.profileID).contains {
        $0.fileURL?.resolvingSymlinksInPath() == file.resolvingSymlinksInPath()
      }, "saved ZIP appears in Library Downloads")
    try expect(
      store.libraryDrawerSection == .downloads,
      "successful export opens the Library Downloads section")
    store.closeLibraryDrawer()
    model.includeSensitiveHeaders = true
    guard let included = await model.createBugReport() else {
      throw DeveloperModeFailure(model.reportFailure ?? "Opted-in export failed.")
    }
    let sensitive = String(
      decoding: try Self.readZip(included, member: "network.har"), as: UTF8.self)
    try expect(
      sensitive.contains("Bearer fixture-report-secret")
        && sensitive.contains("Bearer fixture-xhr-secret"),
      "explicit opt-in retains exposed authorization value")
    store.closeLibraryDrawer()
    model.includeSensitiveHeaders = false
  }

  static func reportMetadata(_ file: URL) throws -> [String: Any] {
    let data = try readZip(file, member: "metadata.json")
    guard let metadata = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let version = metadata["engineVersion"] as? String, !version.isEmpty,
      let viewport = metadata["viewport"] as? [String: Any],
      metadata["activeSimulations"] is [String: Any],
      metadata["sensitiveHeadersIncluded"] is Bool
    else {
      throw DeveloperModeFailure("Bug report metadata is incomplete.")
    }
    for key in ["width", "height", "devicePixelRatio"] {
      guard let value = viewport[key] as? Double, value.isFinite, value > 0 else {
        throw DeveloperModeFailure("Bug report viewport is invalid.")
      }
    }
    return metadata
  }

  static func readZip(_ file: URL, member: String?) throws -> Data {
    let process = Process()
    process.executableURL = URL(filePath: "/usr/bin/unzip")
    process.arguments = member.map { ["-p", file.path, $0] } ?? ["-Z", "-1", file.path]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      throw DeveloperModeFailure("Bug report ZIP member could not be read.")
    }
    return data
  }

  private func settled(_ model: DeveloperPageModel) async throws {
    for _ in 0..<300 {
      if !model.applying {
        if let failure = model.failure { throw DeveloperModeFailure(failure) }
        return
      }
      try await Task.sleep(for: .milliseconds(50))
    }
    throw DeveloperModeFailure("Simulation did not settle.")
  }

  private func performance(_ inspector: InspectorModel, tools: InspectorPageToolsModel) async throws
  {
    tools.tool = .vitals
    let model = tools.developer
    await tools.refresh()
    try await settled(model)
    try await model.refreshPerformance()
    // A shift after the recent-input exclusion interval, followed by real renderer input.
    try await Task.sleep(for: .milliseconds(650))
    _ = try await model.evaluate("document.getElementById('shift').style.marginTop='180px'; true")
    _ = try await model.evaluate(
      "fetch('/inspector-slow?metrics='+Math.random(),{cache:'no-store'}).then(r=>r.text()).then(()=>true)"
    )
    let clicked: Bool = await withCheckedContinuation { continuation in
      engine.runtime.inspectorProbePointer(
        inTabID: model.target.tabID.uuidString, selector: "#performance-input", frames: [],
        click: true, modifiers: 0
      ) { continuation.resume(returning: $0) }
    }
    try expect(clicked, "trusted page input works while element picking is suspended")
    try expect(
      try await model.evaluate("window.clicked") as? Int == 1,
      "Page mode does not intercept the page button")
    try await wait("live LCP, CLS, INP, heap and transfer values arrive") {
      await tools.refresh()
      guard let snapshot = model.performanceSnapshot else { return false }
      return snapshot.lcp != nil && snapshot.inp != nil && (snapshot.cls ?? 0) > 0
        && (snapshot.heapBytes ?? 0) > 0 && snapshot.requests >= 2 && snapshot.transferredBytes > 0
        && tools.cpu != nil
    }
    try await capture(inspector, feature: "vitals")
    let origin = model.performanceSnapshot?.timeOrigin
    let generation = model.documentGeneration
    store.reloadCurrentPage()
    try await wait("navigation resets page diagnostics") {
      model.documentGeneration > generation
        && self.engine.pages[model.target.tabID]?.loading == false
    }
    try await wait("document-start collector records the next navigation") {
      await tools.refresh()
      return tools.console.contains { $0.message.contains("page-tools-document-start") }
    }
    try await wait("new navigation gets fresh performance observers") {
      await tools.refresh()
      return model.performanceSnapshot?.timeOrigin != nil
        && model.performanceSnapshot?.timeOrigin != origin
    }
    try expect(
      model.performanceSnapshot?.cls == 0 && model.performanceSnapshot?.inp == nil,
      "navigation clears old shifts and interactions")
  }

  private func storage(_ tools: InspectorPageToolsModel) async throws {
    tools.tool = .storage
    tools.storageArea = "local"
    try await tools.loadStorage()
    try expect(
      tools.storage.contains { $0.key == "inspector-key" && $0.preview == "original" },
      "local storage lists current-origin values")
    await tools.writeStorage(key: "inspector-key", value: "edited")
    try expect(
      try await tools.storageValue(key: "inspector-key") == "edited",
      "local storage editor saves full values")
    await tools.writeStorage(key: "temporary", value: "remove")
    await tools.writeStorage(key: "temporary", value: nil)
    try expect(
      !tools.storage.contains { $0.key == "temporary" }, "local storage editor deletes entries")
    tools.storageArea = "session"
    try await tools.loadStorage()
    await tools.writeStorage(key: "session-key", value: "session-edited")
    try expect(
      try await tools.storageValue(key: "session-key") == "session-edited",
      "session storage editor saves to the selected document")
    tools.storageArea = "cookies"
    try await tools.loadStorage()
    guard let original = tools.cookies.first(where: { $0.name == "inspector-http-only" }) else {
      throw InspectorFailure("HttpOnly fixture cookie missing.")
    }
    try expect(
      original.raw["httpOnly"] as? Bool == true,
      "cookie inspector reads HttpOnly values through Chromium")
    await tools.writeCookie(original, name: original.name, value: "cookie-edited")
    try expect(
      tools.cookies.contains {
        $0.name == original.name && $0.value == "cookie-edited"
          && $0.raw["httpOnly"] as? Bool == true && $0.path == original.path
      }, "cookie editor preserves HttpOnly, domain and path")
    await tools.writeCookie(nil, name: "inspector-new-cookie", value: "created")
    guard let created = tools.cookies.first(where: { $0.name == "inspector-new-cookie" }) else {
      throw InspectorFailure(tools.failure ?? "New cookie missing.")
    }
    await tools.deleteCookie(created)
    try expect(
      !tools.cookies.contains { $0.name == created.name }, "cookie editor deletes the exact cookie")
  }

  private func capture(_ inspector: InspectorModel, feature: String) async throws {
    for (name, scheme) in [("light", ColorScheme.light), ("dark", .dark)] {
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 320, height: 960), styleMask: [], backing: .buffered,
        defer: false)
      window.isReleasedWhenClosed = false
      window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
      let host = NSHostingView(
        rootView: InspectorPanel(model: inspector).frame(width: 320, height: 960).environment(
          \.colorScheme, scheme))
      window.contentView = host
      host.layoutSubtreeIfNeeded()
      try await Task.sleep(for: .milliseconds(100))
      guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
        throw InspectorFailure("Page tools could not render.")
      }
      host.cacheDisplay(in: host.bounds, to: bitmap)
      guard let png = bitmap.representation(using: .png, properties: [:]) else {
        throw InspectorFailure("Page tools PNG missing.")
      }
      try png.write(to: root.appending(path: "\(phase)-page-tools-\(feature)-\(name).png"))
      try expect(!window.isVisible, "page tools \(feature) capture stays offscreen")
      window.contentView = nil
      window.close()
    }
  }
  private func expect(_ condition: Bool, _ message: String) throws {
    guard condition else { throw InspectorFailure(message) }
    checks.append(message)
  }
  private func wait(_ message: String, _ condition: () async throws -> Bool) async throws {
    for _ in 0..<Int(150 * ProbeTimeout.scale) {
      if try await condition() {
        checks.append(message)
        return
      }
      try await Task.sleep(for: .milliseconds(100))
    }
    throw InspectorFailure("Timed out: \(message)")
  }
  private func report(_ error: Error?) throws {
    try InspectorProbe.reportData(checks: checks, error: error).write(
      to: root.appending(path: "\(phase)-page-tools-report.json"))
  }
}
