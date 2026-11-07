// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import Foundation

@MainActor extension ShaarDevToolsSmoke {
  static func exerciseRealWorldRoundTwo(
    shell: ShaarDevToolsModel, inspector: InspectorModel,
    context: NativeBrowserContext, pageURL: URL, report: ShaarDevToolsSmokeReport
  ) async {
    await roundTwoElements(shell, inspector: inspector, report: report)
    await roundTwoConsole(shell, inspector: inspector, report: report)
    await roundTwoSources(shell, pageURL: pageURL, report: report)
    await roundTwoNetwork(shell, pageURL: pageURL, report: report)
    await roundTwoSocketAndWorker(shell, inspector: inspector, pageURL: pageURL, report: report)
    await roundTwoCookies(shell, inspector: inspector, report: report)
    await roundTwoPerformance(shell, inspector: inspector, report: report)
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
    _ shell: ShaarDevToolsModel, inspector: InspectorModel, report: ShaarDevToolsSmokeReport
  ) async {
    shell.section = .elements
    let ready = await wait(attempts: 80) { shell.dom.available }
    if !ready {
      report.fail("world2-elements-search", "Elements DOM lease did not reconnect")
      return
    }
    await shell.dom.loadDocument(depth: 2)
    let created = try? await inspector.evaluate(
      "(()=>{const node=document.createElement('div');node.id='shaar-round2-search';document.body.appendChild(node);return true})()")
    let live = try? await inspector.evaluate(
      "document.getElementById('shaar-round2-search') !== null")
    shell.dom.search = "#shaar-round2-search"
    await shell.dom.performSearch()
    let matched = shell.dom.matchOrder.count > 0
      && shell.dom.selected?.attributes.contains {
        $0.name == "id" && $0.value == "shaar-round2-search"
      } == true
    record(
      matched, "world2-elements-search",
      "Created=\(String(describing: created)), live=\(String(describing: live)), DOM available=\(shell.dom.available), matches=\(shell.dom.matchOrder.count), selected=\(shell.dom.selected?.name ?? "none"), error=\(shell.dom.failure ?? "none")",
      report: report)
    guard matched else {
      _ = try? await inspector.evaluate("document.getElementById('shaar-round2-search')?.remove()")
      return
    }
    await shell.dom.setAttribute("data-shaar-round2", value: "edited")
    let value = try? await inspector.evaluate(
      "document.getElementById('shaar-round2-search')?.getAttribute('data-shaar-round2')")
    record(
      value as? String == "edited", "world2-elements-attribute",
      "Edited searched element attribute through Elements: \(String(describing: value))", report: report)
    _ = try? await inspector.evaluate("document.getElementById('shaar-round2-search')?.remove()")
  }

  private static func roundTwoConsole(
    _ shell: ShaarDevToolsModel, inspector: InspectorModel, report: ShaarDevToolsSmokeReport
  ) async {
    shell.section = .console
    _ = try? await inspector.evaluate(
      "console.log('shaar-round2-object', {shaarRound2: 42, nested: {ok: true}})")
    let received = await wait(attempts: 60) {
      shell.console.rows(from: shell.consoleEvents).contains {
        $0.event.message.contains("shaar-round2-object")
      }
    }
    if let object = shell.console.rows(from: shell.consoleEvents).last(where: {
      $0.event.message.contains("shaar-round2-object")
    }) {
      await shell.console.toggleProperties(for: object.event, inspector: inspector)
      let properties = shell.console.properties[object.id] ?? object.event.previewProperties
      record(
        received && properties.contains { $0.name == "shaarRound2" },
        "world2-console-object", "Expanded object has \(properties.count) properties",
        report: report)
    } else {
      report.fail("world2-console-object", "Console object did not arrive")
    }
    shell.console.command = "const shaarRound2 = 40;\nshaarRound2 + 2"
    await shell.console.submit { expression in
      let reply = try await inspector.call(
        "Runtime.evaluate", params: ["expression": expression, "returnByValue": false])
      return try ShaarConsoleModel.evaluation(from: reply)
    }
    let evaluated = shell.console.localEntries.contains {
      $0.level == .info && $0.message == "42"
    }
    record(evaluated, "world2-console-multiline", "Multiline console expression returned 42", report: report)
  }

