// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import BrowserCore
import ChromiumBridge
import Foundation

/// Proves the Network operation column from a window that is never ordered on screen.
@MainActor enum ShaarAPIOperationsProbe {
  static func run(frameworkURL: URL, outputURL: URL, pageURL: URL?) -> Int32 {
    guard let pageURL, pageURL.host == "127.0.0.1", pageURL.scheme == "http" else { return 2 }
    let root = outputURL.deletingLastPathComponent().appending(path: "profile")
    do {
      let workspace = try BrowserWorkspaceStore(
        file: WorkspaceFile(
          url: root.appending(path: "workspace.json"),
          legacySessionURL: root.appending(path: "session.json")))
      let runtime = try ARCShaarRuntime(frameworkURL: frameworkURL)
      let host = NativeBrowserHost(
        events: BrowserRuntimeEvents(runtime: runtime), workspace: workspace,
        presentation: .hiddenProbe)
      runtime.onReady = { [weak host] in
        guard let host else { return }
        NSApp.setActivationPolicy(.prohibited)
        Task {
          await inspect(host: host, runtime: runtime, pageURL: pageURL, outputURL: outputURL)
        }
      }
      return withExtendedLifetime(host) {
        // A hidden window cannot present the login-keychain prompt, so the
        // page never commits. The engine test keychain keeps this probe off
        // the login keychain and lets the loopback document finish loading.
        let code = runtime.run(withDataDirectory: root.appending(path: "Chromium"), testing: true)
        host.detach()
        return code
      }
    } catch {
      write(["error": error.localizedDescription, "passed": false], to: outputURL)
      return 1
    }
  }

  private static func inspect(
    host: NativeBrowserHost, runtime: ARCShaarRuntime, pageURL: URL, outputURL: URL
  ) async {
    defer { host.events.quit() }
    do { try host.restore() } catch {
      write(["error": error.localizedDescription, "passed": false], to: outputURL)
      return
    }
    guard let context = host.contexts.values.first else {
      write(["error": "No hidden browser context", "passed": false], to: outputURL)
      return
    }
    context.store.perform(.open(pageURL))
    guard let target = await committedTarget(context: context, pageURL: pageURL) else {
      let selected = context.engine.siteControlTarget
      let loading = selected.flatMap { context.engine.pages[$0.tabID]?.loading }
      write(
        [
          "error": "No committed web page",
          "passed": false,
          "targetURL": selected?.url.absoluteString ?? "",
          "pageLoading": loading ?? true,
          "pageCount": context.engine.pages.count,
          "allWindowsHidden": windowsHidden(host),
        ], to: outputURL)
      return
    }
    guard context.engine.showDeveloperTools(for: target),
      let shell = context.engine.shaarDevTools[target.tabID]
    else {
      write(["error": "Network has no DevTools shell", "passed": false], to: outputURL)
      return
    }
    await waitForStream(shell)
    shell.section = .network
    await shell.prepareAPICapture()
    let fetchResult = await exercise(
      runtime: runtime, target: target, windowID: context.engine.windowID)
    let rows = await waitForOperations(shell)
    let report = await proof(
      host: host, context: context, shell: shell, rows: rows, fetchResult: fetchResult,
      outputURL: outputURL)
    write(report, to: outputURL)
    shell.close()
  }

  private static func proof(
    host: NativeBrowserHost, context: NativeBrowserContext, shell: ShaarDevToolsModel,
    rows: [ShaarNetworkRequest], fetchResult: String, outputURL: URL
  ) async -> [String: Any] {
    let localGraphQL = rows.first { row in
      row.apiOperation?.name == "Continents" && row.url.contains("127.0.0.1")
    }
    let ping = rows.first { $0.apiOperation?.name == "Ping" }
    let list = rows.first { $0.apiOperation?.name == "post.list" }
    let created = rows.first { $0.apiOperation?.name == "post.create" }
    let publicRow = rows.first { row in
      row.url.contains("countries.trevorblades.com") && row.apiOperation?.name == "Continents"
    }
    shell.network.filter = .api
    shell.network.search = ""
    let apiCount = shell.network.visibleRequests(from: shell.events).count
    shell.network.search = "post.list"
    let searched = shell.network.visibleRequests(from: shell.events).compactMap(
      \.apiOperation?.name)
    shell.network.search = ""
    shell.network.filter = .errors
    let errorNames = shell.network.visibleRequests(from: shell.events).compactMap(
      \.apiOperation?.name)
    shell.network.filter = .all
    if let localGraphQL { shell.network.selectedID = localGraphQL.id }
    shell.dock = .bottom
    let window = context.window
    window.setFrame(NSRect(x: -4000, y: -2400, width: 1440, height: 900), display: false)
    window.orderOut(nil)
    context.hosting.needsLayout = true
    context.hosting.layoutSubtreeIfNeeded()
    try? await Task.sleep(for: .milliseconds(400))
    let image = outputURL.deletingLastPathComponent().appending(path: "network-operations.png")
    let captured = ShaarDevToolsSmokeAccess.capture(context.hosting, to: image)
    let hidden = windowsHidden(host)
    let localOK =
      localGraphQL?.apiOperation?.callType == .query
      && localGraphQL?.apiOperation?.hasErrors == true
      && ping?.apiOperation?.callType == .query
      && list?.apiOperation?.callType == .query
      && created?.apiOperation?.callType == .mutation
      && created?.apiOperation?.hasErrors == true
      && apiCount >= 4
      && searched == ["post.list"]
      && errorNames.contains("Continents")
    let passed = localOK && hidden && captured && shell.apiCaptureInstalled
    return [
      "passed": passed,
      "normalBundle": Bundle.main.bundleIdentifier ?? "",
      "allWindowsHidden": hidden,
      "apiCaptureInstalled": shell.apiCaptureInstalled,
      "streamFailure": shell.nativeStreamFailure ?? "",
      "fetchResult": fetchResult,
      "operations": rows.compactMap { summary($0) },
      "apiFilterCount": apiCount,
      "searchMatched": searched,
      "errorNames": errorNames,
      "publicContinents": publicRow != nil,
      "publicCallType": publicRow?.apiOperation?.callType.rawValue ?? "",
      "screenshot": captured,
      "targetURL": context.engine.siteControlTarget?.url.absoluteString ?? "",
    ]
  }

