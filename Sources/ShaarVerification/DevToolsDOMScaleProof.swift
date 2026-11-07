// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

@testable import ArcusisBrowser

/// Inserts 20,000 live spans on BODY, whose children the Elements stream already requested.
@MainActor struct DevToolsDOMScaleProof {
  static let nodeCount = 20_000
  static let batchSize = 64
  let shell: ShaarDevToolsModel
  let inspector: InspectorModel

  func run() async throws -> String {
    await shell.releasePageMask()
    try await waitForMaskRemoval()
    try await prepareBody()
    var added = 0
    while added < Self.nodeCount {
      let count = min(Self.batchSize, Self.nodeCount - added)
      let floor = shell.dom.nodes.count
      try await insertBatch(from: added, count: count)
      try await waitFor("shaar-scale-\(added + count - 1)", holding: floor)
      added += count
    }
    let held = shell.dom.nodes.count
    guard held >= Self.nodeCount, contains("shaar-scale-\(Self.nodeCount - 1)") else {
      throw Failure(status("Elements stream held \(held) nodes"))
    }
    let rows = shell.dom.rows.count
    return "Elements held \(held) live nodes and \(Self.nodeCount) spans (rows \(rows))."
  }

  private func waitForMaskRemoval() async throws {
    var previous = shell.dom.nodes.count
    var stable = 0
    for _ in 0..<25 {
      try await Task.sleep(for: .milliseconds(40))
      let count = shell.dom.nodes.count
      if maskIsPresent || count != previous {
        stable = 0
        previous = count
        continue
      }
      stable += 1
      if stable == 3 { return }
    }
    if maskIsPresent {
      throw Failure(status("Repro mask style was still in the Elements tree"))
    }
  }

  private var maskIsPresent: Bool {
    shell.dom.nodes.values.contains { node in
      node.attributes.contains { $0.name == "id" && $0.value == "shaar-repro-mask" }
    }
  }

  private func prepareBody() async throws {
    try await wait("live DOM tree for scale", holding: 0) {
      self.shell.dom.available && self.shell.dom.rootID != nil && !self.shell.dom.loading
    }
    guard let body = shell.dom.nodes.values.first(where: { $0.name == "BODY" }) else {
      throw Failure("Scale document did not include BODY")
    }
    if !shell.dom.expanded.contains(body.id) {
      await shell.dom.toggleExpanded(body.id)
    }
    try await wait("BODY ready for scale", holding: 0) {
      self.shell.dom.nodes[body.id] != nil && !self.shell.dom.loading
    }
  }

  private func insertBatch(from start: Int, count: Int) async throws {
    let value = try await inspector.evaluate(Self.batchExpression(from: start, count: count))
    guard wholeNumber(value) == count else {
      throw Failure(status("Scale batch at \(start) did not reach the page"))
    }
  }

  private func waitFor(_ identifier: String, holding minimum: Int) async throws {
    try await wait(identifier, holding: minimum) { self.contains(identifier) }
  }

  private func contains(_ identifier: String) -> Bool {
    shell.dom.nodes.values.contains { node in
      node.attributes.contains { $0.name == "id" && $0.value == identifier }
    }
  }

  private func wait(
    _ message: String, holding minimum: Int, _ condition: () -> Bool
  ) async throws {
    for _ in 0..<25 {
      if minimum > 0, shell.dom.nodes.count < minimum {
        throw Failure(status("Elements tree reloaded during \(message)"))
      }
      if condition() { return }
      try await Task.sleep(for: .milliseconds(40))
    }
    throw Failure(status("Timed out: \(message)"))
  }

  private func status(_ message: String) -> String {
    let failure = shell.dom.failure ?? "none"
    return "\(message). Nodes \(shell.dom.nodes.count). Failure \(failure)"
  }

  private func wholeNumber(_ value: Any?) -> Int? {
    if let value = value as? Int { return value }
    guard let value = value as? Double, value.rounded() == value else { return nil }
    return Int(value)
  }

  private static func batchExpression(from start: Int, count: Int) -> String {
    """
    (() => {
      let added = 0;
      const start = \(start);
      for (let index = 0; index < \(count); index += 1) {
        const span = document.createElement('span');
        span.id = 'shaar-scale-' + (start + index);
        document.body.appendChild(span);
        added += 1;
      }
      return added;
    })()
    """
  }

  private struct Failure: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
  }
}
