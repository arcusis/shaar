// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

@testable import ArcusisBrowser

/// Drives the production Application model against one inspected tab.
@MainActor struct ApplicationStorageProof {
  let application: ShaarApplicationModel
  let phase2: ShaarPhase2Model
  let inspector: InspectorModel

  func local() async throws -> String {
    try await prepare()
    try await proveStorage(
      area: .local, originalKey: "inspector-key", originalValue: "original",
      probeKey: "shaar-probe", read: "localStorage.getItem('shaar-probe')")
    return "Local Storage listed inspector-key, edited shaar-probe, and deleted it"
  }

  func session() async throws -> String {
    try await prepare()
    try await proveStorage(
      area: .session, originalKey: "session-key", originalValue: "session-original",
      probeKey: "shaar-session-probe", read: "sessionStorage.getItem('shaar-session-probe')")
    return "Session Storage listed session-key, edited shaar-session-probe, and deleted it"
  }

  func indexedDB() async throws -> String {
    try await prepare()
    application.selectArea(.indexedDB)
    await application.refresh()
    guard row("shaar-notes") != nil else { throw fail("IndexedDB database missing") }
    application.selectDatabase("shaar-notes")
    await application.refresh()
    guard row("entries") != nil else { throw fail("IndexedDB object store missing") }
    application.selectStore("entries")
    await application.refresh()
    guard application.rows.count == 50, application.hasMore,
      application.rows.first?.name == "id-000", application.rows.first?.value == "value-000"
    else {
      throw fail(
        "IndexedDB first page count=\(application.rows.count) hasMore=\(application.hasMore)")
    }
    await application.loadMore()
    guard application.rows.count == 60, !application.hasMore,
      application.rows.last?.name == "id-059", application.rows.last?.value == "value-059"
    else {
      throw fail(
        "IndexedDB second page count=\(application.rows.count) hasMore=\(application.hasMore)")
    }
    return "IndexedDB listed shaar-notes/entries and paged 60 records"
  }

  func cache() async throws -> String {
    try await prepare()
    application.selectArea(.cache)
    await application.refresh()
    guard let cache = row("shaar-app") else { throw fail("Cache shaar-app missing") }
    application.selectCache(cache.id)
    await application.refresh()
    guard let entry = application.rows.first(where: { $0.name.contains("inspector-cached.txt") })
    else { throw fail("Cached request missing") }
    application.selectCacheEntry(entry.name)
    await application.refresh()
    guard application.body == "shaar-cached-body", application.bodyEncoded == false else {
      throw fail("Cached response was not readable text")
    }
    return "Cache Storage listed shaar-app and read inspector-cached.txt"
  }

  func serviceWorker() async throws -> String {
    try await prepare()
    guard
      let scope = try await pageString(
        "navigator.serviceWorker.register('/inspector-sw.js').then(registration => registration.scope)"
      )
    else { throw fail("Service worker did not register") }
    application.selectArea(.workers)
    try await waitUntil("service worker activated", attempts: 200) {
      await self.application.refresh()
      return self.application.workers.contains { worker in
        worker.scopeURL == scope && worker.status == "activated" && !worker.scriptURL.isEmpty
      }
    }
    guard let listed = application.workers.first(where: { $0.scopeURL == scope }) else {
      throw fail("Activated service worker disappeared")
    }
    let generation = try await pageString(
      "fetch('/inspector-sw-bump',{cache:'no-store'}).then(response => response.text())")
    guard let generation, let version = Int(generation), version >= 2 else {
      throw fail("Service worker script bump returned \(generation ?? "nothing")")
    }
    let eventsBefore = phase2.events.count
    await application.updateWorker(listed)
    if let failure = application.failure { throw fail("Update failed: \(failure)") }
    try await waitUntil("service worker update", attempts: 200) {
      self.phase2.events.count > eventsBefore && self.application.failure == nil
    }
    await application.refresh()
    guard let current = application.workers.first(where: { $0.scopeURL == scope }) else {
      throw fail("Updated service worker disappeared")
    }
    await application.unregisterWorker(current)
    if let failure = application.failure { throw fail("Unregister failed: \(failure)") }
    try await waitUntil("service worker unregistered", attempts: 200) {
      await self.application.refresh()
      let listed = self.application.workers.contains { $0.scopeURL == scope }
      let page = try? await self.pageString(
        "navigator.serviceWorker.getRegistration().then(registration => registration ? registration.scope : 'none')"
      )
      return !listed && page == "none"
    }
    return "Service worker \(scope) listed, updated to generation \(version), and unregistered"
  }

  private func prepare() async throws {
    try await requireCapability()
    try await requireSeed()
  }

  private func requireCapability() async throws {
    for _ in 0..<80 {
      if phase2.available { return }
      try await Task.sleep(for: .milliseconds(100))
    }
    throw fail("Application capability did not connect")
  }

  private func requireSeed() async throws {
    for _ in 0..<80 {
      let status =
        try? await pageString(
          "window.shaarApplicationError || (window.shaarApplicationReady ? 'ready' : 'pending')")
      if status == "ready" { return }
      if let status, status != "pending" {
        throw ProofError("Application fixture did not seed: \(status)")
      }
      try await Task.sleep(for: .milliseconds(100))
    }
    throw ProofError("Timed out waiting for IndexedDB and Cache Storage seed")
  }

  private func proveStorage(
    area: ShaarApplicationArea, originalKey: String, originalValue: String,
    probeKey: String, read: String
  ) async throws {
    application.selectArea(area)
    await application.refresh()
    guard row(originalKey)?.value == originalValue else { throw fail("Missing \(originalKey)") }
    await application.saveStorage(key: probeKey, value: "written")
    guard row(probeKey)?.value == "written" else { throw fail("Write did not list \(probeKey)") }
    guard try await pageString(read) == "written" else {
      throw fail("Write did not reach the page")
    }
    await application.saveStorage(key: probeKey, value: "edited")
    guard row(probeKey)?.value == "edited" else { throw fail("Edit did not list \(probeKey)") }
    guard try await pageString(read) == "edited" else { throw fail("Edit did not reach the page") }
    await application.removeStorage(key: probeKey)
    guard row(probeKey) == nil else { throw fail("Delete left \(probeKey) in the list") }
    guard try await pageString("\(read) === null ? 'gone' : 'kept'") == "gone" else {
      throw fail("Delete left \(probeKey) in the page")
    }
    guard row(originalKey)?.value == originalValue else {
      throw fail("Original \(originalKey) was lost")
    }
  }

  private func row(_ name: String) -> ShaarApplicationRow? {
    application.rows.first { $0.name == name }
  }

  private func pageString(_ expression: String) async throws -> String? {
    try await inspector.evaluate(expression) as? String
  }

  private func waitUntil(
    _ message: String, attempts: Int, _ condition: () async throws -> Bool
  ) async throws {
    for _ in 0..<attempts {
      if try await condition() { return }
      try await Task.sleep(for: .milliseconds(100))
    }
    throw fail("Timed out: \(message)")
  }

  private func fail(_ message: String) -> ProofError {
    let rows = application.rows.prefix(6).map { "\($0.name)=\($0.value)" }.joined(separator: ", ")
    let workers = application.workers.map { "\($0.scopeURL) [\($0.status)]" }.joined(
      separator: ", ")
    let modelError = application.failure ?? "no model error"
    let transportError = phase2.nativeFailure ?? "no transport error"
    let summary = [
      message, modelError, transportError, "available=\(phase2.available)",
      "rows=\(rows)", "workers=\(workers)",
    ].joined(separator: ". ")
    return ProofError(summary)
  }

  private struct ProofError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
  }
}