  private static func summary(_ row: ShaarNetworkRequest) -> [String: Any]? {
    guard let operation = row.apiOperation else { return nil }
    return [
      "name": operation.name,
      "callType": operation.callType.rawValue,
      "kind": operation.kind.rawValue,
      "hasErrors": operation.hasErrors,
      "method": row.method,
      "url": row.url,
      "status": row.status ?? 0,
    ]
  }

  private static func waitForOperations(_ shell: ShaarDevToolsModel) async
    -> [ShaarNetworkRequest]
  {
    var latest: [ShaarNetworkRequest] = []
    for _ in 0..<48 {
      shell.network.filter = .all
      shell.network.search = ""
      latest = shell.network.visibleRequests(from: shell.events).filter { $0.apiOperation != nil }
      let names = Set(latest.compactMap(\.apiOperation?.name))
      let localError = latest.contains { row in
        row.apiOperation?.name == "Continents" && row.url.contains("127.0.0.1")
          && row.apiOperation?.hasErrors == true
      }
      let ready =
        localError && names.contains("Ping") && names.contains("post.list")
        && names.contains("post.create")
      if ready { return latest }
      try? await Task.sleep(for: .milliseconds(250))
    }
    return latest
  }

  private static func exercise(
    runtime: ARCShaarRuntime, target: SiteControlTarget, windowID: String
  ) async -> String {
    do {
      let result = try await runtime.developerCall(
        "Runtime.evaluate",
        params: [
          "expression": exerciseScript,
          "returnByValue": true,
          "awaitPromise": true,
          "timeout": 20_000,
        ],
        tabID: target.tabID.uuidString, profileID: target.profileID.uuidString,
        windowID: windowID)
      if result["exceptionDetails"] != nil { return "exception" }
      return ((result["result"] as? [String: Any])?["value"] as? String) ?? ""
    } catch {
      return error.localizedDescription
    }
  }

  private static func committedTarget(
    context: NativeBrowserContext, pageURL: URL
  ) async -> SiteControlTarget? {
    for _ in 0..<300 {
      if let target = context.engine.siteControlTarget,
        target.url == pageURL,
        context.engine.pages[target.tabID]?.loading == false
      {
        return target
      }
      try? await Task.sleep(for: .milliseconds(100))
    }
    return nil
  }

  private static func waitForStream(_ shell: ShaarDevToolsModel) async {
    for _ in 0..<100 {
      if shell.streamAvailable || shell.nativeStreamFailure != nil { return }
      try? await Task.sleep(for: .milliseconds(100))
    }
  }

  private static func windowsHidden(_ host: NativeBrowserHost) -> Bool {
    host.contexts.values.allSatisfy { !$0.window.isVisible }
  }

  private static func write(_ report: [String: Any], to url: URL) {
    guard
      let data = try? JSONSerialization.data(
        withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
    else { return }
    try? data.write(to: url, options: .atomic)
  }

  private static let exerciseScript = #"""
      (async () => {
        const results = [];
        async function hit(name, url, init) {
          const attempt = (async () => {
            try {
              const response = await fetch(url, init);
              return String(response.status);
            } catch (error) {
              return "failed";
            }
          })();
          const timeout = new Promise(resolve => setTimeout(() => resolve("timeout"), 8000));
          const status = await Promise.race([attempt, timeout]);
          results.push(name + ":" + status);
        }
        const graphql = {
          method: "POST",
          headers: { "content-type": "application/json" },
          body: JSON.stringify({
            query: "query Continents { continents { code } }",
            operationName: "Continents",
            variables: { secret: "do-not-keep" }
          })
        };
        const created = {
          method: "POST",
          headers: { "content-type": "application/json" },
          body: "{}"
        };
        const publicCall = {
          method: "POST",
          headers: { "content-type": "application/json" },
          body: JSON.stringify({
            query: "query Continents { continents { code } }",
            operationName: "Continents"
          })
        };
        await Promise.all([
          hit("graphql", new URL("/graphql", location.href).href, graphql),
          hit("ping", new URL("/graphql?operationName=Ping&query=" + encodeURIComponent("query Ping { __typename }"), location.href).href, { method: "GET" }),
          hit("list", new URL("/api/trpc/post.list?batch=1", location.href).href, { method: "GET" }),
          hit("create", new URL("/api/trpc/post.create", location.href).href, created),
          hit("public", "https://countries.trevorblades.com/", publicCall)
        ]);
        return results.join(",");
      })()
    """#
}
