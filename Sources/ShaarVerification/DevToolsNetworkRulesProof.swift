// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import Foundation

@testable import ArcusisBrowser

/// Page-fetch text the hidden rules probe compares against a saved rule.
enum DevToolsNetworkRulePageFetch {
  struct Receipt: Equatable {
    let status: Int
    let header: String
    let body: String
  }

  static func expression(for absoluteURL: String) -> String {
    let literal = jsString(absoluteURL)
    return """
      (async () => {
        const response = await fetch(\(literal), {cache:'no-store'});
        const header = response.headers.get('X-Shaar-Mock') || '';
        const body = await response.text();
        return String(response.status) + '\\n' + header + '\\n' + body;
      })()
      """
  }

  static func receipt(from pageText: String) throws -> Receipt {
    let parts = pageText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    guard parts.count == 3, let status = Int(parts[0]), (100...599).contains(status) else {
      throw FetchError.unexpectedReceipt
    }
    return Receipt(status: status, header: parts[1], body: parts[2])
  }

  private static func jsString(_ value: String) -> String {
    let escaped =
      value
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
    return "\"\(escaped)\""
  }

  enum FetchError: Error {
    case unexpectedReceipt
  }
}

/// Proves the rule cases the first shaar.20 receipt left open.
@MainActor struct DevToolsNetworkRulesProof {
  let engine: BrowserEngine
  let store: BrowserStore
  let shell: ShaarDevToolsModel
  let inspector: InspectorModel
  let space: UUID
  let tab: UUID
  let root: URL
  let fixture: URL

  func run() async throws -> String {
    do {
      try await disableEnabledRules()
      let fromRow = try await proveFileBodyFromNetworkRow()
      let disabled = try await proveDisabledRuleStopsIntercepting()
      let otherTab = try await proveSecondTabIsNotIntercepted()
      let project = try await proveProjectFolderScope()
      try await restoreOriginScope()
      let exchanged = try await proveImportedRule()
      let documents = try await proveDocumentsOnSideTab()
      try await returnToFixtureTools()
      return "\(fromRow) \(disabled) \(otherTab) \(project) \(exchanged) \(documents)"
    } catch {
      try? await restoreOriginScope()
      try? await returnToFixtureTools()
      throw error
    }
  }

  private func proveFileBodyFromNetworkRow() async throws -> String {
    let cache = absolute("/profile-privacy-cache")
    guard
      let row = shell.network.requests(from: shell.events).first(where: {
        $0.method == "GET" && $0.url == cache
      })
    else {
      let seen = shell.network.requests(from: shell.events).prefix(6).map(\.url).joined(
        separator: ", ")
      throw Failure("No live Network row for \(cache). Saw \(seen)")
    }
    try await install(
      from: row, url: row.url, status: 200, header: nil, bodyFile: nil, bodyText: "from-the-row")
    let copied = try await fetch(row.url, step: "row copy")
    guard copied.status == 200, copied.header.isEmpty, copied.body == "from-the-row" else {
      throw Failure("Row rule returned \(copied.status) \(copied.body)")
    }
    try await retarget(status: 201, header: nil, bodyFile: nil, bodyText: "status-201")
    let statusOnly = try await fetch(row.url, step: "status")
    guard statusOnly.status == 201, statusOnly.body == "status-201" else {
      throw Failure("Status mock returned \(statusOnly.status) \(statusOnly.body)")
    }
    try await retarget(status: 201, header: "from-file", bodyFile: nil, bodyText: "status-201")
    let withHeader = try await fetch(row.url, step: "mock header")
    guard withHeader.status == 201, withHeader.header == "from-file" else {
      throw Failure("Mock header returned \(withHeader.status) \(withHeader.header)")
    }
    let file = try writeBodyFile()
    try await retarget(status: 201, header: "from-file", bodyFile: file, bodyText: "not-the-file")
    guard shell.rules.activeCount == 1 else {
      throw Failure("Rules active count was \(shell.rules.activeCount) after the file mock")
    }
    let fetched = try await fetch(row.url, step: "file mock")
    guard fetched.status == 201, fetched.header == "from-file", fetched.body == "shaar-file-body"
    else {
      throw Failure("File mock returned \(fetched.status) \(fetched.header) \(fetched.body)")
    }
    return
      "Created from the live row; file body, status 201, and X-Shaar-Mock applied. Rules active · 1."
  }

