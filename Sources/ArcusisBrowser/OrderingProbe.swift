import AppKit
import BrowserCore
import ChromiumBridge
import SwiftUI

private struct OrderingIdentities: Codable {
  let source: UUID
  let destination: UUID
  let tabs: [UUID]
}

/// Checks the same move APIs used by native drop destinations and context menus.
@MainActor
final class OrderingProbe {
  let runtime: ARCChromiumRuntime
  let engine: BrowserEngine
  let store: BrowserStore
  let root: URL
  let phase: String
  private var checks: [String] = []
  private var previewWindow: NSWindow?
  private var popupWindow: NSWindow?

  init(
    runtime: ARCChromiumRuntime, engine: BrowserEngine, store: BrowserStore, root: URL,
    phase: String
  ) {
    self.runtime = runtime
    self.engine = engine
    self.store = store
    self.root = root
    self.phase = phase
  }

  func run() async throws -> [String] {
    do {
      let result = try await exercise()
      try report(error: nil)
      return result
    } catch {
      engine.extensionPanel = nil
      let profile = store.session.spaces[0].profileID
      let tabs = orderedTabs(profile)
      _ = runtime.placeTabIDs(
        tabs.map { $0.id.uuidString }, pinnedIDs: tabs.filter(\.isPinned).map { $0.id.uuidString },
        profileID: profile.uuidString)
      try? report(error: error)
      throw error
    }
  }

