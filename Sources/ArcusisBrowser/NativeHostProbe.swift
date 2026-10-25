import AppKit
import BrowserCore
import Darwin
import SwiftUI

private struct HostProbeSelection: Codable, Equatable {
  let space: UUID
  let tab: UUID?

  init(_ session: BrowserSession) {
    space = session.selectedSpaceID
    tab = session.selectedSpace.selectedTabID
  }
}

private struct HostProbeIdentity: Codable {
  let first: UUID
  let second: UUID
  let firstTab: UUID
  let secondTab: UUID
  let ordinarilyClosed: [UUID]
  var engineWindow: UUID? = nil
  var engineTab: UUID? = nil
  var restorationSelections: [UUID: HostProbeSelection]? = nil
}

/// Exercises the production host class without ordering windows onscreen or sending OS input.
@MainActor
final class NativeHostProbe {
  let primary: BrowserEngine
  let store: BrowserStore
  let root: URL
  let fixture: URL
  let phase: String
  private let lock: WorkspaceProcessLock
  private let file: WorkspaceFile
  private var host: NativeBrowserHost?
  private var focused: NSWindow?
  private var closures: [UUID: Bool] = [:]
  private var checks: [String] = []
  private var expectedAfterQuit: BrowserWorkspace?

  init(primary: BrowserEngine, store: BrowserStore, root: URL, fixture: URL, phase: String) throws {
    self.primary = primary
    self.store = store
    self.root = root
    self.fixture = fixture
    self.phase = phase
    let directory = root.appending(path: "host-workspace")
    lock = try WorkspaceProcessLock(directory: directory)
    file = WorkspaceFile(
      url: directory.appending(path: "workspace.json"),
      legacySessionURL: directory.appending(path: "session.json"))
  }

  func run() async throws -> [String] {
    do {
      try await exercise()
      try report(error: nil)
      return checks
    } catch {
      try? report(error: error)
      throw error
    }
  }