  private func proveDisabledRuleStopsIntercepting() async throws -> String {
    guard let rule = enabledRule() else { throw Failure("File mock was not saved") }
    shell.rules.edit(rule)
    shell.rules.draft?.enabled = false
    try await shell.rules.saveDraft()
    guard shell.rules.activeCount == 0 else {
      throw Failure("Rules active count stayed \(shell.rules.activeCount) after disable")
    }
    let fetched = try await fetch(rule.url, step: "disabled rule")
    guard fetched.status == 200, fetched.header.isEmpty, isTimestamp(fetched.body) else {
      throw Failure("Disabled rule still intercepted: \(fetched.status) \(fetched.body)")
    }
    return "Disabled rule let the real response through. Rules active · 0."
  }

  private func proveSecondTabIsNotIntercepted() async throws -> String {
    let address = absolute("/inspector-echo-header", query: "shaar-rule=tab")
    try await install(
      from: nil, url: address, status: 203, header: "tab-one", bodyFile: nil, bodyText: "tab-one")
    let here = try await fetch(address, step: "selected tab")
    guard here.status == 203, here.body == "tab-one" else {
      throw Failure("Tab rule missed the selected tab: \(here.status) \(here.body)")
    }
    let other = try await openSecondTab()
    let elsewhere = try await fetch(address, using: other.inspector, step: "second tab")
    guard elsewhere.status == 200, elsewhere.body != "tab-one" else {
      throw Failure("Second tab was intercepted: \(elsewhere.status) \(elsewhere.body)")
    }
    try await selectOriginalTab()
    let again = try await fetch(address, step: "original tab")
    guard again.status == 203, again.body == "tab-one" else {
      throw Failure("Original tab lost its rule: \(again.status) \(again.body)")
    }
    try await disableEnabledRules()
    return "Second tab was not intercepted."
  }

  private func proveProjectFolderScope() async throws -> String {
    let address = absolute("/inspector-echo-header", query: "shaar-rule=project")
    let folderA = try makeFolder("rules-project-a")
    let folderB = try makeFolder("rules-project-b")
    try await shell.rules.useProjectRoot(folderA)
    try await install(
      from: nil, url: address, status: 202, header: "project-a", bodyFile: nil,
      bodyText: "project-a")
    let onA = try await fetch(address, step: "project folder")
    guard onA.status == 202, onA.body == "project-a", shell.rules.activeCount == 1 else {
      throw Failure("Project folder did not apply its rule: \(onA.status) \(onA.body)")
    }
    try await shell.rules.useProjectRoot(folderB)
    let onB = try await fetch(address, step: "other project folder")
    guard onB.status == 200, onB.body != "project-a", shell.rules.activeCount == 0 else {
      throw Failure("Other project folder still intercepted: \(onB.status) \(onB.body)")
    }
    try await shell.rules.useProjectRoot(folderA)
    let restored = try await fetch(address, step: "restored project folder")
    guard restored.status == 202, restored.body == "project-a", shell.rules.activeCount == 1 else {
      throw Failure("Project folder did not restore its rule: \(restored.status) \(restored.body)")
    }
    try await disableEnabledRules()
    return "Project folder applied, hid, and restored the saved rule."
  }

