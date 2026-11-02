// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import BrowserCore
import Foundation
import SwiftUI
import XCTest

@testable import ArcusisBrowser

@MainActor
final class InspectorLocalizationVisualTests: XCTestCase {
  func testInspectorPanelsRenderInBothAppearancesAndKeepProtocolValuesStable() throws {
    let previousKeyWindow = NSApplication.shared.keyWindow
    defer { XCTAssertTrue(NSApp.keyWindow === previousKeyWindow) }
    let target = SiteControlTarget(
      tabID: UUID(), profileID: UUID(), url: URL(string: "https://example.com/inspect")!)
    let inspector = InspectorModel(target: target, engine: nil)
    inspector.open()
    let developer = DeveloperPageModel(target: target, engine: nil)
    let tools = InspectorPageToolsModel(inspector: inspector, developer: developer)
    tools.start()
    defer {
      tools.stop()
      developer.close()
      inspector.close()
    }

    var selection = InspectorPanelTests.fixtureSelection()
    selection.renderedFonts = ["Arial"]
    selection.pageFonts = ["Arial", "Georgia"]
    selection.fontsAvailable = true
    try inspector.receive(selection)
    let generation = inspector.documentGeneration
    inspector.tab = .styles
    try inspector.styles.receive(
      rules: [
        InspectorRule(
          id: 0, selector: ".save", source: "https://example.com/main.css:12",
          declarations: [.init(name: "display", value: "grid"), .init(name: "gap", value: "12px")])
      ],
      computed: [
        .init(name: "display", value: "grid"),
        .init(name: "grid-template-columns", value: "1fr 2fr"),
        .init(name: "font-family", value: "Arial, sans-serif"),
      ], selectionID: 8, generation: generation)
    inspector.tab = .component
    try inspector.details.receive(
      .component(
        .init(
          framework: "React",
          nodes: [.init(id: 1, name: "SaveButton", parent: nil, source: "/src/Save.tsx:4")],
          selected: 1, limit: nil),
        .init(
          id: 1, name: "SaveButton", source: "/src/Save.tsx:4", props: "{\"label\":\"Save\"}",
          state: "{\"busy\":false}", hooks: "null", truncated: false, note: nil)),
      selectionID: 8, generation: generation)
    inspector.tab = .accessibility
    var accessibility = InspectorAccessibilityData(
      aria: [.init(name: "aria-label", value: "Save")], tabOrder: 2, tabLimit: false, warnings: [])
    accessibility.role = "button"
    accessibility.name = "Save"
    accessibility.ignored = false
    try inspector.details.receive(
      .accessibility(accessibility), selectionID: 8, generation: generation)
    inspector.tab = .assets
    try inspector.details.receive(
      .assets(
        .init(
          images: [
            .init(
              index: 0, url: "https://example.com/art.png", renderedWidth: 128, renderedHeight: 96,
              naturalWidth: 64, naturalHeight: 48, transferSize: 768, bodySize: 512,
              mime: "image/png",
              frameID: "frame")
          ], svg: "<svg viewBox='0 0 10 10'></svg>", svgTruncated: false)),
      selectionID: 8, generation: generation)

    try tools.receive(pageSnapshot(), generation: generation)
    try tools.receiveTechnologies(
      [["name": "Vue", "version": "3.5.42", "source": "Component runtime marker"]],
      generation: generation)
    developer.performanceSnapshot = PagePerformanceSnapshot(
      page: [
        "timeOrigin": 1_700_000_000_000.0, "lcp": 2300.0, "inp": 220.0, "cls": 0.3,
        "fps": 60.0, "requests": 8.0, "bytes": 10_240.0,
      ],
      engineMetrics: [["name": "JSHeapUsedSize", "value": 2_097_152.0]])
    try tools.receiveStorage(
      ["items": [["key": "theme", "preview": "dark", "length": 4]]], area: "local",
      generation: generation)

    XCTAssertTrue(
      InspectorPageToolsModel.Tool.allCases.map(\.rawValue) == [
        "Tech stack", "Vitals", "Network", "Console", "Storage", "Simulations", "Bug report",
      ])
    XCTAssertTrue(
      DeveloperSimulation.Device.allCases.map(\.rawValue) == ["desktop", "phone", "tablet"])
    XCTAssertTrue(
      DeveloperSimulation.Network.allCases.map(\.rawValue) == ["normal", "slow3G", "offline"])
    XCTAssertTrue(DeveloperSimulation.CPU.allCases.map(\.rawValue) == [1, 4, 6])
    XCTAssertTrue(
      DeveloperSimulation.Location.allCases.map(\.rawValue) == ["actual", "sanFrancisco", "london"])
    XCTAssertTrue(
      DeveloperSimulation.Timezone.allCases.map(\.rawValue) == ["system", "newYork", "tokyo"])
    XCTAssertTrue(
      DeveloperSimulation.Language.allCases.map(\.rawValue) == [
        "system", "english", "french", "hebrew",
      ])
    XCTAssertTrue(
      [
        PerformanceQuality.unavailable.rawValue, PerformanceQuality.good.rawValue,
        PerformanceQuality.needsImprovement.rawValue, PerformanceQuality.poor.rawValue,
      ] == ["unavailable", "good", "needsImprovement", "poor"])
    XCTAssertTrue(
      DeveloperSimulation().commands(userAgent: "fixture").contains {
        $0.0 == "Network.emulateNetworkConditions"
      })
    XCTAssertEqual(tools.requests.count, 1)
    XCTAssertEqual(tools.requests.first?.method, "GET")
    XCTAssertEqual(tools.requests.first?.status, 200)
    XCTAssertEqual(developer.performanceSnapshot?.requests, 8)
    let archive = BugReportArchive.har(
      snapshot: pageSnapshot(), includeSensitiveHeaders: false, version: "test")
    let log = try XCTUnwrap(archive["log"] as? [String: Any])
    XCTAssertTrue(log["version"] as? String == "1.2")
    XCTAssertTrue(log["creator"] != nil && log["entries"] != nil && log["_captureScope"] != nil)

    let language = BrowserLanguage.currentLaunchLanguage == .hebrew ? "he" : "en"
    if language == "he" {
      XCTAssertTrue(
        InspectorL10n.string("Inspector").unicodeScalars.contains {
          (0x0590...0x05FF).contains($0.value)
        })
      XCTAssertTrue(
        InspectorToolsL10n.string("Bug report").unicodeScalars.contains {
          (0x0590...0x05FF).contains($0.value)
        })
    }
    let outputDirectory = URL(
      fileURLWithPath: "build/Verification/localization-visuals/\(language)")
    try FileManager.default.createDirectory(
      at: outputDirectory, withIntermediateDirectories: true)
    let componentTree = try XCTUnwrap(inspector.details.tree)
    let componentData = try XCTUnwrap(inspector.details.component)
    let assetsData = try XCTUnwrap(inspector.details.assets)
    let stylesRules = inspector.styles.rules
    let computedStyles = inspector.styles.computed
    let elementPanels: [(String, InspectorModel.Tab)] = [
      ("design", .design), ("css", .styles), ("component", .component),
      ("accessibility", .accessibility), ("assets", .assets),
    ]
    for (name, tab) in elementPanels {
      inspector.tab = tab
      switch tab {
      case .styles:
        try inspector.styles.receive(
          rules: stylesRules, computed: computedStyles, selectionID: 8, generation: generation)
      case .component:
        try inspector.details.receive(
          .component(componentTree, componentData), selectionID: 8, generation: generation)
      case .accessibility:
        try inspector.details.receive(
          .accessibility(accessibility), selectionID: 8, generation: generation)
      case .assets:
        try inspector.details.receive(
          .assets(assetsData), selectionID: 8, generation: generation)
      case .design: break
      }
      try capture(InspectorPanel(model: inspector), name: name, directory: outputDirectory)
    }
    inspector.setPanelMode(.page)
    for tool in InspectorPageToolsModel.Tool.allCases {
      tools.tool = tool
      try capture(
        InspectorPageToolsView(inspector: inspector, model: tools), name: toolName(tool),
        directory: outputDirectory)
    }
  }