  private func exercise() async throws -> [String] {
    let base = store.session.spaces[0]
    let other = store.session.spaces[1]
    let fixture = base.selectedTab!.url
    let file = root.appending(path: "ordering-identities.json")
    let identities: OrderingIdentities
    if phase == "initial" {
      guard store.createSpace(name: "Ordering source", sharingProfile: base.profileID, tint: .ocean)
      else { throw OrderingFailure("Could not create source space.") }
      let source = store.session.selectedSpaceID
      var tabs: [UUID] = []
      for _ in 0..<3 {
        store.perform(.open(fixture))
        tabs.append(store.session.selectedSpace.selectedTabID!)
      }
      guard
        store.createSpace(
          name: "Ordering destination", sharingProfile: base.profileID, tint: .forest)
      else { throw OrderingFailure("Could not create destination space.") }
      let destination = store.session.selectedSpaceID
      for _ in 0..<2 {
        store.perform(.open(fixture))
        tabs.append(store.session.selectedSpace.selectedTabID!)
      }
      identities = OrderingIdentities(source: source, destination: destination, tabs: tabs)
      try JSONEncoder().encode(identities).write(to: file, options: .atomic)
    } else {
      identities = try JSONDecoder().decode(OrderingIdentities.self, from: Data(contentsOf: file))
      let source = try space(identities.source)
      let destination = try space(identities.destination)
      try expect(
        source.tabs.map(\.id) == [identities.tabs[1], identities.tabs[0]],
        "source tab ordering survives restart")
      try expect(source.tabs.first?.isPinned == true, "pin state survives restart")
      try expect(
        destination.tabs.map(\.id) == [identities.tabs[3], identities.tabs[2], identities.tabs[4]],
        "destination tab ordering survives restart")
      try expect(
        store.session.spaces.firstIndex { $0.id == destination.id }! < store.session.spaces
          .firstIndex { $0.id == source.id }!, "space ordering survives restart")
    }
    let ids = identities.tabs
    var before: [UUID: NSDictionary] = [:]
    let tracked = ids + [base.selectedTabID!, other.selectedTabID!]
    let nativeIDs = tracked.map { runtime.nativeTabID(forID: $0.uuidString) }
    for id in tracked { before[id] = try await document(id) as NSDictionary }
    for (id, title) in zip(ids, ["Planning", "Reference", "Review", "Research", "Team notes"]) {
      let literal = String(data: try JSONEncoder().encode(title), encoding: .utf8)!
      let _: String? = await withCheckedContinuation { continuation in
        runtime.evaluate(
          inTabID: id.uuidString, script: "(()=>{document.title=\(literal);return true;})()"
        ) {
          continuation.resume(returning: $0)
        }
      }
    }

    if phase == "restart" {
      try expect(
        store.moveTab(ids[2], from: identities.destination, to: identities.source),
        "restored live tab can return to its original shared-profile space")
      store.perform(.space(identities.source))
      store.togglePin(ids[1])
      for id in ids.prefix(3).reversed() {
        if let first = store.session.selectedSpace.tabs.first?.id, first != id {
          _ = store.moveTab(id, from: identities.source, to: identities.source, before: first)
        }
      }
      _ = store.moveSpace(identities.source, before: identities.destination)
    }
    store.perform(.tab(space: identities.source, tab: ids[2]))
    try expect(
      store.moveTab(ids[1], from: identities.source, to: identities.source, before: ids[0]),
      "native store reorders an existing tab")
    store.togglePin(ids[1])
    try expect(
      store.moveTab(ids[2], from: identities.source, to: identities.destination, before: ids[4]),
      "native store moves a tab between explicitly shared spaces")
    try expect(
      store.session.selectedSpaceID == identities.destination
        && store.session.selectedSpace.selectedTabID == ids[2],
      "selected live document follows its move to the destination space")
    try expect(
      store.moveSpace(identities.destination, before: identities.source),
      "native store persists reordered spaces")
    let rejected = store.session
    try expect(
      !store.moveTab(ids[2], from: identities.destination, to: other.id),
      "cross-profile move is rejected")
    try expect(
      store.session == rejected,
      "rejected move preserves all accounts, selections, and tab identities")
    store.perform(.space(identities.destination))
    for (index, id) in tracked.enumerated() {
      let after = try await document(id) as NSDictionary
      try expect(
        after == before[id], "reordering retains live document and account storage \(index + 1)")
      try expect(
        runtime.nativeTabID(forID: id.uuidString) == nativeIDs[index],
        "native Chromium tab identity remains unchanged \(index + 1)")
    }
    let expected = orderedTabs(base.profileID)
    try await verifyNativeOrder(
      expected, profile: base.profileID, label: "Chromium extension API sees model order and pins")
    // Exercise the multi-unpin transition independently of per-click UI updates.
    let native = expected.map { $0.id.uuidString }
    try expect(
      runtime.placeTabIDs(native, pinnedIDs: native, profileID: base.profileID.uuidString),
      "native bridge accepts a valid all-pinned ordering")
    try expect(
      runtime.placeTabIDs(
        native, pinnedIDs: expected.filter(\.isPinned).map { $0.id.uuidString },
        profileID: base.profileID.uuidString),
      "native bridge restores mixed pin states without scrambling indices")
    try await verifyNativeOrder(
      expected, profile: base.profileID,
      label: "native order remains correct after unpinning several tabs together")
    try expect(
      !runtime.placeTabIDs(
        [ids[2].uuidString], pinnedIDs: [], profileID: other.profileID.uuidString),
      "native bridge rejects another profile's tab")
    let saved = try SessionFile(url: root.appending(path: "session.json")).load()
    try expect(
      saved == store.session,
      "saved session contains current order, ownership, pins, and selections")
    try await capture(name: "\(phase)-ordering.png", compact: false)
    try await capture(name: "\(phase)-ordering-compact.png", compact: true)
    store.perform(.space(base.id))
    return checks
  }

  private func space(_ id: UUID) throws -> BrowserSpace {
    guard let space = store.session.spaces.first(where: { $0.id == id }) else {
      throw OrderingFailure("Ordering fixture space was lost.")
    }
    return space
  }

  private func orderedTabs(_ profile: UUID) -> [BrowserTab] {
    let tabs = store.session.spaces.filter { $0.profileID == profile }.flatMap(\.tabs)
    return tabs.filter(\.isPinned) + tabs.filter { !$0.isPinned }
  }

  private func document(_ tab: UUID) async throws -> [String: Any] {
    for _ in 0..<80 {
      let json: String? = await withCheckedContinuation { continuation in
        runtime.evaluate(
          inTabID: tab.uuidString,
          script:
            "({fixture:document.documentElement.dataset.arcusisFixture,instance:window.arcusisInstance,cookie:document.cookie,local:localStorage.getItem('account'),session:sessionStorage.getItem('account')})"
        ) { continuation.resume(returning: $0) }
      }
      if let data = json?.data(using: .utf8),
        let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        value["fixture"] as? String == "v1"
      {
        return value
      }
      try await Task.sleep(for: .milliseconds(100))
    }
    throw OrderingFailure("Ordering document was not ready.")
  }

