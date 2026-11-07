// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

@testable import ArcusisBrowser

/// Confirms a real 5 MiB same-origin script survives the Inspector fallback.
@MainActor struct DevToolsSourceBytesProof {
  nonisolated static let byteCount = 5 * 1024 * 1024
  let shell: ShaarDevToolsModel
  let inspector: InspectorModel
  let fixture: URL

  func run() async throws -> String {
    let address = DevToolsPanelResults.fixtureURL("/scale-source.js", from: fixture).absoluteString
    try await loadScript()
    _ = try await scriptResource(address)
    let loaded: (body: String, base64Encoded: Bool)
    do {
      loaded = try await ShaarInspectorSourceLoader.load(
        url: address, target: shell.phase2.target, inspector: inspector)
    } catch {
      let seen = await listedResourceURLs()
      throw Failure(
        "Inspector fallback failed: \(error.localizedDescription). Resource tree: \(seen)")
    }
    guard Self.isScaleSource(loaded.body), loaded.base64Encoded == false else {
      let prefix = String(loaded.body.prefix(24))
      throw Failure(
        "Inspector body was \(loaded.body.utf8.count) bytes, encoded=\(loaded.base64Encoded), prefix=\(prefix)"
      )
    }
    return
      "Phase 2 resource list included /scale-source.js. Inspector Page.getResourceContent delivered \(Self.byteCount) bytes."
  }

  nonisolated static func isScaleSource(_ content: String, byteCount: Int = byteCount) -> Bool {
    let prefix = "/* shaar-scale-source\n"
    let suffix = "\nshaar-scale-end */\n"
    guard content.utf8.count == byteCount, content.hasPrefix(prefix), content.hasSuffix(suffix)
    else { return false }
    return content.dropFirst(prefix.count).dropLast(suffix.count).allSatisfy { $0 == "x" }
  }

  private func loadScript() async throws {
    guard
      let loaded = try await inspector.evaluate(
        """
        (async () => {
          await new Promise((resolve, reject) => {
            const script = document.createElement('script');
            script.src = '/scale-source.js';
            script.onload = () => resolve('loaded');
            script.onerror = () => reject(new Error('scale source failed'));
            document.head.appendChild(script);
          });
          return 'loaded';
        })()
        """
      ) as? String,
      loaded == "loaded"
    else { throw Failure("The page did not load /scale-source.js") }
  }

  private func scriptResource(_ address: String) async throws -> ShaarSourceResource {
    var seen = ""
    for _ in 0..<8 {
      try await waitForPhase2()
      await shell.sources.refresh()
      if let resource = shell.sources.resources.first(where: { $0.url == address }) {
        return resource
      }
      seen = shell.sources.resources.prefix(8).map(\.url).joined(separator: ", ")
      try await Task.sleep(for: .milliseconds(150))
    }
    throw Failure("5 MiB script missing from the resource tree. Saw \(seen)")
  }

  private func listedResourceURLs() async -> String {
    do {
      let tree = try await inspector.call("Page.getResourceTree")
      return Self.resourceURLs(in: tree).prefix(8).joined(separator: ", ")
    } catch {
      return "unavailable: \(error.localizedDescription)"
    }
  }

  private static func resourceURLs(in reply: [String: Any]) -> [String] {
    guard let root = reply["frameTree"] as? [String: Any] else { return [] }
    var urls: [String] = []
    appendResourceURLs(in: root, depth: 0, into: &urls)
    return urls
  }

  private static func appendResourceURLs(
    in tree: [String: Any], depth: Int, into urls: inout [String]
  ) {
    guard depth < 8 else { return }
    let resources = tree["resources"] as? [[String: Any]] ?? []
    for resource in resources.prefix(32) {
      if let url = resource["url"] as? String { urls.append(url) }
    }
    for child in (tree["childFrames"] as? [[String: Any]] ?? []).prefix(8) {
      appendResourceURLs(in: child, depth: depth + 1, into: &urls)
    }
  }

  private func waitForPhase2() async throws {
    for _ in 0..<40 {
      if shell.phase2.available { return }
      try await Task.sleep(for: .milliseconds(100))
    }
    throw Failure("Phase 2 lease was not available for the 5 MiB source")
  }

  private struct Failure: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
  }
}
