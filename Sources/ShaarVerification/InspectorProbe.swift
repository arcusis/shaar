// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import BrowserCore
import ChromiumBridge.Verification
import Foundation
import SwiftUI

@testable import ArcusisBrowser

/// Real renderer input and native Inspector captures in disposable, offscreen windows.
@MainActor
final class InspectorProbe {
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
    let returning = store.session.selectedSpaceID
    try expect(
      store.createSpace(
        name: "Inspector fixture", sharingProfile: store.session.selectedSpace.profileID,
        tint: .ocean), "Inspector fixture space opens")
    let space = store.session.selectedSpaceID
    var address = URLComponents(url: fixture, resolvingAgainstBaseURL: false)!
    address.host = "inspector.localhost"
    address.path = "/inspector"
    address.query = nil
    store.perform(.open(address.url!))
    try await loaded(host: "inspector.localhost")
    let target = try require(engine.siteControlTarget, "Inspector fixture has an owned page")
    let identity = target.tabID.uuidString
    let oldFrame = engine.runtime.view(forTabID: identity)?.frame
    let keyWindow = NSApp.keyWindow
    engine.toggleInspector(for: target)
    let model = try require(engine.inspectors[target.tabID], "Inspector model exists")
    try await wait("Inspector page script installs") {
      try await model.evaluate("!!globalThis.__shaarInspectorV2") as? Bool == true
    }
    try await wait("native dock gives Inspector its own layout space") {
      self.engine.runtime.window(forID: self.engine.windowID)?.contentView?.layoutSubtreeIfNeeded()
      guard let before = oldFrame, let after = self.engine.runtime.view(forTabID: identity)?.frame
      else { return false }
      return after.width > 0 && after.height > 0
        && (after.width < before.width || after.height < before.height)
    }
    try expect(
      await pointer(model, selector: "#save", click: false),
      "trusted pointer hovers the authored element")
    try await wait("hover previews the deepest element") { model.selection?.tag == "span" }
    try expect(model.mode == .picking, "hover leaves selection unlocked")
    let overlay =
      try await model.evaluate("globalThis.__shaarInspectorV2.overlay()") as? [String: Any]
    try expect(
      overlay?["painted"] as? Bool == true && (overlay?["colors"] as? [String])?.count == 4,
      "hover paints margin, border, padding, and content shading")
    try expect(
      (overlay?["badge"] as? String)?.contains("×") == true,
      "hover badge contains tag and dimensions")
    try expect(
      await pointer(model, selector: "#save", click: true),
      "trusted click locks the hovered element")
    try await wait("click locks selection") { model.mode == .locked }
    try expect(
      try await model.evaluate("window.clicked||0") as? Int == 0,
      "locking does not activate the page button")
    try await key(model, "ArrowUp")
    try await wait("arrow up selects parent") { model.selection?.tag == "button" }
    let button = try require(model.selection, "button details are available")
    try expect(
      button.box.padding == ["10px", "20px", "10px", "20px"]
        && button.box.border == Array(repeating: "2px", count: 4),
      "box model reflects computed padding and border")
    try expect(
      button.typography.size == "16px" && button.typography.weight == "600",
      "typography reflects actual computed size and weight")
    try expect(
      button.fontsAvailable && button.renderedFonts.contains(where: { $0.contains("Arial") }),
      "Chromium reports rendered font rather than a CSS fallback guess")
    try expect(
      button.colors.first(where: { $0.label == "Background" })?.value.formatted(.hex) == "#2563EB",
      "color swatch preserves the computed button fill")
    try expect(
      button.contrastGrade == "AA" && (button.contrast ?? 0) > 5,
      "solid text contrast has measured WCAG AA result")
    try expect(
      button.playwright.contains("getByTestId") && button.jsPath.contains("querySelector"),
      "header exposes Playwright and JavaScript targets")
    try expect(
      try await model.evaluate("document.querySelectorAll(\(json(button.css))).length") as? Int
        == 1, "copied CSS resolves uniquely")
    try await capture(model, stem: "\(phase)-inspector")
    try await styles(model)
    try await key(model, "ArrowRight")
    try await wait("arrow right selects next sibling") { model.selection?.css == "#next" }
    try await key(model, "ArrowLeft")
    try await wait("arrow left selects previous sibling") { model.selection?.css == "#save" }
    try await key(model, "ArrowDown")
    try await wait("arrow down selects first child") { model.selection?.tag == "span" }
    let ancestor = try require(
      model.selection?.ancestors.first(where: { $0.label == "main" }),
      "breadcrumb exposes parent ancestry")
    model.selectAncestor(ancestor.id)
    try await wait("breadcrumb selects its ancestor") { model.selection?.tag == "main" }
    model.pick()
    try expect(
      await pointer(model, selector: "#transparent", click: true),
      "transparent text can be selected")
    try await wait("transparent text data arrives") { model.selection?.css == "#transparent" }
    try expect(
      model.selection?.foreground.rgba.last == 0.5 && model.selection?.contrastGrade == "Fail",
      "alpha is retained precisely when calculating contrast")
    model.pick()
    try expect(
      await pointer(model, selector: "#gradient", click: true), "gradient element can be selected")
    try await wait("gradient data arrives") { model.selection?.css == "#gradient" }
    try expect(
      model.selection?.contrast == nil && model.selection?.contrastLimit != nil,
      "complex backgrounds do not receive a fabricated contrast pass")
    model.pick()
    try expect(
      await pointer(model, selector: "#nested", frames: ["#frame"], click: true),
      "trusted input reaches same-origin iframe element")
    try await wait("iframe selection retains context") { model.selection?.frames.count == 1 }
    try expect(
      model.selection?.playwright.contains("frameLocator") == true
        && model.selection?.jsPath.contains("contentDocument") == true,
      "copied locators retain iframe context")
    try await key(model, "Escape")
    try await wait("Escape removes Inspector and its overlay") { !model.isOpen }
    try expect(
      try await model.evaluate("document.querySelector('[data-shaar-inspector]')===null") as? Bool
        == true, "exit leaves no overlay behind")
    try expect(
      NSApp.keyWindow === keyWindow
        && engine.runtime.window(forID: engine.windowID)?.isVisible == false,
      "Inspector never orders a window or changes desktop focus")
    if phase == "initial"
      && ProcessInfo.processInfo.environment["SHAAR_INSPECTOR_PUBLIC_CAPTURE"] == "1"
    {
      try await publicCaptures()
    }
    store.perform(.space(returning))
    try expect(store.removeSpace(space), "Inspector fixture tabs close")
    try await wait("closing tab releases its Inspector") {
      self.engine.inspectors[target.tabID] == nil
    }
  }

  private func publicCaptures() async throws {
    for (name, address) in [
      (
        "mdn",
        "https://developer.mozilla.org/en-US/docs/Web/CSS/CSS_box_model/Introduction_to_the_CSS_box_model"
      ),
      ("wcag", "https://www.w3.org/WAI/WCAG22/Understanding/contrast-minimum.html"),
    ] {
      let url = URL(string: address)!
      store.perform(.open(url))
      try await loaded(host: url.host!)
      let target = try require(engine.siteControlTarget, "public page has an owned target")
      engine.toggleInspector(for: target)
      let model = try require(engine.inspectors[target.tabID], "public Inspector exists")
      try await wait("public Inspector installs") {
        try await model.evaluate("!!globalThis.__shaarInspectorV2") as? Bool == true
      }
      try expect(
        await pointer(model, selector: "h1", click: true),
        "public heading selected with trusted renderer input")
      try await wait("public heading styles arrive") { model.selection?.locked == true }
      try await wait("rendered public page fonts are listed") {
        model.selection?.pageFonts.isEmpty == false
      }
      try await capture(model, stem: "public-\(name)")
      model.tab = .styles
      await model.styles.refresh(force: true)
      try expect(
        !model.styles.rules.isEmpty && !model.styles.computed.isEmpty,
        "public CSS rules and computed values arrive")
      try expect(
        model.styles.rules.contains { $0.source.hasPrefix("https://") },
        "public CSS resolves a real source URL and generated line")
      try await capture(model, stem: "public-\(name)-css")
      let image: Data? = await withCheckedContinuation { continuation in
        engine.runtime.captureProbeTabID(target.tabID.uuidString) {
          continuation.resume(returning: $0)
        }
      }
      try image?.write(to: root.appending(path: "public-\(name)-page.png"))
      model.close()
    }
  }

  private func styles(_ model: InspectorModel) async throws {
    model.tab = .styles
    let styles = model.styles
    await styles.refresh(force: true)
    try expect(
      styles.failure == nil && styles.selectedID == model.selection?.id,
      "CSS model follows locked element")
    try expect(
      styles.rules.contains {
        $0.selector.contains("button") && $0.source.contains("/inspector#style-")
          && $0.source.contains(":")
      }, "matched CSS resolves real inline source and line")
    let authored = styles.rules.first { $0.selector == "button" && $0.source.contains("#style-") }
    try expect(
      authored?.declarations.contains { $0.name == "font" } == true
        && authored?.declarations.contains { $0.name == "font-style" } == false,
      "matched declarations retain authored shorthand without generated longhands")
    try expect(
      styles.computed.contains { $0.name == "padding-top" && $0.value == "10px" },
      "computed CSS contains final used values")
    try expect(
      styles.css.contains("padding-top: 10px;") && styles.tailwind.contains("[padding-top:10px]"),
      "CSS and Tailwind exports include computed spacing")
    await styles.edit(property: "padding", value: "30px", important: true)
    try expect(
      try await model.evaluate("getComputedStyle(document.querySelector('#save')).padding")
        as? String == "30px", "live override changes actual renderer")
    await styles.undo()
    try expect(
      try await model.evaluate("document.querySelector('#save').getAttribute('style')===null")
        as? Bool == true,
      "undo restores absent style attribute exactly")
    try await wait("undo restores box details") { model.selection?.box.padding.first == "10px" }
    try expect(
      await pointer(model, selector: "#next", click: false, modifiers: 1),
      "trusted Option hover reaches page")
    let measurement =
      try await model.evaluate("globalThis.__shaarInspectorStyles.measurement()")
      as? [String: Double]
    try expect(
      abs((measurement?["horizontal"] ?? -999) - 32) < 0.5,
      "Option guide measures actual sibling gap")
    _ = await pointer(model, selector: "#next", click: false)
    let button = try require(model.selection, "screenshot selection exists")
    let png = try await styles.screenshot()
    guard let bitmap = NSBitmapImageRep(data: png) else {
      throw InspectorFailure("Element screenshot is not a PNG.")
    }
    try expect(
      abs(Double(bitmap.pixelsWide) - button.box.width * 2) <= 2
        && abs(Double(bitmap.pixelsHigh) - button.box.height * 2) <= 2,
      "element screenshot contains exactly two pixels per CSS pixel")
    try png.write(to: root.appending(path: "\(phase)-inspector-element@2x.png"))
    try await capture(model, stem: "\(phase)-inspector-css")
    for (selector, display) in [("#grid", "grid"), ("#flex", "flex")] {
      model.pick()
      try expect(
        await pointer(model, selector: selector, click: true), "layout fixture can be selected")
      // The fixture's center can hit a child; choose the container through its ancestor.
      try await wait("layout fixture locks") { model.mode == .locked }
      if model.selection?.css != selector {
        _ = try await model.evaluate(
          "(()=>{const api=globalThis.__shaarInspectorV2;for(let i=0;i<4&&api.element().id!==\(json(String(selector.dropFirst())));i++)api.navigate('up');return true;})()"
        )
      }
      try await wait("layout container details arrive") { model.selection?.css == selector }
      await styles.refresh(force: true)
      try expect(
        styles.computed.contains { $0.name == "display" && $0.value == display },
        "layout properties distinguish \(display)")
      await styles.toggleOverlay()
      try expect(
        styles.overlay && styles.failure == nil, "Chromium accepts real \(display) overlay")
      if display == "grid" {
        let highlight = try await model.withSelectedNode { node in
          try await model.call(
            "Overlay.getGridHighlightObjectsForTest", params: ["nodeIds": [node]])
        }
        try expect(
          !(highlight["highlights"] as? [String: Any] ?? [:]).isEmpty,
          "Chromium computes grid highlight geometry")
      }
      await styles.clearOverlay()
      try expect(!styles.overlay, "layout overlay turns off")
    }
    model.pick()
    try expect(
      await pointer(model, selector: "#save", click: true), "selection returns to button child")
    try await wait("button child selected again") { model.selection?.tag == "span" }
    try await key(model, "ArrowUp")
    try await wait("button restored after CSS probe") { model.selection?.css == "#save" }
    model.tab = .design
  }

  private func loaded(host: String) async throws {
    try await wait("page loads at \(host)") {
      guard let target = self.engine.siteControlTarget, target.host == host,
        self.engine.pages[target.tabID]?.loading == false
      else { return false }
      return self.engine.runtime.view(forTabID: target.tabID.uuidString)?.superview != nil
    }
  }
  private func pointer(
    _ model: InspectorModel, selector: String, frames: [String] = [], click: Bool,
    modifiers: Int = 0
  ) async -> Bool {
    await withCheckedContinuation { continuation in
      engine.runtime.inspectorProbePointer(
        inTabID: model.target.tabID.uuidString, selector: selector, frames: frames, click: click,
        modifiers: modifiers
      ) { continuation.resume(returning: $0) }
    }
  }
  private func key(_ model: InspectorModel, _ key: String) async throws {
    let accepted: Bool = await withCheckedContinuation { continuation in
      engine.runtime.inspectorProbeKey(inTabID: model.target.tabID.uuidString, key: key) {
        continuation.resume(returning: $0)
      }
    }
    try expect(accepted, "trusted \(key) reaches the inspected page")
  }
  private func capture(_ model: InspectorModel, stem: String) async throws {
    for (name, scheme) in [("light", ColorScheme.light), ("dark", .dark)] {
      let panel = InspectorPanel(model: model).frame(width: 320, height: 960).environment(
        \.colorScheme, scheme)
      let host = NSHostingView(rootView: panel)
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 320, height: 960), styleMask: .borderless,
        backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
      window.contentView = host
      host.layoutSubtreeIfNeeded()
      try await Task.sleep(for: .milliseconds(150))
      guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
        throw InspectorFailure("Inspector capture could not render.")
      }
      host.cacheDisplay(in: host.bounds, to: bitmap)
      guard let png = bitmap.representation(using: .png, properties: [:]) else {
        throw InspectorFailure("Inspector capture could not encode.")
      }
      try png.write(to: root.appending(path: "\(stem)-\(name).png"))
      window.contentView = nil
      window.close()
    }
    let state = try await model.evaluate("globalThis.__shaarInspectorV2.read()")
    let metadata: [String: Any] = [
      "url": model.target.url.absoluteString, "state": state ?? NSNull(),
      "tab": model.tab.rawValue,
      "matchedRules": model.styles.rules.map { rule in
        [
          "selector": rule.selector, "source": rule.source,
          "declarations": rule.declarations.map { ["name": $0.name, "value": $0.value] },
        ] as [String: Any]
      },
      "computedStyles": model.styles.computed.map { ["name": $0.name, "value": $0.value] },
      "renderedFonts": model.selection?.renderedFonts ?? [],
      "pageFonts": model.selection?.pageFonts ?? [],
    ]
    try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys])
      .write(to: root.appending(path: "\(stem).json"))
    checks.append("Inspector renders offscreen in light and dark on \(model.target.host)")
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
  private func expect(_ condition: Bool, _ message: String) throws {
    guard condition else { throw InspectorFailure(message) }
    checks.append(message)
  }
  private func require<T>(_ value: T?, _ message: String) throws -> T {
    guard let value else { throw InspectorFailure(message) }
    return value
  }
  private func json(_ value: String) -> String {
    String(data: try! JSONEncoder().encode(value), encoding: .utf8)!
  }
  private func report(_ error: Error?) throws {
    try JSONSerialization.data(
      withJSONObject: [
        "passed": error == nil, "checks": checks,
        "error": error?.localizedDescription as Any? ?? NSNull(),
        "scope":
          "Offscreen native Inspector and trusted renderer input on owned loopback fixtures; public-page captures require explicit opt-in.",
      ], options: [.prettyPrinted, .sortedKeys]
    ).write(to: root.appending(path: "\(phase)-inspector-report.json"))
  }
}