  private func proveImportedRule() async throws -> String {
    let address = absolute("/inspector-echo-header", query: "shaar-rule=import")
    var rule = ShaarNetworkRule()
    rule.enabled = true
    rule.method = "GET"
    rule.url = address
    rule.kind = .mock
    rule.status = 200
    rule.bodyText = "shaar-imported-body"
    rule.headers = [ShaarNetworkHeader(name: "X-Shaar-Mock", value: "imported")]
    let file = try ShaarNetworkRuleExchange.data(from: [rule])
    shell.rules.showingRules = true
    try await shell.rules.importDocument(file)
    guard shell.rules.activeCount == 1, shell.rules.rules.count == 1 else {
      throw Failure("Import did not replace the site rules")
    }
    let fetched = try await fetch(address, step: "imported rule")
    guard fetched.status == 200, fetched.header == "imported", fetched.body == "shaar-imported-body"
    else {
      throw Failure("Imported rule returned \(fetched.status) \(fetched.header) \(fetched.body)")
    }
    let exported = try shell.rules.exportDocument()
    let roundTrip = try ShaarNetworkRuleExchange.rules(from: exported)
    guard roundTrip.count == 1, roundTrip[0].url == address,
      roundTrip[0].bodyText == "shaar-imported-body", roundTrip[0].enabled
    else { throw Failure("Export did not round-trip the imported rule") }
    try await disableEnabledRules()
    return "Import replaced the site rules and export round-tripped them."
  }

  private struct RulesTab {
    let id: UUID
    let shell: ShaarDevToolsModel
    let inspector: InspectorModel
  }

  /// Document loads run on another tab. Navigating the probed tab removes the
  /// repro mask, and the engine then stops the screencast the later check needs.
  private func proveDocumentsOnSideTab() async throws -> String {
    let side = try await openRulesTab()
    let document = try await proveDocumentLoad(on: side)
    let live = try await proveLiveSiteDocument(on: side)
    return "\(document) \(live)"
  }

  private func proveDocumentLoad(on side: RulesTab) async throws -> String {
    let address = absolute("/inspector-tools", query: "shaar-rule=document")
    guard let page = URL(string: address) else { throw Failure("Bad document rule URL") }
    try await installDocumentRule(on: side.shell, url: address, marker: "shaar-document-mock")
    guard engine.navigateCurrentPage(to: page) else {
      throw Failure("Document navigation did not start")
    }
    do {
      _ = try await waitForMarker(
        "shaar-document-mock", step: "fixture document", tab: side.id, inspector: side.inspector)
    } catch {
      guard store.reloadCurrentPage(.bypassingCache) else { throw error }
      _ = try await waitForMarker(
        "shaar-document-mock", step: "fixture document reload", tab: side.id,
        inspector: side.inspector)
    }
    try await disableEnabledRules(on: side.shell)
    return "A document navigation returned the saved mock."
  }

  private func proveLiveSiteDocument(on side: RulesTab) async throws -> String {
    try await disableEnabledRules(on: side.shell)
    guard let page = URL(string: "https://example.com/") else {
      throw Failure("Could not build the live site URL")
    }
    guard engine.navigateCurrentPage(to: page) else {
      throw Failure("Live site navigation did not start")
    }
    _ = try await waitForMarker(
      "This domain is for use in documentation examples without needing permission.",
      step: "live site", attempts: 200, tab: side.id, inspector: side.inspector)
    try await wait("rules followed the live site", attempts: 100) {
      side.shell.rules.target.url.host == "example.com"
    }
    guard let href = try await side.inspector.evaluate("location.href") as? String,
      href.hasPrefix("https://example.com")
    else { throw Failure("Live site URL was not example.com") }
    try await installDocumentRule(on: side.shell, url: href, marker: "shaar-example-mock")
    guard store.reloadCurrentPage(.bypassingCache) else {
      throw Failure("Live site reload did not start")
    }
    do {
      _ = try await waitForMarker(
        "shaar-example-mock", step: "live site document", attempts: 150, tab: side.id,
        inspector: side.inspector)
    } catch {
      guard store.reloadCurrentPage(.bypassingCache) else { throw error }
      _ = try await waitForMarker(
        "shaar-example-mock", step: "live site document retry", attempts: 150, tab: side.id,
        inspector: side.inspector)
    }
    try await disableEnabledRules(on: side.shell)
    return "https://example.com/ loaded, then a document reload used the saved mock."
  }

