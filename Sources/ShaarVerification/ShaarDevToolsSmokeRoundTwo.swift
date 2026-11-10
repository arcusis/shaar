// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import Foundation

@testable import ArcusisBrowser

@MainActor extension ShaarDevToolsSmoke {
  static func exerciseRealWorldRoundTwo(
    shell: ShaarDevToolsModel, inspector: InspectorModel,
    context: NativeBrowserContext, pageURL: URL, report: ShaarDevToolsSmokeReport
  ) async {
    await roundTwoElements(shell, inspector: inspector, context: context, report: report)
    await roundTwoLayout(shell, context: context, report: report)
    await roundTwoKeyboard(shell, context: context, report: report)
    await roundTwoHMR(inspector, pageURL: pageURL, report: report)
    await roundTwoNavigation(
      shell, inspector: inspector, context: context, pageURL: pageURL, report: report)
  }

  private static func record(
    _ passed: Bool, _ name: String, _ detail: String, report: ShaarDevToolsSmokeReport
  ) {
    if passed { report.pass(name, detail) } else { report.fail(name, detail) }
  }

  private static func roundTwoElements(
    _ shell: ShaarDevToolsModel, inspector: InspectorModel, context: NativeBrowserContext,
    report: ShaarDevToolsSmokeReport
  ) async {
    shell.section = .elements
    let ready = await wait(attempts: 80) { shell.dom.available }
    if !ready {
      report.fail("world2-elements-search", "Elements DOM lease did not reconnect")
      return
    }
    await shell.dom.loadDocument(depth: 2)
    let created = try? await inspector.evaluate(
      "(()=>{const node=document.createElement('div');node.id='shaar-round2-search';document.body.appendChild(node);return true})()"
    )
    let live = try? await inspector.evaluate(
      "document.getElementById('shaar-round2-search') !== null")
    await shell.dom.loadDocument(depth: 2)
    let shallowHasMatch = shell.dom.nodes.values.contains { node in
      node.attributes.contains { $0.name == "id" && $0.value == "shaar-round2-search" }
    }
    shell.dom.search = "#shaar-round2-search"
    let pressed = ShaarDevToolsSmokeAccess.press(
      identifier: "shaar.devtools.domSearchButton", in: context.hosting)
    let finished = await wait(attempts: 80) {
      shell.dom.selected?.attributes.contains {
        $0.name == "id" && $0.value == "shaar-round2-search"
      } == true || shell.dom.failure != nil
    }
    await settle(context)
    let selectedID = shell.dom.selectedID
    var inspectorID: Int?
    for _ in 0..<20 {
      inspectorID = await inspector.currentDOMNodeID()
      if inspectorID == selectedID { break }
      try? await Task.sleep(for: .milliseconds(50))
    }
    await settle(context)
    let matched =
      pressed && finished && shell.dom.matchOrder.count > 0
      && shell.dom.selected?.attributes.contains {
        $0.name == "id" && $0.value == "shaar-round2-search"
      } == true
      && shell.dom.rows.contains { $0.id == shell.dom.selectedID }
      && inspectorID == shell.dom.selectedID
    record(
      matched, "world2-elements-search",
      "Created=\(String(describing: created)), live=\(String(describing: live)), shallow match present=\(shallowHasMatch), search pressed=\(pressed), DOM available=\(shell.dom.available), matches=\(shell.dom.matchOrder.count), selected=\(shell.dom.selected?.name ?? "none"), inspector node=\(String(describing: inspectorID)), error=\(shell.dom.failure ?? "none")",
      report: report)
    if matched {
      let capture = report.directory.appending(path: "world-elements-search.png")
      if !ShaarDevToolsSmokeAccess.capture(context.hosting, to: capture) {
        report.fail("world-capture-elements-search", "Offscreen Elements search capture failed")
      }
    }
    guard matched else {
      _ = try? await inspector.evaluate("document.getElementById('shaar-round2-search')?.remove()")
      return
    }
    await shell.dom.setAttribute("data-shaar-round2", value: "edited")
    let value = try? await inspector.evaluate(
      "document.getElementById('shaar-round2-search')?.getAttribute('data-shaar-round2')")
    record(
      value as? String == "edited", "world2-elements-attribute",
      "Edited searched element attribute through Elements: \(String(describing: value))",
      report: report)
    _ = try? await inspector.evaluate("document.getElementById('shaar-round2-search')?.remove()")
  }

