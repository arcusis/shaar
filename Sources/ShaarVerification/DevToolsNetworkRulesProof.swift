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
      return "\(fromRow) \(disabled) \(otherTab) \(project)"
    } catch {
      try? await restoreOriginScope()
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