  private func openRulesTab() async throws -> RulesTab {
    let opened = try await openSecondTab()
    guard let shell = engine.shaarDevTools[opened.id] else {
      throw Failure("Second tab did not open its rules shell")
    }
    try await wait("side tab rules", attempts: 100) {
      shell.rules.available && shell.rules.target.tabID == opened.id
    }
    return RulesTab(id: opened.id, shell: shell, inspector: opened.inspector)
  }

  private func installDocumentRule(
    on shell: ShaarDevToolsModel, url: String, marker: String
  ) async throws {
    shell.rules.createNew()
    shell.rules.showingRules = true
    shell.rules.draft?.enabled = true
    shell.rules.draft?.method = "GET"
    shell.rules.draft?.url = url
    shell.rules.draft?.kind = .mock
    shell.rules.draft?.status = 200
    shell.rules.draft?.headers = [
      ShaarNetworkHeader(name: "Content-Type", value: "text/html; charset=utf-8")
    ]
    shell.rules.draft?.bodyText =
      "<!doctype html><meta charset=\"utf-8\"><title>\(marker)</title><p>\(marker)</p>"
    try await shell.rules.saveDraft()
    guard shell.rules.activeCount == 1 else {
      throw Failure("Document rule was not active (\(shell.rules.failure ?? "no error"))")
    }
  }

  private func pageText(using inspector: InspectorModel) async -> String {
    let value = try? await inspector.evaluate("document.body ? document.body.innerText : ''")
    return value as? String ?? ""
  }

  private func waitForMarker(
    _ marker: String, step: String, attempts: Int = 100, tab: UUID, inspector: InspectorModel
  ) async throws -> String {
    var last = ""
    for _ in 0..<attempts {
      if engine.pages[tab]?.loading == false {
        last = await pageText(using: inspector)
        if last.contains(marker) { return last }
      }
      try await Task.sleep(for: .milliseconds(100))
    }
    throw Failure("\(step) did not show \(marker). Saw \(last.prefix(180))")
  }

  private func returnToFixtureTools() async throws {
    try? await disableEnabledRules()
    try await selectOriginalTab()
    try await wait("fixture page after network rules", attempts: 50) {
      self.engine.siteControlTarget?.tabID == self.tab
        && self.engine.siteControlTarget?.url.path == "/inspector-tools"
        && self.shell.rules.target.url.path == "/inspector-tools"
    }
    try await disableEnabledRules()
  }

  private func restoreOriginScope() async throws {
    try await shell.rules.useProjectRoot(nil)
    try await disableEnabledRules()
    guard shell.rules.activeCount == 0 else {
      throw Failure("Origin scope still had \(shell.rules.activeCount) active rules")
    }
  }

  private func retarget(
    status: Int, header: String?, bodyFile: String?, bodyText: String
  ) async throws {
    guard let saved = enabledRule() else { throw Failure("Rule was not saved") }
    shell.rules.edit(saved)
    shell.rules.draft?.status = status
    shell.rules.draft?.headers =
      header.map { [ShaarNetworkHeader(name: "X-Shaar-Mock", value: $0)] } ?? []
    shell.rules.draft?.bodyText = bodyText
    shell.rules.draft?.bodyFilePath = bodyFile
    try await shell.rules.saveDraft()
  }

  private func install(
    from request: ShaarNetworkRequest?, url: String, status: Int, header: String?,
    bodyFile: String?, bodyText: String
  ) async throws {
    if let request {
      shell.rules.create(from: request)
      guard shell.rules.draft?.method == request.method, shell.rules.draft?.url == request.url
      else { throw Failure("Rule draft did not copy the network row") }
    } else {
      shell.rules.createNew()
    }
    shell.rules.draft?.enabled = true
    shell.rules.draft?.method = "GET"
    shell.rules.draft?.url = url
    shell.rules.draft?.kind = .mock
    shell.rules.draft?.status = status
    shell.rules.draft?.headers =
      header.map { [ShaarNetworkHeader(name: "X-Shaar-Mock", value: $0)] } ?? []
    shell.rules.draft?.bodyText = bodyText
    shell.rules.draft?.bodyFilePath = bodyFile
    shell.rules.draft?.redirectURL = ""
    shell.rules.draft?.delayMilliseconds = 0
    try await shell.rules.saveDraft()
  }