  private func exercise() async throws {
    try await verifyParentLock()
    let bases = Array(store.session.spaces.prefix(2))
    if phase == "initial" {
      let spaces = bases.enumerated().map { index, base in
        BrowserSpace(
          profileID: base.profileID, name: "Host \(index == 0 ? "alpha" : "beta")",
          symbol: base.symbol,
          tint: base.tint, tabs: [BrowserTab(url: fixture.appending(path: "host-initial-\(index)"))]
        )
      }
      try SessionFile(url: file.legacySessionURL).save(
        BrowserSession(
          profiles: store.session.profiles.filter { bases.map(\.profileID).contains($0.id) },
          spaces: spaces, selectedSpaceID: spaces[0].id))
    }
    let legacy = try Data(contentsOf: file.legacySessionURL)
    let manager = try BrowserWorkspaceStore(file: file)
    let host = NativeBrowserHost(
      events: primary.events, workspace: manager, presentation: .hiddenProbe,
      usesPrimaryWindow: false,
      keyWindow: { [weak self] in self?.focused },
      screens: { [NSRect(x: 0, y: 0, width: 1920, height: 1080)] })
    self.host = host
    host.onClosed = { [weak self] id, quitting in self?.closures[id] = quitting }
    try host.restore()
    let checkpoint = root.appending(path: "host-identities.json")
    var firstID: UUID
    var secondID: UUID
    var closedIDs: [UUID] = []
    if phase == "initial" {
      firstID = manager.workspace.windows[0].id
      focus(firstID)
      let initial = host.contexts[firstID]!
      _ = try await document(initial.store.session.selectedSpace.selectedTabID!)
      try send(.newWindow)
      secondID = manager.workspace.windows.first { $0.id != firstID }!.id
      try expect(
        host.contexts[secondID]!.store.session.spaces.flatMap(\.tabs).isEmpty,
        "native New window menu creates a managed window without copying ordinary live pages")
      focus(secondID)
      host.contexts[secondID]!.store.perform(
        .open(fixture.appending(path: "host-second-temporary")))
      let temporary = host.contexts[secondID]!.store.session.selectedSpace.selectedTabID!
      _ = try await document(temporary)
      try send(.closeTab)
      try await wait("host close-tab recovery") {
        host.contexts[secondID]?.store.session.closedTabs.contains { $0.id == temporary } == true
      }
      try expect(
        !initial.store.session.closedTabs.contains { $0.id == temporary },
        "native menu closure records recovery only in its focused managed window")
      try send(.reopenClosed)
      let reopened = host.contexts[secondID]!.store.session.selectedSpace.selectedTabID!
      _ = try await document(reopened)
      try expect(reopened != temporary, "native Reopen menu restores a fresh owning tab identity")
      try send(.closeWindow)
      try await wait("ordinary host window closure") { host.contexts[secondID] == nil }
      try expect(
        manager.workspace.window(secondID) == nil && closures[secondID] == false,
        "ordinary native window close removes only its confirmed managed record")
      focus(firstID)
      try send(.closeWindow)
      try await wait("last managed host window closure") { host.contexts.isEmpty }
      try expect(
        manager.workspace.windows.isEmpty && !primary.runtime.isQuitting,
        "closing all managed host windows retains the catalog and leaves the test runtime available"
      )
      closedIDs = [firstID, secondID]
      focused = nil
      try send(.newWindow)
      firstID = manager.workspace.windows[0].id
      let first = host.contexts[firstID]!.store
      first.perform(.space(first.session.spaces[1].id))
      first.perform(.open(fixture.appending(path: "host-beta-final")))
      focus(firstID)
      try send(.newWindow)
      secondID = manager.workspace.windows.first { $0.id != firstID }!.id
      let second = host.contexts[secondID]!.store
      second.perform(.space(second.session.spaces[0].id))
      second.perform(.open(fixture.appending(path: "host-alpha-final")))
    } else {
      let saved = try JSONDecoder().decode(
        HostProbeIdentity.self, from: Data(contentsOf: checkpoint))
      firstID = saved.first
      secondID = saved.second
      closedIDs = saved.ordinarilyClosed
      let expected = Set([firstID, secondID] + [saved.engineWindow].compactMap { $0 })
      try expect(
        Set(host.contexts.keys) == expected
          && closedIDs.allSatisfy { host.contexts[$0] == nil },
        "native host startup restores retained windows and excludes ordinarily closed windows")
      guard let selections = saved.restorationSelections else {
        throw HostProbeFailure("Final host-restoration checkpoint is missing.")
      }
      guard saved.engineWindow == nil || saved.engineTab != nil else {
        throw HostProbeFailure("Saved engine-created fixture tab is missing.")
      }
      try expect(
        Set(selections.keys) == expected
          && selections.allSatisfy { id, selection in
            host.contexts[id].map { HostProbeSelection($0.store.session) == selection } == true
          },
        "production host restoration preserves each window's saved Space and tab selection")
      for id in [firstID, secondID] {
        let geometry = manager.workspace.window(id)!.geometry!
        try expect(
          host.contexts[id]!.window.frame
            == NSRect(x: geometry.x, y: geometry.y, width: geometry.width, height: geometry.height),
          "production host restores saved window geometry \(id)")
      }
      if let id = saved.engineWindow, let restored = host.contexts[id],
        let tab = saved.engineTab
      {
        try selectFixture(tab, in: restored)
        let account = try await document(tab)
        try expect(
          account["cookie"] as? String == "account=alpha"
            && restored.store.session.selectedSpace.profileID == bases[0].profileID,
          "production startup restores the engine-created normal window in its saved account")
        primary.runtime.closeWindowID(restored.nativeID)
        try await wait("restored engine window closure") { host.contexts[id] == nil }
        closedIDs.append(id)
      }
      focus(secondID)
      try send(.newWindow)
      let empty = host.contexts.keys.first { ![firstID, secondID].contains($0) }!
      focus(empty)
      try send(.closeTab)
      try await wait("empty host window closure") { host.contexts[empty] == nil }
      try expect(
        manager.workspace.window(empty) == nil,
        "Close tab becomes Close window for an empty native window")
      closedIDs.append(empty)
      try selectFixture(saved.firstTab, in: host.contexts[firstID]!)
      try selectFixture(saved.secondTab, in: host.contexts[secondID]!)
    }
    let first = host.contexts[firstID]!
    let second = host.contexts[secondID]!
    let firstTab = first.store.session.selectedSpace.selectedTabID!
    let secondTab = second.store.session.selectedSpace.selectedTabID!
    let beta = try await document(firstTab)
    let alpha = try await document(secondTab)
    try expect(
      beta["cookie"] as? String == "account=beta" && alpha["cookie"] as? String == "account=alpha",
      "native host presents separate beta and alpha account sessions simultaneously")
    focus(secondID)
    let requested = try await EngineRequestedWindowProbe(
      host: host, root: root, fixture: fixture, phase: phase
    ).run(alpha: second, beta: first)
    checks += requested.checks
    focus(firstID)
    try send(.search)
    try expect(
      first.store.commandIsOpen && !second.store.commandIsOpen,
      "native search menu targets the first focused window")
    first.store.dismissCommand()
    focus(secondID)
    try send(.newTab)
    try expect(
      second.store.commandIsOpen && !first.store.commandIsOpen,
      "native New tab menu follows focus without changing another window")
    second.store.dismissCommand()
    try send(.find)
    second.store.updatePageFindQuery("OrbitFindMarker")
    try await wait("focused host Find") { second.store.pageFind?.canMove == true }
    try expect(
      first.store.pageFind == nil && second.store.pageFind?.tabID == secondTab,
      "native Find menu retains its focused document/profile boundary")
    second.store.dismissPageFind()
    let foreign = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: .borderless,
      backing: .buffered, defer: false)
    focused = foreign
    host.perform(.search)
    try expect(
      !host.canPerform(.closeWindow) && !host.canPerform(.reload) && !first.store.commandIsOpen
        && !second.store.commandIsOpen,
      "foreign key windows cannot fall back to another account's commands")
    focus(secondID)
    second.store.spaceEditor = .edit(second.store.session.selectedSpaceID)
    try expect(
      !host.canPerform(.newTab) && !host.canPerform(.closeWindow) && host.canPerform(.newWindow),
      "native menu validation respects the focused window's modal state")
    second.store.sheet = nil
    second.store.sheetDidDismiss()
    let newWindowItem = try menuItem(.newWindow)
    let closeWindowItem = try menuItem(.closeWindow)
    try expect(
      newWindowItem.keyEquivalent == "n" && newWindowItem.keyEquivalentModifierMask == .command
        && closeWindowItem.keyEquivalentModifierMask == [.command, .shift],
      "native window menu registers exact Command-N and Shift-Command-W chords")
    first.window.setFrame(NSRect(x: 80, y: 90, width: 1000, height: 720), display: false)
    second.window.setFrame(NSRect(x: 150, y: 130, width: 980, height: 700), display: false)
    host.flushGeometry()
    try expect(
      manager.workspace.focusedWindowID == secondID && (try file.load()) == manager.workspace,
      "owned focus notifications and geometry persist in the managed snapshot")
    try expect(
      try Data(contentsOf: file.legacySessionURL) == legacy,
      "production host path retains the original legacy session bytes")
    try expect(
      host.contexts.values.allSatisfy { !$0.window.isVisible },
      "production host fixture keeps every native window hidden")
    for (index, context) in [first, second].enumerated() {
      try await capture(context.hosting, index: index + 1)
    }
    if let created = host.contexts[requested.retained] {
      try await capture(created.hosting, index: 3)
    }
    try await captureEditor(second.store)
    try JSONEncoder().encode(
      HostProbeIdentity(
        first: firstID, second: secondID, firstTab: firstTab, secondTab: secondTab,
        ordinarilyClosed: closedIDs, engineWindow: requested.retained,
        engineTab: host.contexts[requested.retained]?.store.session.selectedSpace.selectedTabID)
    ).write(to: checkpoint, options: .atomic)
    try expect(
      host.lastError == nil && manager.storageNotice == nil,
      "native host completes without startup, geometry, or persistence errors")
  }

  func prepareForQuit() throws {
    guard let host else { return }
    host.flushGeometry()
    guard host.workspace.persistSnapshot() else {
      throw HostProbeFailure("Host quit snapshot failed.")
    }
    expectedAfterQuit = host.workspace.workspace
    if phase == "initial" {
      let checkpoint = root.appending(path: "host-identities.json")
      var saved = try JSONDecoder().decode(
        HostProbeIdentity.self, from: Data(contentsOf: checkpoint))
      saved.restorationSelections = Dictionary(
        uniqueKeysWithValues: host.workspace.workspace.windows.map {
          ($0.id, HostProbeSelection($0.session))
        })
      try JSONEncoder().encode(saved).write(to: checkpoint, options: .atomic)
    }
  }

  func auditAfterQuit() throws -> [String] {
    guard let host, let expectedAfterQuit else { return [] }
    for _ in 0..<10 where !host.contexts.isEmpty {
      RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
    do {
      guard host.contexts.isEmpty, expectedAfterQuit.windows.allSatisfy({ closures[$0.id] == true })
      else {
        throw HostProbeFailure(
          "Actual engine quit did not deliver all host window closures as quitting.")
      }
      guard try file.load() == expectedAfterQuit else {
        throw HostProbeFailure("Actual engine quit changed retained window models.")
      }
      try report(error: nil)
      host.detach()
      return [
        "actual engine quit delivers owned host closures without ordinary-window deletion",
        "retained native host models and geometry remain intact after the engine loop exits",
      ]
    } catch {
      try? report(error: error)
      host.detach()
      throw error
    }
  }

  private func focus(_ id: UUID) {
    focused = host?.contexts[id]?.window
    if let focused {
      NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: focused)
    }
  }

  private func selectFixture(_ tab: UUID, in context: NativeBrowserContext) throws {
    guard
      let space = context.store.session.spaces.first(where: {
        $0.tabs.contains(where: { $0.id == tab })
      })
    else { throw HostProbeFailure("Saved host fixture tab is missing.") }
    context.store.perform(.tab(space: space.id, tab: tab))
  }

  private func menuItem(_ command: BrowserMenuCommand) throws -> NSMenuItem {
    guard
      let item = host?.menu?.items.flatMap({ $0.submenu?.items ?? [] }).first(where: {
        $0.representedObject as? String == command.rawValue
      })
    else { throw HostProbeFailure("Missing native menu \(command).") }
    return item
  }

  private func send(_ command: BrowserMenuCommand) throws {
    guard let host, host.canPerform(command) else {
      throw HostProbeFailure("Native menu disabled: \(command).")
    }
    let item = try menuItem(command)
    guard let action = item.action, NSApp.sendAction(action, to: item.target, from: item) else {
      throw HostProbeFailure("Native menu action failed: \(command).")
    }
  }

  private func verifyParentLock() async throws {
    let token = UUID().uuidString
    try JSONSerialization.data(withJSONObject: [
      "schema": 1, "pid": getpid(), "phase": phase, "token": token,
      "lockFile": "host-workspace/workspace.lock",
    ]).write(to: root.appending(path: "\(phase)-host-lock-ready.json"), options: .atomic)
    let receipt = root.appending(path: "\(phase)-host-lock-receipt.json")
    for _ in 0..<100 {
      if FileManager.default.fileExists(atPath: receipt.path) {
        let value =
          try JSONSerialization.jsonObject(with: Data(contentsOf: receipt)) as? [String: Any]
        try expect(
          value?["blocked"] as? Bool == true && value?["pid"] as? Int32 == getpid()
            && value?["parentPID"] as? Int32 == getppid() && value?["token"] as? String == token
            && value?["phase"] as? String == phase,
          "another process cannot acquire the active native workspace writer lock")
        return
      }
      try await Task.sleep(for: .milliseconds(100))
    }
    throw HostProbeFailure("Parent workspace-lock verification did not arrive.")
  }

  private func document(_ id: UUID) async throws -> [String: Any] {
    for _ in 0..<100 {
      let json: String? = await withCheckedContinuation { continuation in
        primary.runtime.evaluate(
          inTabID: id.uuidString,
          script:
            "({fixture:document.documentElement.dataset.arcusisFixture,instance:window.arcusisInstance,cookie:document.cookie})"
        ) { continuation.resume(returning: $0) }
      }
      if let data = json?.data(using: .utf8),
        let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        value["fixture"] as? String == "v1", value["instance"] as? String != nil
      {
        return value
      }
      try await Task.sleep(for: .milliseconds(100))
    }
    throw HostProbeFailure("Native host fixture document not ready.")
  }

  private func capture(_ view: NSView, index: Int) async throws {
    view.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(200))
    guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
      throw HostProbeFailure("Native host capture failed.")
    }
    view.cacheDisplay(in: view.bounds, to: bitmap)
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
      throw HostProbeFailure("Native host PNG failed.")
    }
    try png.write(to: root.appending(path: "\(phase)-native-host-\(index).png"), options: .atomic)
  }

  private func captureEditor(_ store: BrowserStore) async throws {
    let view = NSHostingView(
      rootView: SpaceEditor(store: store, route: .edit(store.session.selectedSpaceID))
        .environment(\.colorScheme, .light).frame(width: 496, height: 430))
    let carrier = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 496, height: 430), styleMask: .borderless,
      backing: .buffered, defer: false)
    carrier.contentView = view
    view.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(200))
    guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
      throw HostProbeFailure("Host Space editor capture failed.")
    }
    view.cacheDisplay(in: view.bounds, to: bitmap)
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
      throw HostProbeFailure("Host Space editor PNG failed.")
    }
    try png.write(to: root.appending(path: "\(phase)-host-space-editor.png"), options: .atomic)
    withExtendedLifetime(carrier) {}
  }

  private func wait(_ label: String, until ready: () -> Bool) async throws {
    for _ in 0..<100 {
      if ready() { return }
      try await Task.sleep(for: .milliseconds(100))
    }
    throw HostProbeFailure("Timed out: \(label).")
  }

  private func expect(_ condition: Bool, _ message: String) throws {
    guard condition else { throw HostProbeFailure(message) }
    checks.append(message)
  }

  private func report(error: Error?) throws {
    try JSONSerialization.data(
      withJSONObject: [
        "passed": error == nil, "checks": checks,
        "closedWindows": Dictionary(
          uniqueKeysWithValues: closures.map { ($0.key.uuidString, $0.value) }),
        "error": error?.localizedDescription as Any? ?? NSNull(),
        "scope":
          "Production host class with hidden native windows, actual NSMenu target actions, injected owned key-window identity and notifications, real native ordinary closures, managed restoration/geometry, cross-process lock, and engine-quit audit. Engine-requested normal-profile windows have a separate report. Physical input/focus, native close-cancellation dialogs, primary/last-engine-window macOS reopen policy, private sessions and company/vendor window flows remain unverified.",
      ], options: [.prettyPrinted, .sortedKeys]
    ).write(to: root.appending(path: "\(phase)-native-host.json"), options: .atomic)
  }
}

private struct HostProbeFailure: LocalizedError {
  let message: String
  init(_ message: String) { self.message = message }
  var errorDescription: String? { message }
}