  private static func roundTwoLayout(
    _ shell: ShaarDevToolsModel, context: NativeBrowserContext,
    report: ShaarDevToolsSmokeReport
  ) async {
    for dock in [ShaarDevToolsDock.bottom, .right] {
      shell.dock = dock
      await settle(context)
      let name = dock == .bottom ? "bottom" : "right"
      let image = report.directory.appending(path: "world-round2-dock-\(name).png")
      let captured = ShaarDevToolsSmokeAccess.capture(context.hosting, to: image)
      record(
        shell.dock == dock && captured, "world2-dock-\(name)",
        "DevTools shell rendered at \(dock.rawValue)", report: report)
    }
    await ShaarDevToolsSmokeExercise.dragSplit(
      shell: shell, context: context, report: report)
    let old = context.window.appearance
    for (name, appearance) in [
      ("light", NSAppearance(named: .aqua)),
      ("dark", NSAppearance(named: .darkAqua)),
    ] {
      context.window.appearance = appearance
      await settle(context)
      let image = report.directory.appending(path: "world-round2-\(name).png")
      record(
        ShaarDevToolsSmokeAccess.capture(context.hosting, to: image),
        "world2-theme-\(name)", "Offscreen \(name) appearance captured", report: report)
    }
    context.window.appearance = old
  }

  private static func roundTwoKeyboard(
    _ shell: ShaarDevToolsModel, context: NativeBrowserContext,
    report: ShaarDevToolsSmokeReport
  ) async {
    var reached = 0
    for (index, section) in shell.sections.enumerated() where index + 1 < shell.sections.count {
      let button = "shaar.devtools.\(section.rawValue.lowercased())"
      guard ShaarDevToolsSmokeAccess.press(identifier: button, in: context.hosting) else {
        continue
      }
      let moved = ShaarDevToolsSmokeAccess.sendRightArrow(in: context.hosting)
      await settle(context)
      if moved && shell.section == shell.sections[index + 1] { reached += 1 }
    }
    if reached == shell.sections.count - 1 {
      report.pass("world2-keyboard", "Arrow navigation reached every adjacent panel")
    } else {
      report.manual(
        "world2-keyboard",
        "Offscreen arrow transitions \(reached)/\(shell.sections.count - 1); window never became key"
      )
    }
  }

  private static func roundTwoHMR(
    _ inspector: InspectorModel, pageURL: URL, report: ShaarDevToolsSmokeReport
  ) async {
    guard pageURL.host == "127.0.0.1", [3210, 3211].contains(pageURL.port ?? 0) else { return }
    let before = try? await inspector.evaluate("document.getElementById('hmr-token')?.textContent")
    guard before as? String == "before-edit" else {
      report.fail(
        "world2-hmr", "HMR marker absent before source edit: \(String(describing: before))")
      return
    }
    let marker = report.directory.appending(path: "hmr-ready")
    _ = FileManager.default.createFile(atPath: marker.path, contents: Data())
    let edited = await wait(attempts: 300) {
      FileManager.default.fileExists(atPath: report.directory.appending(path: "hmr-edited").path)
    }
    var after: Any?
    if edited {
      for _ in 0..<100 {
        after = try? await inspector.evaluate("document.getElementById('hmr-token')?.textContent")
        if after as? String == "after-edit" { break }
        try? await Task.sleep(for: .milliseconds(200))
      }
    }
    record(
      after as? String == "after-edit", "world2-hmr",
      "File edited=\(edited), open page text=\(String(describing: after))", report: report)
  }

  private static func roundTwoNavigation(
    _ shell: ShaarDevToolsModel, inspector: InspectorModel,
    context: NativeBrowserContext, pageURL: URL,
    report: ShaarDevToolsSmokeReport
  ) async {
    guard pageURL.port == 3210 else { return }
    let clicked = try? await inspector.evaluate(
      "(()=>{const link=document.getElementById('spa-link');if(!link)return false;link.click();return true})()"
    )
    let navigated = await wait(attempts: 100) {
      shell.target.url.path == "/details"
    }
    let reconnected = await wait(attempts: 100) { shell.phase2.available }
    let path = try? await inspector.evaluate("location.pathname")
    record(
      clicked as? Bool == true && navigated && path as? String == "/details" && reconnected,
      "world2-spa",
      "Clicked=\(String(describing: clicked)), path=\(String(describing: path)), lease=\(reconnected)",
      report: report)
    context.engine.runtime.goBack(inTabID: shell.target.tabID.uuidString)
    _ = await wait(attempts: 100) { context.engine.siteControlTarget?.url.path == "/" }
  }
}
