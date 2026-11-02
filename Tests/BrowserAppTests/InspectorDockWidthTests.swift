// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import BrowserCore
import SwiftUI
import XCTest

@testable import ArcusisBrowser

@MainActor final class InspectorDockWidthTests: XCTestCase {
  func testLongContentKeepsDockWidthAcrossTabSwitches() async throws {
    let application = NSApplication.shared
    let previous = application.keyWindow
    defer { XCTAssertTrue(application.keyWindow === previous) }
    let inspector = InspectorModel(
      target: .init(
        tabID: UUID(), profileID: UUID(), url: URL(string: "https://example.com/layout")!),
      engine: nil)
    inspector.open()
    defer { inspector.close() }
    try inspector.receive(Self.selection())
    let language = BrowserLanguage.currentLaunchLanguage.localeIdentifier
    let output = URL(fileURLWithPath: "build/Verification/localization-visuals/\(language)")
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    for width in [CGFloat(320), 420] {
      for (name, scheme, appearance) in [
        ("light", ColorScheme.light, NSAppearance.Name.aqua), ("dark", .dark, .darkAqua),
      ] {
        #if INSPECTOR_BEFORE_CAPTURE
          let panel = AnyView(InspectorPanel(model: inspector))
          let prefix = "before"
        #else
          let layout = InspectorLayoutSnapshot()
          let panel = AnyView(InspectorPanel(model: inspector, layout: layout))
          let prefix = "after"
        #endif
        let host = NSHostingView(
          rootView: panel.frame(width: width, height: 960).environment(\.colorScheme, scheme))
        let window = NSWindow(
          contentRect: NSRect(x: 0, y: 0, width: width, height: 960), styleMask: .borderless,
          backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        window.contentView = host
        defer {
          window.contentView = nil
          window.close()
        }
        for (tabName, tab) in [
          ("design", InspectorModel.Tab.design), ("code", .styles), ("design-return", .design),
        ] {
          inspector.tab = tab
          if tab == .styles {
            try inspector.styles.receive(
              rules: [
                .init(
                  id: 0, selector: ".layout" + String(repeating: "-long-selector", count: 30),
                  source: "https://example.com/styles.css:12",
                  declarations: [
                    .init(name: "font-family", value: String(repeating: "LongFont", count: 120))
                  ])
              ],
              computed: [
                .init(name: "font-family", value: String(repeating: "LongFont", count: 120))
              ],
              selectionID: 8, generation: inspector.documentGeneration)
          }
          host.layoutSubtreeIfNeeded()
          try await Task.sleep(for: .milliseconds(120))
          host.layoutSubtreeIfNeeded()
          XCTAssertEqual(host.frame.width, width, accuracy: 0.5)
          XCTAssertEqual(host.fittingSize.width, width, accuracy: 0.5)
          XCTAssertFalse(window.isVisible)
          XCTAssertTrue(application.keyWindow === previous)
          #if !INSPECTOR_BEFORE_CAPTURE
            XCTAssertEqual(layout.panelSize.width, width, accuracy: 0.5)
            XCTAssertEqual(layout.contentFrame.width, width, accuracy: 0.5)
            let tabs = layout.tabFrames.values.sorted { $0.minX < $1.minX }
            XCTAssertEqual(tabs.count, 6)
            for (left, right) in zip(tabs, tabs.dropFirst()) {
              XCTAssertGreaterThanOrEqual(right.minX - left.maxX, 3.5)
            }
            XCTAssertLessThanOrEqual(tabs.last?.maxX ?? .infinity, width + 0.5)
            let selectedChip = try XCTUnwrap(layout.breadcrumbFrames[8])
            XCTAssertGreaterThanOrEqual(selectedChip.minX, 11.5)
            XCTAssertLessThanOrEqual(selectedChip.maxX, width - 11.5)
          #endif
          if tabName != "design-return" {
            _ = try VisualCapture.render(
              host, to: output.appending(path: "\(prefix)-\(tabName)-\(Int(width))-\(name).png"))
          }
        }
      }
    }
  }

  func testBreadcrumbUsesReadableIdentityWithoutChangingNavigationID() throws {
    #if !INSPECTOR_BEFORE_CAPTURE
      let selection = try Self.selection()
      XCTAssertEqual(
        selection.ancestors.map(\.displayLabel),
        [
          "html", "body", "main#page", "section#content", "div#details",
        ])
      XCTAssertEqual(selection.ancestors.last?.id, selection.id)
      XCTAssertEqual(selection.ancestors[3].label, "section.second/50.flex")
      XCTAssertEqual(
        InspectorSelection.Ancestor(id: 1, label: "div.w-full.flex").displayLabel, "div")
    #endif
  }

  private static func selection() throws -> InspectorSelection {
    let data = Data(
      #"""
      {"id":8,"revision":1,"locked":true,"tag":"div","label":"div.w-full.flex",
       "css":"#details","xpath":"/html/body/main/section/div","playwright":"page.locator('#details')",
       "jsPath":"document.querySelector('#details')","frames":[],
       "ancestors":[
         {"id":1,"label":"html","tag":"html"},
         {"id":2,"label":"body","tag":"body"},
         {"id":3,"label":"main.mx-auto.max-w-screen","tag":"main","identifier":"page"},
         {"id":4,"label":"section.second/50.flex","tag":"section","identifier":"content"},
         {"id":8,"label":"div.w-full.flex","tag":"div","identifier":"details"}],
       "box":{"width":480,"height":120,"contentWidth":440,"contentHeight":80,
         "margin":["0px","0px","0px","0px"],"border":["0px","0px","0px","0px"],
         "padding":["20px","20px","20px","20px"]},
       "typography":{"family":"Arial, sans-serif","size":"16px","weight":"400",
         "lineHeight":"24px","letterSpacing":"normal","preview":"Selected element details"},
       "colors":[{"label":"Text","value":{"css":"black","rgba":[0,0,0,1]}},
         {"label":"Background","value":{"css":"white","rgba":[1,1,1,1]}}],
       "foreground":{"css":"black","rgba":[0,0,0,1]},
       "backdrop":{"css":"white","rgba":[1,1,1,1]},
       "display":"block","identifier":"details","classNames":["w-full","flex"]}
      """#.utf8)
    return try JSONDecoder().decode(InspectorSelection.self, from: data)
  }
}