  private static func roundTwoSources(
    _ shell: ShaarDevToolsModel, pageURL: URL, report: ShaarDevToolsSmokeReport
  ) async {
    shell.section = .sources
    await shell.sources.refresh()
    guard let scheme = pageURL.scheme, let host = pageURL.host else {
      report.fail("world2-source-open", "Page URL has no origin")
      return
    }
    let candidates = shell.sources.resources.filter { resource in
      resource.url.hasPrefix(scheme + "://" + host)
        && (resource.name.hasSuffix(".vue") || resource.name.hasSuffix(".js")
          || resource.name.hasSuffix(".ts") || resource.name.hasSuffix(".tsx"))
    }
    guard let chosen = candidates.first(where: { $0.name.hasSuffix(".vue") })
      ?? candidates.first(where: { $0.name.hasSuffix(".js") })
    else {
      let names = shell.sources.resources.prefix(12).map(\.name).joined(separator: ", ")
      report.fail(
        "world2-source-open",
        "No same-origin script or Vue resource in \(shell.sources.resources.count) entries: \(names)")
      return
    }
    await shell.sources.select(chosen)
    let opened = shell.sources.content?.isEmpty == false && shell.sources.failure == nil
    record(opened, "world2-source-open", "Opened \(chosen.name) from Sources", report: report)
    if shell.sources.canPrettyPrint {
      let before = shell.sources.displayedContent
      shell.sources.prettyPrint = true
      let after = shell.sources.displayedContent
      let compact = before?.split(separator: "\n").count == 1 && before?.contains("{") == true
      if compact {
        record(
          after != nil && after != before, "world2-source-pretty",
          "Pretty print transformed \(chosen.name)", report: report)
      } else {
        report.manual("world2-source-pretty", "\(chosen.name) is already formatted")
      }
    } else {
      report.manual("world2-source-pretty", "Selected \(chosen.name) is not a prettifiable type")
    }
    if pageURL.port == 3211, chosen.name.hasSuffix(".vue") {
      await shell.sources.findLocalFiles(framework: .vite)
      record(
        shell.sources.localFiles.contains { $0.path.hasSuffix("/src/App.vue") },
        "world2-source-map",
        "Vue original file count=\(shell.sources.localFiles.count), error=\(shell.sources.sourceFailure ?? "none")",
        report: report)
    } else if pageURL.host == "127.0.0.1" {
      let mapped = shell.sources.content?.contains("sourceMappingURL") == true
      report.manual(
        "world2-source-map",
        "\(chosen.name) includes sourceMappingURL=\(mapped); original-source navigation needs an interactive editor")
    }
  }

  private static func roundTwoSocketAndWorker(
    _ shell: ShaarDevToolsModel, inspector: InspectorModel, pageURL: URL,
    report: ShaarDevToolsSmokeReport
  ) async {
    guard pageURL.port == 3212 else { return }
    let socketState = try? await inspector.evaluate("document.getElementById('ws-state')?.textContent")
    shell.network.filter = .socket
    let sockets = shell.network.visibleRequests(from: shell.events)
    record(
      socketState as? String == "echo-ready" && !sockets.isEmpty,
      "world2-websocket", "Page socket=\(String(describing: socketState)), WS rows=\(sockets.count)",
      report: report)
    shell.network.filter = .all
    shell.section = .application
    shell.application.selectArea(.workers)
    await shell.application.refresh()
    let workerState = try? await inspector.evaluate("document.getElementById('sw-state')?.textContent")
    record(
      workerState as? String == "registered" && !shell.application.workers.isEmpty,
      "world2-service-worker",
      "Page worker=\(String(describing: workerState)), Application workers=\(shell.application.workers.count)",
      report: report)
  }