  private func fetch(
    _ absolute: String, using inspector: InspectorModel? = nil, step: String
  ) async throws -> DevToolsNetworkRulePageFetch.Receipt {
    let target = inspector ?? self.inspector
    var last = "no attempt"
    for _ in 0..<2 {
      do {
        guard
          let text = try await target.evaluate(
            DevToolsNetworkRulePageFetch.expression(for: absolute)) as? String
        else {
          last = "empty result"
          try await Task.sleep(for: .milliseconds(150))
          continue
        }
        return try DevToolsNetworkRulePageFetch.receipt(from: text)
      } catch {
        last = error.localizedDescription
        try await Task.sleep(for: .milliseconds(150))
      }
    }
    throw Failure("\(step) fetch failed: \(last)")
  }

  private func openSecondTab() async throws -> (id: UUID, inspector: InspectorModel) {
    guard let page = URL(string: absolute("/inspector-tools")) else {
      throw Failure("Could not build the second tab URL")
    }
    store.perform(.open(page))
    try await wait("second tab ready") {
      guard let id = self.store.session.selectedPage?.tab.id, id != self.tab else { return false }
      return self.engine.liveTabs.contains(id) && self.engine.pages[id]?.loading == false
        && self.engine.siteControlTarget?.tabID == id
        && self.engine.runtime.view(forTabID: id.uuidString)?.superview != nil
    }
    guard let id = store.session.selectedPage?.tab.id, id != tab,
      let target = engine.siteControlTarget, target.tabID == id,
      engine.showDeveloperTools(for: target), let inspector = engine.inspectors[id]
    else { throw Failure("Second tab did not open its own Shaar shell") }
    return (id, inspector)
  }

  private func selectOriginalTab() async throws {
    store.perform(.tab(space: space, tab: tab))
    try await wait("original tab selected") {
      self.engine.siteControlTarget?.tabID == self.tab
        && self.engine.pages[self.tab]?.loading == false
    }
  }

  private func disableEnabledRules() async throws {
    try await disableEnabledRules(on: shell)
  }

  private func disableEnabledRules(on shell: ShaarDevToolsModel) async throws {
    let enabled = shell.rules.rules.filter(\.enabled)
    for rule in enabled {
      shell.rules.edit(rule)
      shell.rules.draft?.enabled = false
      try await shell.rules.saveDraft()
    }
  }

  private func enabledRule() -> ShaarNetworkRule? {
    shell.rules.rules.first { $0.enabled }
  }

  private func writeBodyFile() throws -> String {
    let file = root.appending(path: "shaar-rule-body.txt")
    try Data("shaar-file-body".utf8).write(to: file, options: .atomic)
    let path = file.path
    guard URL(fileURLWithPath: path).path == path else {
      throw Failure("Rule file path did not round-trip")
    }
    return path
  }

  private func makeFolder(_ name: String) throws -> String {
    let folder = root.appending(path: name)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder.path
  }

  private func absolute(_ path: String, query: String? = nil) -> String {
    var parts = URLComponents(url: fixture, resolvingAgainstBaseURL: false)
    parts?.path = path
    parts?.query = query
    return parts?.url?.absoluteString ?? ""
  }

  private func isTimestamp(_ body: String) -> Bool {
    !body.isEmpty && body.allSatisfy(\.isNumber)
  }

  private func wait(_ message: String, attempts: Int = 120, _ condition: () -> Bool) async throws {
    for _ in 0..<attempts {
      if condition() { return }
      try await Task.sleep(for: .milliseconds(100))
    }
    throw Failure("Timed out: \(message)")
  }

  private struct Failure: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
  }
}