  private func capture<V: View>(_ view: V, name: String, directory: URL) throws {
    for (appearance, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
      let url = directory.appending(path: "inspector-\(name)-\(suffix).png")
      let language = BrowserLanguage.currentLaunchLanguage
      let root = view.frame(width: 320, height: 1000)
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(\.colorScheme, suffix == "dark" ? .dark : .light)
        .environment(\.locale, Locale(identifier: language.localeIdentifier))
        .environment(\.layoutDirection, language.isRightToLeft ? .rightToLeft : .leftToRight)
        .transaction { $0.disablesAnimations = true }
      let bitmap = try VisualCapture.renderOffscreen(
        root, size: NSSize(width: 320, height: 1000),
        appearance: appearance, to: url)
      XCTAssertEqual(bitmap.pixelsWide, 320)
      XCTAssertEqual(bitmap.pixelsHigh, 1000)
      XCTAssertTrue(hasVisiblePixels(bitmap), "Nonblank Inspector panel: \(name)-\(suffix)")
      XCTAssertTrue((try Data(contentsOf: url)).count > 4_096)
    }
  }

  private func hasVisiblePixels(_ bitmap: NSBitmapImageRep) -> Bool {
    var colors = Set<String>()
    for x in stride(from: 4, to: bitmap.pixelsWide, by: 20) {
      for y in stride(from: 4, to: bitmap.pixelsHigh, by: 20) {
        guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
        let red = Int((color.redComponent * 255).rounded())
        let green = Int((color.greenComponent * 255).rounded())
        let blue = Int((color.blueComponent * 255).rounded())
        colors.insert("\(red)-\(green)-\(blue)")
      }
    }
    return colors.count > 3
  }

  private func toolName(_ tool: InspectorPageToolsModel.Tool) -> String {
    switch tool {
    case .overview: "overview"
    case .vitals: "vitals"
    case .network: "network"
    case .console: "console"
    case .storage: "storage"
    case .simulations: "simulations"
    case .report: "report"
    }
  }

  private func pageSnapshot() -> [String: Any] {
    [
      "startedAt": 1_700_000_000_000.0, "timeOrigin": 1_700_000_000_000.0,
      "console": [["level": "error", "message": "fixture error", "time": 1_700_000_000_002.0]],
      "network": [
        [
          "url": "https://example.com/app.js", "start": 1.0, "end": 3.0, "method": "GET",
          "status": 200,
        ]
      ],
      "resources": [
        [
          "url": "https://example.com/app.js", "start": 1.0, "duration": 2.0,
          "status": 200.0, "transfer": 2048.0, "initiator": "script",
        ]
      ],
    ]
  }
}