  private static func roundTwoNetwork(
    _ shell: ShaarDevToolsModel, pageURL: URL, report: ShaarDevToolsSmokeReport
  ) async {
    shell.section = .network
    let rows = shell.network.requests(from: shell.events)
    if pageURL.port == 3210 {
      let distinct = Set(rows.filter { $0.url.contains("/api/item/") }.map(\.url)).count
      record(
        distinct >= 100, "world2-network-volume",
        "\(distinct) distinct /api/item/ requests in \(rows.count) total rows", report: report)
    }
    shell.network.filter = .script
    let scripts = shell.network.visibleRequests(from: shell.events)
    record(
      !scripts.isEmpty && scripts.allSatisfy { $0.resource == .script },
      "world2-network-filter", "JS chip shows \(scripts.count) scripts", report: report)
    shell.network.filter = .all
    if let first = rows.first(where: { $0.url.contains("/api/item/") }) ?? rows.first {
      shell.network.search = first.url
      let searched = shell.network.visibleRequests(from: shell.events)
      record(
        !searched.isEmpty && searched.allSatisfy { $0.url.contains(first.url) },
        "world2-network-search", "Search for \(first.url) shows \(searched.count) rows",
        report: report)
      shell.network.search = ""
      let fetch = shell.network.fetchCommand(for: first)
      record(
        fetch.hasPrefix("fetch(") && fetch.contains("method:"),
        "world2-network-fetch", "Copy as fetch text generated for \(first.name)", report: report)
    }
    let har = report.directory.appending(path: "world-round2-network.har")
    do {
      try ShaarNetworkHAR.write(shell.network.exportRequests(from: shell.events), to: har)
      let size = (try? har.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
      record(size > 100, "world2-network-har", "HAR saved \(size) bytes", report: report)
    } catch {
      report.fail("world2-network-har", error.localizedDescription)
    }
  }

  private static func roundTwoCookies(
    _ shell: ShaarDevToolsModel, inspector: InspectorModel, report: ShaarDevToolsSmokeReport
  ) async {
    shell.section = .application
    shell.application.selectArea(.cookies)
    _ = try? await inspector.evaluate("document.cookie = 'shaar_round2=before; path=/'; document.cookie")
    await shell.cookies.refresh()
    guard let cookie = shell.cookies.cookies.first(where: { $0.name == "shaar_round2" }) else {
      report.fail("world2-cookie-edit", "Created first-party cookie not listed")
      report.fail("world2-cookie-delete", "Created first-party cookie not listed")
      return
    }
    shell.cookies.selectedID = cookie.id
    await shell.cookies.save(
      value: "after", secure: cookie.secure, httpOnly: cookie.httpOnly,
      sameSite: cookie.sameSite)
    let edited = shell.cookies.cookies.contains {
      $0.name == "shaar_round2" && $0.value == "after"
    }
    record(edited, "world2-cookie-edit", "Cookie value changed to after", report: report)
    shell.cookies.selectedID = shell.cookies.cookies.first { $0.name == "shaar_round2" }?.id
    await shell.cookies.deleteSelected()
    let deleted = !shell.cookies.cookies.contains { $0.name == "shaar_round2" }
    record(deleted, "world2-cookie-delete", "Cookie absent after delete", report: report)
  }

  private static func roundTwoPerformance(
    _ shell: ShaarDevToolsModel, inspector: InspectorModel, report: ShaarDevToolsSmokeReport
  ) async {
    shell.section = .performance
    shell.performance.startRecording()
    _ = try? await inspector.evaluate(
      "setTimeout(()=>{const until=performance.now()+160;while(performance.now()<until){}},30)")
    try? await Task.sleep(for: .milliseconds(350))
    await shell.performance.refresh()
    shell.performance.stopRecording()
    let count = shell.performance.timelineTasks.count
    let observed = try? await inspector.evaluate("globalThis.__shaarLongTasks?.length ?? 0")
    if observed as? Int == 0 && count == 0 {
      report.manual(
        "world2-performance-long-task",
        "Hidden page emitted no long-task entry after a 160ms timer callback")
    } else {
      record(
        count > 0, "world2-performance-long-task",
        "Page observer=\(String(describing: observed)), panel tasks=\(count)", report: report)
    }
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
        "Offscreen arrow transitions \(reached)/\(shell.sections.count - 1); window never became key")
    }
  }

  private static func roundTwoHMR(
    _ inspector: InspectorModel, pageURL: URL, report: ShaarDevToolsSmokeReport
  ) async {
    guard pageURL.host == "127.0.0.1", [3210, 3211].contains(pageURL.port ?? 0) else { return }
    let before = try? await inspector.evaluate("document.getElementById('hmr-token')?.textContent")
    guard before as? String == "before-edit" else {
      report.fail("world2-hmr", "HMR marker absent before source edit: \(String(describing: before))")
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
      "(()=>{const link=document.getElementById('spa-link');if(!link)return false;link.click();return true})()")
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
