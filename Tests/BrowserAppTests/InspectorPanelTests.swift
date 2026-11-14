// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import JavaScriptCore
import SwiftUI
import Testing

@testable import ArcusisBrowser

@Suite @MainActor struct InspectorPanelTests {
  @Test func inspectorTitleIsAHeading() {
    #expect(InspectorPanel.titleAccessibilityTraits.contains(.isHeader))
  }

  init() { _ = NSApplication.shared }

  @Test func collapsedInspectorSectionsPointTowardTheLogicalCenterInBothDirections() {
    #expect(
      InspectorSection<EmptyView>.disclosureSymbol(isCollapsed: true, rightToLeft: false)
        == "chevron.right")
    #expect(
      InspectorSection<EmptyView>.disclosureSymbol(isCollapsed: true, rightToLeft: true)
        == "chevron.left")
    #expect(
      InspectorSection<EmptyView>.disclosureSymbol(isCollapsed: false, rightToLeft: true)
        == "chevron.down")
  }

  private var target: SiteControlTarget {
    .init(tabID: UUID(), profileID: UUID(), url: URL(string: "https://example.com/inspect")!)
  }

  @Test func inspectorPollBacksOffAfterUnchangedLockedReadsThenResets() {
    var cadence = InspectorPollCadence()
    cadence.selectionLocked = true
    for _ in 0..<3 { cadence.note(.unchanged) }
    #expect(cadence.delay == InspectorPollCadence.fastInterval)
    cadence.note(.unchanged)
    #expect(cadence.unchangedReads == 4)
    #expect(cadence.delay == InspectorPollCadence.idleInterval)
    cadence.note(.changed)
    #expect(cadence.unchangedReads == 0)
    #expect(cadence.delay == InspectorPollCadence.fastInterval)
    for _ in 0..<4 { cadence.note(.unchanged) }
    #expect(cadence.delay == InspectorPollCadence.idleInterval)
    cadence.wake()
    #expect(cadence.delay == InspectorPollCadence.fastInterval)
  }

  @Test func inspectorPollStaysFastWhilePicking() {
    var cadence = InspectorPollCadence()
    cadence.picking = true
    for _ in 0..<20 { cadence.note(.unchanged) }
    #expect(cadence.delay == .milliseconds(150))
    for _ in 0..<4 { cadence.note(.unavailable) }
    #expect(cadence.unavailableReads == 4)
    #expect(cadence.delay == .milliseconds(150))
    cadence.note(.changed)
    cadence.picking = false
    cadence.selectionLocked = true
    #expect(cadence.delay == .milliseconds(150))
  }

  @Test func inspectorPollBacksOffWhenReadsMissThePage() {
    var cadence = InspectorPollCadence()
    cadence.picking = true
    for _ in 0..<4 { cadence.note(.unavailable) }
    #expect(cadence.delay == .milliseconds(150))
    cadence.picking = false
    #expect(cadence.delay == .seconds(1))
    cadence.note(.unchanged)
    #expect(cadence.unavailableReads == 0)
    #expect(cadence.delay == .milliseconds(150))
  }

  @Test func inspectorPollBacksOffInThePagePanel() {
    var cadence = InspectorPollCadence()
    cadence.pagePanel = true
    for _ in 0..<3 { cadence.note(.unchanged) }
    #expect(cadence.delay == .milliseconds(150))
    cadence.note(.unchanged)
    #expect(cadence.delay == .seconds(1))
  }

  @Test func cancellingInspectorRefreshWaitStopsBeforeTheNextRead() async {
    let wait = Task {
      await InspectorModel.waitForRefreshToBecomeIdle(isRefreshing: { true })
    }
    wait.cancel()

    #expect(await !wait.value)
  }

  @Test func inspectorModelWakesThePollWhenTheUserMoves() throws {
    let model = InspectorModel(target: target, engine: nil)
    model.open()
    defer { model.close() }
    func idle() {
      model.pollCadence.picking = false
      model.pollCadence.selectionLocked = true
      model.pollCadence.pagePanel = false
      model.pollCadence.wake()
      for _ in 0..<4 { model.pollCadence.note(.unchanged) }
      #expect(model.pollCadence.delay == .seconds(1))
    }
    idle()
    model.pick()
    #expect(model.pollCadence.delay == .milliseconds(150))
    idle()
    model.setPanelMode(.page)
    #expect(model.pollCadence.delay == .milliseconds(150))
    idle()
    model.documentChanged(url: URL(string: "https://example.com/next")!, committed: true)
    #expect(model.pollCadence.delay == .milliseconds(150))
    try model.receive(Self.fixtureSelection())
    idle()
    model.selectAncestor(1)
    #expect(model.pollCadence.delay == .milliseconds(150))
  }

  @Test func inspectorRefreshTreatsAMissingPageAsUnavailable() async {
    let model = InspectorModel(target: target, engine: nil)
    model.open()
    defer { model.close() }
    #expect(await model.refresh() == .unavailable)
  }

  @Test func shippingPickerScriptParsesAsJavaScript() throws {
    let context = try #require(JSContext())
    let parse = try #require(
      context.evaluateScript("source => { new Function(source); return true; }"))
    #expect(parse.call(withArguments: [InspectorPageScript.install])?.toBool() == true)
    #expect(context.exception == nil)
  }

  @Test func selectionValidationAndNavigationRetireNativeState() async throws {
    let model = InspectorModel(target: target, engine: nil)
    #expect(!model.isOpen)
    #expect(throws: InspectorFailure.self) { try model.receive(Self.fixtureSelection()) }
    model.open()
    model.open()
    try model.receive(Self.fixtureSelection())
    #expect(model.mode == .locked && model.selection?.dimensions == "180 × 48")
    #expect(model.selection?.contrastGrade == "AAA")
    model.pick()
    model.navigate("invalid")
    model.selectAncestor(-1)
    model.documentChanged(url: URL(string: "https://example.com/next")!, committed: true)
    #expect(model.target.url.path == "/next")
    #expect(model.mode == .picking && model.selection == nil)
    try model.receive(Self.fixtureSelection(locked: false))
    #expect(model.mode == .picking)
    await model.refresh()
    model.close()
    model.close()
    #expect(model.mode == .closed && model.selection == nil)
    await #expect(throws: InspectorFailure.self) { _ = try await model.evaluate("true") }
  }

  @Test func panelRendersRealSelectionAcrossColorFormatsAndContrastLimits() async throws {
    let model = InspectorModel(target: target, engine: nil)
    model.open()
    defer { model.close() }
    let previous = NSApp.keyWindow
    var appearances: [Data] = []
    for scheme in [ColorScheme.light, .dark] {
      for format in InspectorColor.Format.allCases {
        model.colorFormat = format
        var value = Self.fixtureSelection(limit: format == .oklch ? "Gradient background" : nil)
        value.renderedFonts = ["Arial"]
        value.pageFonts = ["Arial", "Georgia"]
        value.fontsAvailable = format != .rgb
        try model.receive(value)
        let image = try await Self.render(InspectorPanel(model: model), scheme: scheme)
        #expect(image.count > 4_096)
        appearances.append(image)
      }
    }
    #expect(appearances[0] != appearances[3])
    model.documentChanged(url: target.url, committed: true)
    #expect(try await Self.render(InspectorPanel(model: model), scheme: .light).count > 4_096)
    #expect(NSApp.keyWindow === previous)
  }

  @Test func awaitingPickerAcknowledgesModeChangeBeforeNextInput() async throws {
    let model = InspectorModel(target: target, engine: nil)
    model.open()
    defer { model.close() }
    try model.receive(Self.fixtureSelection())
    #expect(model.mode == .locked)
    let pending = try #require(model.pick())
    #expect(model.mode == .locked)
    await pending.value
    #expect(model.mode == .picking)
  }

  @Test func invalidRendererPacketsCannotReplaceValidSelection() throws {
    let model = InspectorModel(target: target, engine: nil)
    model.open()
    defer { model.close() }
    let good = Self.fixtureSelection()
    try model.receive(good)
    let malformed = InspectorSelection(
      id: -1, revision: 0, locked: true, tag: "button", label: "button", component: nil,
      css: "button", xpath: "//button", playwright: "page.locator('button')",
      jsPath: "document.body",
      frames: [], ancestors: [], box: good.box, typography: good.typography,
      colors: good.colors, foreground: good.foreground, backdrop: good.backdrop, contrastLimit: nil)
    #expect(throws: InspectorFailure.self) { try model.receive(malformed) }
    #expect(model.selection == good)
  }

  static func fixtureSelection(locked: Bool = true, limit: String? = nil) -> InspectorSelection {
    .init(
      id: 8, revision: 1, locked: locked, tag: "button", label: "button.save",
      component: "SaveButton",
      css: ".save", xpath: "/html/body/button",
      playwright: "page.getByRole('button', {name:'Save'})",
      jsPath: "document.querySelector('.save')", frames: ["iframe"],
      ancestors: [
        .init(id: 1, label: "html"), .init(id: 2, label: "body"), .init(id: 3, label: "main"),
        .init(id: 8, label: "button.save"),
      ],
      box: .init(
        width: 180, height: 48, contentWidth: 136, contentHeight: 24,
        margin: ["8px", "12px", "8px", "12px"], border: Array(repeating: "2px", count: 4),
        padding: ["10px", "20px", "10px", "20px"]),
      typography: .init(
        family: "Arial, sans-serif", size: "16px", weight: "600", lineHeight: "24px",
        letterSpacing: "0.25px", preview: "Save changes"),
      colors: [
        .init(label: "Text", value: .init(css: "black", rgba: [0, 0, 0, 1])),
        .init(label: "Background", value: .init(css: "white", rgba: [1, 1, 1, 1])),
        .init(label: "Border", value: .init(css: "rgba(0,0,0,.5)", rgba: [0, 0, 0, 0.5])),
      ],
      foreground: .init(css: "black", rgba: [0, 0, 0, 1]),
      backdrop: .init(css: "white", rgba: [1, 1, 1, 1]), contrastLimit: limit)
  }

  static func render(_ panel: some View, scheme: ColorScheme) async throws -> Data {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 320, height: 1000), styleMask: [], backing: .buffered,
      defer: false)
    window.isReleasedWhenClosed = false
    window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
    let hosting = NSHostingView(
      rootView: panel.frame(width: 320, height: 1000).environment(\.colorScheme, scheme))
    window.contentView = hosting
    defer {
      window.contentView = nil
      window.close()
    }
    hosting.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(30))
    let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
    hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
    #expect(!window.isVisible)
    return try #require(bitmap.representation(using: .png, properties: [:]))
  }
}
