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
    try await dockedDeveloperTools(model)
    try await capture(model, feature: "simulations")
    model.set(DeveloperSimulation())
    try await settled(model)
    try expect(
      try await model.evaluate("navigator.language") as? String != "fr-FR",
      "reset restores browser language")
    try await performance(model)
    try await bugReport(model)
    try await picker(model)
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
    try await cpuSimulations(model, value: value)
    value.cpu = .six
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

  private func dockedDeveloperTools(_ model: SiteControlsDeveloperModel) async throws {
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
    try await settled(model)
    let retainedAfterClose = try await model.evaluate(retained) as? Bool == true
    try expect(
      runtime.devToolsView(forTabID: identity) == nil && retainedAfterClose,
      "closing built-in DevTools preserves active simulations")
  }

  private func cpuSimulations(
    _ model: SiteControlsDeveloperModel, value: DeveloperSimulation
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

  private func performance(_ model: SiteControlsDeveloperModel) async throws {
    try expect(!model.performanceEnabled, "performance overlay starts disabled")
    model.setPerformanceEnabled(true)
    try await settled(model)
    try await model.refreshPerformance()
    _ = try await model.evaluate("document.getElementById('shift').style.marginTop='180px'; true")
    _ = try await model.evaluate(
      "fetch('/developer-slow?run='+Math.random(),{cache:'no-store'}).then(r=>r.text()).then(()=>true)"
    )
    let clicked: Bool = await withCheckedContinuation { continuation in
      engine.runtime.clickProbeElement(
        inTabID: model.target.tabID.uuidString, elementID: "performance-input"
      ) { continuation.resume(returning: $0) }
    }
    try expect(clicked, "trusted renderer input reaches performance fixture button")
    for _ in 0..<50 {
      try await model.refreshPerformance()
      if let snapshot = model.performanceSnapshot, snapshot.cls ?? 0 > 0, snapshot.inp != nil,
        snapshot.lcp != nil, snapshot.requests >= 2, snapshot.transferredBytes > 0
      {
        break
      }
      try await Task.sleep(for: .milliseconds(100))
    }
    guard let snapshot = model.performanceSnapshot else {
      throw DeveloperModeFailure("Performance samples are missing.")
    }
    try expect(
      snapshot.cls ?? 0 > 0 && snapshot.lcp != nil && snapshot.inp != nil,
      "observer reports forced layout shift, LCP and trusted interaction latency")
    try expect(
      snapshot.heapBytes ?? 0 > 0 && snapshot.requests >= 2 && snapshot.transferredBytes > 0,
      "protocol heap and observed slow resource appear in live samples")
    try await capturePerformance(snapshot)
    let origin = snapshot.timeOrigin
    let generation = model.documentGeneration
    store.reloadCurrentPage()
    for _ in 0..<100 {
      if model.documentGeneration > generation && engine.pages[model.target.tabID]?.loading == false
      {
        break
      }
      try await Task.sleep(for: .milliseconds(100))
    }
    try expect(
      model.documentGeneration > generation, "navigation starts a new performance generation")
    try await settled(model)
    try await model.refreshPerformance()
    try expect(
      model.performanceSnapshot?.timeOrigin != origin && model.performanceSnapshot?.cls == 0
        && model.performanceSnapshot?.inp == nil, "navigation resets layout shifts and interactions"
    )
    model.setPerformanceEnabled(false)
    try await settled(model)
    try expect(model.performanceSnapshot == nil, "disabling overlay clears native samples")
    try expect(
      ShortcutCatalog.shortcut(for: .performanceOverlay)?.key == "p",
      "performance overlay shortcut is registered")
  }

  private func capturePerformance(_ snapshot: PagePerformanceSnapshot) async throws {
    for (name, scheme) in [("light", ColorScheme.light), ("dark", .dark)] {
      let content = PerformanceOverlayPanel(snapshot: snapshot, close: {})
        .frame(width: 268).padding(16).background(Color(nsColor: .windowBackgroundColor))
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
        throw DeveloperModeFailure("Performance overlay could not render.")
      }
      host.cacheDisplay(in: host.bounds, to: bitmap)
      guard let data = bitmap.representation(using: .png, properties: [:]) else {
        throw DeveloperModeFailure("Performance screenshot could not encode.")
      }
      try data.write(to: root.appending(path: "\(phase)-developer-performance-\(name).png"))
    }
    checks.append("performance overlay renders offscreen in light and dark")
  }

  private func bugReport(_ model: SiteControlsDeveloperModel) async throws {
    _ = try await model.evaluate(
      "console.error('shaar-report-fixture-error');fetch('/developer-slow?report='+Math.random(),{headers:{Authorization:'Bearer fixture-report-secret'}}).then(r=>r.text()).then(()=>true)"
    )
    _ = try await model.evaluate(
      "new Promise((resolve,reject)=>{const request=new XMLHttpRequest();request.open('GET','/developer-slow?xhr='+Math.random());request.setRequestHeader('Authorization','Bearer fixture-xhr-secret');request.onload=()=>resolve(true);request.onerror=()=>reject(Error('XHR fixture failed'));request.send();})"
    )
    try await Task.sleep(for: .milliseconds(200))
    try expect(
      !model.includeSensitiveHeaders, "bug report defaults to sensitive HAR header redaction")
    guard let file = await model.createBugReport() else {
      throw DeveloperModeFailure(model.reportFailure ?? "Bug report export failed.")
    }
    let members = try readZip(file, member: nil)
    for name in ["screenshot.png", "metadata.json", "console.json", "network.har", "README.txt"] {
      try expect(
        String(decoding: members, as: UTF8.self).contains(name),
        "bug report archive includes \(name)")
    }
    let png = try readZip(file, member: "screenshot.png")
    try expect(
      png.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]),
      "report screenshot contains a real page PNG")
    let console = String(decoding: try readZip(file, member: "console.json"), as: UTF8.self)
    let har = String(decoding: try readZip(file, member: "network.har"), as: UTF8.self)
    try expect(
      console.contains("shaar-report-fixture-error"),
      "document-start collector preserves console errors")
    try expect(
      har.contains("developer-slow") && har.lowercased().contains("authorization")
        && har.contains("[redacted]")
        && !har.contains("fixture-report-secret") && !har.contains("fixture-xhr-secret"),
      "default HAR contains requests with authorization value redacted")
    let metadata =
      try JSONSerialization.jsonObject(with: readZip(file, member: "metadata.json"))
      as? [String: Any]
    try expect(
      metadata?["engineVersion"] as? String == engine.runtime.chromiumVersion
        && metadata?["viewport"] != nil && metadata?["activeSimulations"] != nil,
      "report includes versions, viewport and simulation metadata")
    try expect(
      engine.downloads.libraryItems(in: model.target.profileID).contains {
        $0.fileURL?.resolvingSymlinksInPath() == file.resolvingSymlinksInPath()
      }, "saved ZIP appears in Library Downloads")
    try expect(
      store.libraryDrawerSection == .downloads,
      "successful export opens the Library Downloads section")
    store.closeLibraryDrawer()
    try await captureReport(model)
    model.includeSensitiveHeaders = true
    guard let included = await model.createBugReport() else {
      throw DeveloperModeFailure(model.reportFailure ?? "Opted-in export failed.")
    }
    let sensitive = String(decoding: try readZip(included, member: "network.har"), as: UTF8.self)
    try expect(
      sensitive.contains("Bearer fixture-report-secret")
        && sensitive.contains("Bearer fixture-xhr-secret"),
      "explicit opt-in retains exposed authorization value")
    store.closeLibraryDrawer()
    model.includeSensitiveHeaders = false
  }

  private func readZip(_ file: URL, member: String?) throws -> Data {
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

  private func captureReport(_ model: SiteControlsDeveloperModel) async throws {
    for (name, scheme) in [("light", ColorScheme.light), ("dark", .dark)] {
      let content = DeveloperBugReportSection(model: model)
        .frame(width: 320).padding(16).background(Color(nsColor: .windowBackgroundColor))
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
        throw DeveloperModeFailure("Bug report section could not render.")
      }
      host.cacheDisplay(in: host.bounds, to: bitmap)
      guard let data = bitmap.representation(using: .png, properties: [:]) else {
        throw DeveloperModeFailure("Bug report screenshot could not encode.")
      }
      try data.write(to: root.appending(path: "\(phase)-developer-bug-report-\(name).png"))
    }
    checks.append("bug report section renders offscreen in light and dark")
  }

  private func picker(_ model: SiteControlsDeveloperModel) async throws {
    for (path, identity, frames, framework) in [
      ("/developer-react", "react-target", [String](), "React"),
      ("/developer-vue", "vue-target", [], "Vue"),
      ("/developer-plain", "plain-target", [], ""),
      ("/developer-frame", "frame-target", ["picker-frame", "picker-frame"], ""),
    ] {
      let generation = model.documentGeneration
      var url = URLComponents(url: model.target.url, resolvingAgainstBaseURL: false)!
      url.path = path
      url.query = nil
      try expect(engine.navigateCurrentPage(to: url.url!), "picker fixture navigates to \(path)")
      for _ in 0..<100 {
        if model.documentGeneration > generation
          && engine.pages[model.target.tabID]?.loading == false
        {
          break
        }
        try await Task.sleep(for: .milliseconds(100))
      }
      try await settled(model)
      let arguments = String(
        decoding: try JSONSerialization.data(withJSONObject: [identity, frames]), as: UTF8.self)
      var targetReady = false
      for _ in 0..<100 {
        targetReady =
          (try? await model.evaluate(
            "(()=>{const [id,frames]=\(arguments);let doc=document;for(const frame of frames){doc=doc.getElementById(frame)?.contentDocument;if(!doc)return false;}return !!doc.getElementById(id);})()"
          )) as? Bool == true
        if targetReady { break }
        try await Task.sleep(for: .milliseconds(100))
      }
      try expect(targetReady, "picker target is ready inside its owning document")
      await model.startPicker()
      if let failure = model.pickerFailure { throw DeveloperModeFailure(failure) }
      let clicked: Bool = await withCheckedContinuation { continuation in
        engine.runtime.clickProbeElement(
          inTabID: model.target.tabID.uuidString, elementID: identity, frameIDs: frames
        ) { continuation.resume(returning: $0) }
      }
      try expect(clicked, "trusted renderer input picks \(identity)")
      for _ in 0..<50 {
        try await model.refreshPicker()
        if model.pickedElement != nil { break }
        try await Task.sleep(for: .milliseconds(50))
      }
      guard let element = model.pickedElement else {
        throw DeveloperModeFailure("Picker selection did not arrive for \(identity).")
      }
      let resolved =
        try await model.evaluate(
          "(()=>{const p=__shaarPickerV1.snapshot().selection;let doc=document;for(const f of p.frames)doc=doc.querySelector(f).contentDocument;const css=doc.querySelectorAll(p.css),x=doc.evaluate(p.xpath,doc,null,XPathResult.ORDERED_NODE_SNAPSHOT_TYPE,null);return {css:css.length,xpath:x.snapshotLength,id:css[0]?.id,same:x.snapshotItem(0)===css[0],clicked:doc.defaultView.fixtureClicked===true};})()"
        ) as? [String: Any]
      try expect(
        resolved?["css"] as? Int == 1 && resolved?["xpath"] as? Int == 1
          && resolved?["same"] as? Bool == true && resolved?["id"] as? String == identity,
        "CSS and XPath uniquely resolve to \(identity)")
      try expect(
        resolved?["clicked"] as? Bool == false, "picker selection does not activate page button")
      try expect(element.frames.count == frames.count, "picker preserves same-origin frame context")
      if !framework.isEmpty {
        try expect(
          element.framework == framework && element.component == framework + "Demo"
            && element.source?.contains("/fixture/") == true,
          "picker reads exposed \(framework) component name and source")
      }
      if framework == "React" { try await capturePicker(model, element: element) }
      _ = try await model.evaluate(
        "(()=>{let win=window;for(const f of __shaarPickerV1.snapshot().selection.frames)win=win.document.querySelector(f).contentWindow;win.dispatchEvent(new win.KeyboardEvent('keydown',{key:'Escape',bubbles:true}));return true;})()"
      )
      try await model.refreshPicker()
      try expect(
        !model.pickerEnabled && model.pickedElement == nil,
        "Escape exits picker including same-origin frame")
    }
    try expect(
      ShortcutCatalog.shortcut(for: .elementPicker)?.modifiers == [.command, .option],
      "element picker shortcut is registered")
  }

  private func capturePicker(_ model: SiteControlsDeveloperModel, element: PickedElement)
    async throws
  {
    for (name, scheme) in [("light", ColorScheme.light), ("dark", .dark)] {
      let content = ElementPickerPanel(element: element, copy: { _ in }, close: {})
        .frame(width: 360).padding(16).background(Color(nsColor: .windowBackgroundColor))
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
        throw DeveloperModeFailure("Element picker panel could not render.")
      }
      host.cacheDisplay(in: host.bounds, to: bitmap)
      guard let data = bitmap.representation(using: .png, properties: [:]) else {
        throw DeveloperModeFailure("Element picker screenshot could not encode.")
      }
      try data.write(to: root.appending(path: "\(phase)-developer-picker-\(name).png"))
    }
    let page = try await model.call(
      "Page.captureScreenshot", params: ["format": "png", "captureBeyondViewport": false])
    if let encoded = page["data"] as? String, let png = Data(base64Encoded: encoded) {
      try png.write(to: root.appending(path: "\(phase)-developer-picker-page.png"))
    }
    checks.append(
      "picker copy panel renders offscreen in light and dark with exposed component metadata")
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