  private func verifyNativeOrder(_ expected: [BrowserTab], profile: UUID, label: String)
    async throws
  {
    engine.refreshExtensions()
    guard let fixture = engine.extensions.first(where: { $0.name == "Account isolation probe" })
    else { throw OrderingFailure("Ordering extension fixture is unavailable.") }
    engine.executeExtension(fixture.id)
    guard case .popup(let popup) = engine.extensionPanel else {
      throw OrderingFailure("Ordering extension popup did not open.")
    }
    defer { engine.extensionPanel = nil }
    if let page = runtime.view(forExtensionPopupID: popup.id) {
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 420, height: 560), styleMask: .borderless,
        backing: .buffered, defer: false)
      window.contentView = page
      popupWindow = window
    }
    for _ in 0..<50 {
      if await popupValue(popup.id, "typeof window.probeCommand==='function'") as? Bool == true {
        break
      }
      try await Task.sleep(for: .milliseconds(100))
    }
    _ = await popupValue(
      popup.id,
      "(()=>{window.orderReply=null;window.probeCommand({action:'order'}).then(v=>window.orderReply=v).catch(e=>window.orderReply={error:String(e)});return true;})()"
    )
    for _ in 0..<50 {
      if let result = await popupValue(popup.id, "window.orderReply") as? [String: Any] {
        guard let tabs = result["tabs"] as? [[String: Any]], result["error"] == nil else {
          throw OrderingFailure("Extension tab-order query failed: \(result)")
        }
        let expectedIDs = expected.map { runtime.nativeTabID(forID: $0.id.uuidString) }
        let actualIDs = tabs.compactMap { ($0["id"] as? NSNumber)?.int32Value }
        let pins = tabs.compactMap { $0["pinned"] as? Bool }
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
          .write(to: root.appending(path: "\(phase)-native-order.json"), options: .atomic)
        try expect(actualIDs == expectedIDs && pins == expected.map(\.isPinned), label)
        try expect(
          result["account"] as? String == "alpha",
          "ordering inspection stays in the owning extension profile")
        try expect(
          (result["tabID"] as? NSNumber)?.int32Value
            == store.session.selectedSpace.selectedTabID.map {
              runtime.nativeTabID(forID: $0.uuidString)
            },
          "extension actions retain the selected document after ordering")
        return
      }
      try await Task.sleep(for: .milliseconds(100))
    }
    throw OrderingFailure("Extension tab-order query timed out.")
  }

  private func popupValue(_ id: String, _ script: String) async -> Any? {
    let json: String? = await withCheckedContinuation { continuation in
      runtime.evaluateProbePopupID(id, script: script) { continuation.resume(returning: $0) }
    }
    return json.flatMap { $0.data(using: .utf8) }.flatMap {
      try? JSONSerialization.jsonObject(with: $0, options: [.fragmentsAllowed])
    }
  }

  private func capture(name: String, compact: Bool) async throws {
    let size = compact ? NSSize(width: 760, height: 520) : NSSize(width: 1200, height: 780)
    let host = NSHostingView(
      rootView: BrowserWindow(store: store).frame(width: size.width, height: size.height))
    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered,
      defer: false)
    window.contentView = host
    previewWindow = window
    try await Task.sleep(for: .milliseconds(100))
    host.layoutSubtreeIfNeeded()
    guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
      throw OrderingFailure("Ordering layout could not be rendered.")
    }
    host.cacheDisplay(in: host.bounds, to: bitmap)
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
      throw OrderingFailure("Ordering layout could not be encoded.")
    }
    try png.write(to: root.appending(path: name), options: .atomic)
  }

  private func expect(_ condition: Bool, _ message: String) throws {
    guard condition else { throw OrderingFailure(message) }
    checks.append(message)
  }

  private func report(error: Error?) throws {
    try JSONSerialization.data(
      withJSONObject: [
        "passed": error == nil, "checks": checks, "phase": phase,
        "error": error?.localizedDescription as Any? ?? NSNull(),
        "scope":
          "Real-engine model/drop-handler moves and extension-visible tab order. Native drag gestures and context-menu input remain unverified.",
      ],
      options: [.prettyPrinted, .sortedKeys]
    ).write(to: root.appending(path: "\(phase)-ordering.json"), options: .atomic)
  }
}

private struct OrderingFailure: LocalizedError {
  let message: String
  init(_ message: String) { self.message = message }
  var errorDescription: String? { message }
}
