// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import Foundation
import SwiftUI
import Testing

@testable import ArcusisBrowser

@Suite @MainActor struct ShaarDevToolsSettingsTests {
  @Test func pinnedPanelAndDockSurviveCloseAndReopen() {
    let defaults = UserDefaults(suiteName: "ShaarDevToolsSettings.\(UUID().uuidString)")!
    let target = SiteControlTarget(
      tabID: UUID(), profileID: UUID(), url: URL(string: "http://localhost:3000/")!)
    let inspector = InspectorModel(target: target, engine: nil)
    let shell = ShaarDevToolsModel(target: target, layoutDefaults: defaults)
    #expect(shell.opening == .panel(.elements))
    shell.open(inspector: inspector)
    shell.chooseOpening(.panel(.console))
    shell.dock = .bottom
    shell.rightWidth = 470
    shell.leftWidth = 360
    shell.bottomHeight = 300
    shell.restoreDefaultDockSizes()
    #expect(shell.rightWidth == ShaarDevToolsMetrics.sideWidth)
    #expect(shell.leftWidth == ShaarDevToolsMetrics.sideWidth)
    #expect(shell.bottomHeight == ShaarDevToolsMetrics.bottomHeight)
    shell.section = .network
    shell.close()
    shell.open(inspector: inspector)
    #expect(shell.section == .console)
    #expect(shell.dock == .bottom)
    #expect(!shell.settingsOpen)
    shell.showSettings()
    #expect(shell.settingsOpen)
    shell.toggleCommandMenu()
    #expect(shell.commandMenuOpen && !shell.settingsOpen)
  }

  @Test func lastPanelSurvivesANewShell() {
    let defaults = UserDefaults(suiteName: "ShaarDevToolsSettings.\(UUID().uuidString)")!
    let target = SiteControlTarget(
      tabID: UUID(), profileID: UUID(), url: URL(string: "http://localhost:3000/")!)
    let shell = ShaarDevToolsModel(target: target, layoutDefaults: defaults)
    shell.chooseOpening(.last)
    shell.section = .sources
    let reopened = ShaarDevToolsModel(target: target, layoutDefaults: defaults)
    #expect(reopened.opening == .last)
    #expect(reopened.section == .sources)
    #expect(reopened.dock == .right)
  }

  @Test func commandMenuIncludesSettings() {
    let matches = ShaarDevToolsCommandIndex.matches(
      query: "set", sections: ShaarDevToolsSection.allCases, console: [], network: [],
      sources: [], nodes: [])
    #expect(matches.contains { $0.hit == .settings && $0.title == "Settings" })
    #expect(ShaarDevToolsCommandHit.settings.token == "settings")
    #expect(ShaarDevToolsCommandHit.settings.groupKey == nil)
    #expect(ShaarDevToolsCommandHit.settings.localizesTitle)
  }

  @Test func settingsSheetRendersOffscreen() throws {
    _ = NSApplication.shared
    let defaults = UserDefaults(suiteName: "ShaarDevToolsSettings.\(UUID().uuidString)")!
    let target = SiteControlTarget(
      tabID: UUID(), profileID: UUID(), url: URL(string: "http://localhost:3000/")!)
    let inspector = InspectorModel(target: target, engine: nil)
    let shell = ShaarDevToolsModel(target: target, layoutDefaults: defaults)
    shell.open(inspector: inspector)
    shell.dock = .bottom
    shell.chooseOpening(.last)
    #expect(shell.opening.title == "Last panel")
    #expect(ShaarDevToolsOpening.panel(.network).title == "Network")
    let unknown = UserDefaults(suiteName: "ShaarDevToolsSettings.\(UUID().uuidString)")!
    unknown.set("not-a-panel", forKey: ShaarDevToolsOpening.key)
    #expect(ShaarDevToolsOpening.load(unknown) == .panel(.elements))
    shell.showSettings()
    shell.section = .security
    let settings = try VisualCapture.pngOffscreen(
      ShaarDevToolsSettings(model: shell), size: NSSize(width: 440, height: 320))
    let panel = try VisualCapture.pngOffscreen(
      ShaarDevToolsPanel(model: shell, inspector: inspector, openChromium: {}),
      size: NSSize(width: 850, height: 620))
    #expect(!settings.isEmpty)
    #expect(!panel.isEmpty)
    shell.close()
  }
}
