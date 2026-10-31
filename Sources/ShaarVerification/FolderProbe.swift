import AppKit
import BrowserCore
import ChromiumBridge
import SwiftUI

@testable import ArcusisBrowser

private struct FolderIdentities: Codable {
  let source: UUID
  let destination: UUID
  let root: UUID
  let child: UUID
  let parent: UUID
  let tabs: [UUID]
}

@MainActor
final class FolderProbe {
  let runtime: ARCChromiumRuntime
  let engine: BrowserEngine
  let store: BrowserStore
  let root: URL
  let phase: String
  private var checks: [String] = []
  private var previewWindow: NSWindow?

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
      try? report(error: error)
      throw error
    }
  }

  private func exercise() async throws -> [String] {
    let base = store.session.spaces[0]
    let other = store.session.spaces[1]
    let file = root.appending(path: "folder-identities.json")
    let ids: FolderIdentities
    if phase == "initial" {
      guard store.createSpace(name: "Folder source", sharingProfile: base.profileID, tint: .ocean)
      else { throw FolderFailure("Could not create source.") }
      let source = store.session.selectedSpaceID
      var tabs: [UUID] = []
      for _ in 0..<3 {
        store.perform(.open(base.selectedTab!.url))
        tabs.append(store.session.selectedSpace.selectedTabID!)
      }
      guard let main = store.createFolder(name: "Projects", in: source),
        let child = store.createFolder(name: "Accounts", in: source, parentID: main),
        store.createFolder(name: "Reference", in: source) != nil,
        store.createSpace(name: "Folder destination", sharingProfile: base.profileID, tint: .forest)
      else { throw FolderFailure("Could not create nested folders.") }
      let destination = store.session.selectedSpaceID
      store.perform(.open(base.selectedTab!.url))
      tabs.append(store.session.selectedSpace.selectedTabID!)
      guard let parent = store.createFolder(name: "Company", in: destination) else {
        throw FolderFailure("Could not create destination folder.")
      }
      ids = FolderIdentities(
        source: source, destination: destination, root: main, child: child, parent: parent,
        tabs: tabs)
      try JSONEncoder().encode(ids).write(to: file, options: .atomic)
    } else {
      ids = try JSONDecoder().decode(FolderIdentities.self, from: Data(contentsOf: file))
      let destination = try space(ids.destination)
      try expect(
        destination.folders.first { $0.id == ids.root }?.parentID == ids.parent,
        "folder hierarchy restores in its destination space")
      try expect(
        destination.folders.first { $0.id == ids.root }?.name == "Operations",
        "folder name restores after restart")
      try expect(
        destination.folders.first { $0.id == ids.root }?.isCollapsed == true,
        "collapsed folder state survives restart")
      try expect(
        destination.tabs.first { $0.id == ids.tabs[0] }?.folderID == ids.child,
        "nested tab membership survives restart")
      try expect(
        destination.tabs.first { $0.id == ids.tabs[1] }?.folderID == ids.root,
        "direct tab membership survives restart")
    }
    let tracked = ids.tabs + [base.selectedTabID!, other.selectedTabID!]
    var before: [UUID: NSDictionary] = [:]
    let nativeIDs = tracked.map { runtime.nativeTabID(forID: $0.uuidString) }
    for tab in tracked { before[tab] = try await document(tab) as NSDictionary }
    if phase == "restart" {
      try expect(
        store.moveFolder(ids.root, from: ids.destination, to: ids.source),
        "restored folder subtree can move back without rebuilding tabs")
    }
    store.perform(.tab(space: ids.source, tab: ids.tabs[0]))
    for (tab, title) in zip(
      ids.tabs, ["Company dashboard", "Drive notes", "Scratchpad", "Research"])
    {
      let text = String(data: try JSONEncoder().encode(title), encoding: .utf8)!
      let _: String? = await withCheckedContinuation { continuation in
        runtime.evaluate(
          inTabID: tab.uuidString, script: "(()=>{document.title=\(text);return true;})()"
        ) { continuation.resume(returning: $0) }
      }
    }
    _ = store.moveTab(ids.tabs[0], from: ids.source, to: ids.source, folderID: ids.child)
    _ = store.moveTab(ids.tabs[1], from: ids.source, to: ids.source, folderID: ids.root)
    let source = try space(ids.source)
    try expect(
      source.tabs.first { $0.id == ids.tabs[0] }?.isPinned == true,
      "moving into a folder pins the existing live tab")
    let logical = source.orderedTabs.map(\.id)
    store.toggleFolder(ids.root, in: ids.source)
    try expect(
      try space(ids.source).folders.first { $0.id == ids.root }?.isCollapsed == true,
      "collapsing hides the folder contents")
    try expect(
      try space(ids.source).orderedTabs.map(\.id) == logical,
      "collapse preserves native logical ordering")
    try expect(
      store.session.selectedSpace.selectedTabID == ids.tabs[0],
      "collapse retains the selected document")
    store.showCommand()
    store.commandQuery = "Accounts"
    try await capture(
      BrowserWindow(store: store), size: NSSize(width: 1200, height: 780),
      name: "\(phase)-folder-command.png")
    guard
      let result = store.results.first(where: {
        $0.action == .tab(space: ids.source, tab: ids.tabs[0])
      })
    else { throw FolderFailure("Collapsed folder tab was not searchable.") }
    let count = store.session.spaces.flatMap(\.tabs).count
    store.perform(result.action)
    try expect(
      try space(ids.source).folderPath(to: ids.child).allSatisfy { !$0.isCollapsed },
      "Command-T result reveals collapsed ancestors")
    try expect(
      store.session.spaces.flatMap(\.tabs).count == count, "folder search creates no duplicate tabs"
    )
    let route = FolderEditorRoute.edit(spaceID: ids.source, folderID: ids.root)
    store.showFolderEditor(route)
    try expect(
      store.renameFolder(ids.root, in: ids.source, name: "Operations"),
      "native editor operation renames a folder in its owning space")
    try await capture(
      FolderEditor(store: store, route: route), size: NSSize(width: 496, height: 370),
      name: "\(phase)-folder-editor.png")
    store.sheet = nil
    store.sheetDidDismiss()
    let transfer = SidebarTransfer.folder(
      sessionID: store.dragSessionID, sourceSpaceID: ids.source, folderID: ids.root)
    try expect(
      store.acceptSidebarDrop(transfer, into: ids.destination, pinned: true, folderID: ids.parent),
      "folder drop handler moves the complete subtree between shared-profile spaces")
    try expect(
      store.session.selectedSpaceID == ids.destination
        && store.session.selectedSpace.selectedTabID == ids.tabs[0],
      "selected document follows its folder into the destination space")
    let unchanged = store.session
    try expect(
      !store.moveFolder(ids.root, from: ids.destination, to: other.id),
      "folder moves cannot cross account profiles")
    try expect(
      !store.moveFolder(ids.root, from: ids.destination, to: ids.destination, parentID: ids.child),
      "folder drop cannot create an ancestry cycle")
    try expect(store.session == unchanged, "rejected folder moves leave all context state intact")
    store.perform(.space(ids.destination))
    guard
      let temporary = store.createFolder(name: "Temporary", in: ids.destination, parentID: ids.root)
    else { throw FolderFailure("Could not prepare removal fixture.") }
    let tabTransfer = SidebarTransfer.tab(
      sessionID: store.dragSessionID, sourceSpaceID: ids.destination, tabID: ids.tabs[1])
    try expect(
      store.acceptSidebarDrop(
        tabTransfer, into: ids.destination, pinned: true, folderID: temporary),
      "tab drop handler places a live page in a nested folder")
    try expect(
      store.removeFolder(temporary, in: ids.destination), "removing a folder preserves its pages")
    try expect(
      try space(ids.destination).tabs.first { $0.id == ids.tabs[1] }?.folderID == ids.root,
      "removed container promotes its tab to the parent folder")
    for (index, tab) in tracked.enumerated() {
      try expect(
        try await document(tab) as NSDictionary == before[tab],
        "folder operations retain live document and account storage \(index + 1)")
      try expect(
        runtime.nativeTabID(forID: tab.uuidString) == nativeIDs[index],
        "folder operations retain native tab identity \(index + 1)")
    }
    let tabs = store.session.spaces.filter { $0.profileID == base.profileID }.flatMap(\.orderedTabs)
    let ordered = tabs.filter(\.isPinned) + tabs.filter { !$0.isPinned }
    try await OrderingProbe(
      runtime: runtime, engine: engine, store: store, root: root, phase: "\(phase)-folders"
    )
    .verifyNativeOrder(
      ordered, profile: base.profileID, label: "folder projection matches native order")
    try expect(
      true, "extension-visible order, pins, profile, and active target match the folder projection")
    try await capture(
      BrowserWindow(store: store), size: NSSize(width: 1200, height: 780),
      name: "\(phase)-folders-expanded.png")
    try await capture(
      BrowserWindow(store: store), size: NSSize(width: 760, height: 520),
      name: "\(phase)-folders-compact.png")
    store.toggleFolder(ids.root, in: ids.destination)
    try await capture(
      BrowserWindow(store: store), size: NSSize(width: 1200, height: 780),
      name: "\(phase)-folders-collapsed.png")
    try expect(
      store.session.version == BrowserSession.currentVersion,
      "folder session uses the current schema")
    try expect(
      try SessionFile(url: root.appending(path: "session.json")).load() == store.session,
      "folder hierarchy, membership, selection, and collapse state save atomically")
    store.perform(.space(base.id))
    return checks
  }

  private func space(_ id: UUID) throws -> BrowserSpace {
    guard let space = store.session.spaces.first(where: { $0.id == id }) else {
      throw FolderFailure("Folder fixture space was lost.")
    }
    return space
  }

  private func document(_ id: UUID) async throws -> [String: Any] {
    for _ in 0..<80 {
      let json: String? = await withCheckedContinuation { continuation in
        runtime.evaluate(
          inTabID: id.uuidString,
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
    throw FolderFailure("Folder fixture page was not ready.")
  }

  private func capture<V: View>(_ view: V, size: NSSize, name: String) async throws {
    let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered,
      defer: false)
    window.contentView = host
    previewWindow = window
    try await Task.sleep(for: .milliseconds(100))
    host.layoutSubtreeIfNeeded()
    guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
      throw FolderFailure("Folder UI could not be rendered.")
    }
    host.cacheDisplay(in: host.bounds, to: bitmap)
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
      throw FolderFailure("Folder UI could not be encoded.")
    }
    try png.write(to: root.appending(path: name), options: .atomic)
  }

  private func expect(_ condition: Bool, _ message: String) throws {
    guard condition else { throw FolderFailure(message) }
    checks.append(message)
  }

  private func report(error: Error?) throws {
    try JSONSerialization.data(
      withJSONObject: [
        "passed": error == nil, "phase": phase, "checks": checks,
        "error": error?.localizedDescription as Any? ?? NSNull(),
        "scope":
          "Real-engine folder model/drop operations and offscreen native layouts. No live native drag, menu, or dialog input tested.",
      ],
      options: [.prettyPrinted, .sortedKeys]
    ).write(to: root.appending(path: "\(phase)-folders.json"), options: .atomic)
  }
}

private struct FolderFailure: LocalizedError {
  let message: String
  init(_ message: String) { self.message = message }
  var errorDescription: String? { message }
}
