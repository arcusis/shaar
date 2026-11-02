// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import BrowserCore
import SwiftUI
import Testing
import UniformTypeIdentifiers

@testable import ArcusisBrowser

@Suite(.serialized) @MainActor
struct SidebarDnDProbeTests {
  init() throws {
    let type = UTType("com.arcusis.browser.sidebar-item")
    try #require(
      type?.isDeclared == true && type?.conforms(to: .data) == true,
      "Native drop probes require the registered_sidebar_type fixture used by ci-stage.py and sidebar-dnd-probe.py."
    )
  }

  @Test(arguments: [0, 1]) func pinnedToFavoritesOffscreenDrop(existingFavorites: Int) async throws
  {
    _ = NSApplication.shared
    let store = BrowserStore()
    let opened = store.session.open(URL(string: "https://pinned.example")!)
    let id = try #require(opened)
    store.togglePin(id)
    if existingFavorites > 0 {
      _ = store.session.addFavorite(
        profileID: store.session.selectedSpace.profileID,
        originalURL: URL(string: "https://favorite.example")!, title: "Existing")
    }
    store.tabDrag = TabDrag(tabID: id, fromSplitPane: false)
    let item = SidebarTransfer.tab(
      sessionID: store.dragSessionID, sourceSpaceID: store.session.selectedSpaceID, tabID: id)
    let host = NSHostingView(rootView: BrowserSidebar(store: store))
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 260, height: 700), styleMask: .borderless,
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    defer { window.close() }
    host.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(150))
    host.layoutSubtreeIfNeeded()
    func receivers(_ view: NSView) -> [NSView] {
      (view.registeredDraggedTypes.isEmpty ? [] : [view]) + view.subviews.flatMap(receivers)
    }
    let point = NSPoint(x: 40, y: 20)
    let candidates = receivers(host).filter { $0.convert($0.bounds, to: host).contains(point) }
    print("OFFSCREEN_RECEIVERS: \(candidates.map { $0.convert($0.bounds, to: host) })")
    let receiver = try #require(candidates.last)
    let info = try OffscreenSidebarDrag(window: window, item: item)
    info.location = host.convert(point, to: nil)
    let operation = receiver.draggingEntered(info)
    print("OFFSCREEN_FAVORITES_OPERATION: \(operation.rawValue)")
    #expect(!operation.isEmpty)
    if receiver.prepareForDragOperation(info) { _ = receiver.performDragOperation(info) }
    try await Task.sleep(for: .milliseconds(150))
    #expect(store.session.favoritePages.contains { $0.tab.id == id })
    #expect(!store.session.selectedSpace.tabs.contains { $0.id == id })
    #expect(!window.isVisible && !window.isKeyWindow)
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appending(path: "build/Verification/sidebar-dnd")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    host.layoutSubtreeIfNeeded()
    _ = try VisualCapture.render(
      host, to: root.appending(path: "favorites-\(existingFavorites).png"))
  }

  @Test func splitMemberOutAfterDragStateExpires() async throws {
    let store = BrowserStore()
    let space = store.session.selectedSpaceID
    let openedFirst = store.session.open(URL(string: "https://one.example")!)
    let openedSecond = store.session.open(URL(string: "https://two.example")!)
    let first = try #require(openedFirst)
    let second = try #require(openedSecond)
    store.togglePin(first)
    store.togglePin(second)
    store.splitTabs(first, second)
    let transfer = store.beginTabDrag(second, spaceID: space, fromSplitPane: true)
    // AppKit may deliver the drop after the transient drag presentation is cleared.
    store.tabDrag = nil
    #expect(store.acceptSidebarDrop(transfer, into: space, pinned: true))
    #expect(store.session.selectedSpace.splits.isEmpty)
  }
}

@MainActor
private final class OffscreenSidebarDrag: NSObject, NSDraggingInfo {
  let draggingDestinationWindow: NSWindow?
  let draggingPasteboard = NSPasteboard.withUniqueName()
  let draggingSourceOperationMask: NSDragOperation = .every
  var location = NSPoint(x: 120, y: 20)
  var draggingLocation: NSPoint { location }
  var draggedImageLocation: NSPoint { .zero }
  nonisolated var draggedImage: NSImage? { nil }
  var draggingSource: Any? { draggingDestinationWindow?.contentView }
  var draggingSequenceNumber: Int { 383 }
  var draggingFormation: NSDraggingFormation = .none
  var animatesToDestination = false
  var numberOfValidItemsForDrop = 1
  var springLoadingHighlight: NSSpringLoadingHighlight { .none }

  init(window: NSWindow, item: SidebarTransfer) throws {
    draggingDestinationWindow = window
    super.init()
    draggingPasteboard.setData(
      try JSONEncoder().encode(item),
      forType: NSPasteboard.PasteboardType("com.arcusis.browser.sidebar-item"))
  }

  func slideDraggedImage(to point: NSPoint) {}
  nonisolated override func namesOfPromisedFilesDropped(atDestination destination: URL) -> [String]?
  { nil }
  func resetSpringLoading() {}
  func enumerateDraggingItems(
    options: NSDraggingItemEnumerationOptions = [], for view: NSView?, classes: [AnyClass],
    searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
    using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
  ) {
    for (index, item) in (draggingPasteboard.pasteboardItems ?? []).enumerated() {
      var stop: ObjCBool = false
      block(NSDraggingItem(pasteboardWriter: item), index, &stop)
      if stop.boolValue { break }
    }
  }
}

@MainActor
private final class OffscreenSidebarMount {
  let host: NSHostingView<AnyView>
  let window: NSWindow
  private(set) var lastOperation: NSDragOperation = []

  init(store: BrowserStore, draft: SidebarFolderDraft? = nil) {
    _ = NSApplication.shared
    host = NSHostingView(rootView: AnyView(BrowserSidebar(store: store, previewFolderDraft: draft)))
    window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 260, height: 700), styleMask: .borderless,
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
  }

  var receivers: [NSView] {
    func collect(_ view: NSView) -> [NSView] {
      (view.registeredDraggedTypes.isEmpty ? [] : [view]) + view.subviews.flatMap(collect)
    }
    return collect(host)
  }

  func settle() async throws {
    host.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(150))
    host.layoutSubtreeIfNeeded()
    #expect(!window.isVisible && !window.isKeyWindow)
  }

  func drop(_ item: SidebarTransfer, on receiver: NSView, hold: Duration = .zero) async throws
    -> Bool
  {
    let info = try OffscreenSidebarDrag(window: window, item: item)
    info.location = receiver.convert(
      NSPoint(x: receiver.bounds.midX, y: receiver.bounds.midY), to: nil)
    let operation = receiver.draggingEntered(info)
    lastOperation = operation
    if hold > .zero {
      _ = receiver.draggingUpdated(info)
      try await Task.sleep(for: hold)
    }
    let accepted =
      !operation.isEmpty && receiver.prepareForDragOperation(info)
      && receiver.performDragOperation(info)
    try await Task.sleep(for: .milliseconds(150))
    receiver.draggingExited(info)
    #expect(!window.isVisible && !window.isKeyWindow)
    return accepted
  }

  func capture(_ name: String, root: URL) throws {
    host.layoutSubtreeIfNeeded()
    _ = try VisualCapture.render(host, to: root.appending(path: name))
  }

  func close() { window.close() }
}

extension SidebarDnDProbeTests {
  @Test func nativeSplitMemberOutAfterDragPresentationExpires() async throws {
    let store = BrowserStore()
    let space = store.session.selectedSpaceID
    let first = store.session.open(URL(string: "https://one.example")!)!
    let second = store.session.open(URL(string: "https://two.example")!)!
    store.togglePin(first)
    store.togglePin(second)
    store.splitTabs(first, second)
    let transfer = store.beginTabDrag(second, spaceID: space, fromSplitPane: true)
    store.tabDrag = nil
    let mounted = OffscreenSidebarMount(store: store)
    defer { mounted.close() }
    try await mounted.settle()
    let footer = try #require(
      mounted.receivers.last { abs($0.bounds.height - 32) < 1 && $0.bounds.width > 100 })
    #expect(try await mounted.drop(transfer, on: footer))
    #expect(store.session.selectedSpace.splits.isEmpty)
    #expect(store.session.selectedSpace.tabs.first { $0.id == second }?.isPinned == false)
  }

  @Test(arguments: [false, true])
  func nativeHeldDropCreatesFolderAndRefusesStackFavoriteDrop(existingFavorite: Bool) async throws {
    let store = BrowserStore()
    let space = store.session.selectedSpaceID
    if existingFavorite {
      _ = store.session.addFavorite(
        profileID: store.session.selectedSpace.profileID,
        originalURL: URL(string: "https://favorite.example")!, title: "Favorite")
    }
    let first = store.session.open(URL(string: "https://first.example")!)!
    let second = store.session.open(URL(string: "https://second.example")!)!
    store.togglePin(first)
    store.togglePin(second)
    store.tabDrag = TabDrag(tabID: second, fromSplitPane: false)
    let mounted = OffscreenSidebarMount(store: store)
    defer { mounted.close() }
    try await mounted.settle()
    let target = try #require(mounted.receivers.first { abs($0.bounds.height - 34) < 1 })
    // Synthetic dragging info has no pressed mouse button. Keep drag presentation alive
    // explicitly, as AppKit does throughout a real mouse or trackpad hold.
    let transfer = SidebarTransfer.tab(
      sessionID: store.dragSessionID, sourceSpaceID: space, tabID: second)
    #expect(try await mounted.drop(transfer, on: target, hold: .milliseconds(750)))
    let folder = try #require(store.session.selectedSpace.folders.first)
    #expect(store.session.selectedSpace.tabs.allSatisfy { $0.folderID == folder.id })
    #expect(store.renameFolder(folder.id, in: space, name: "Projects"))
    store.splitTabs(first, second)
    let split = try #require(store.session.selectedSpace.splits.first)
    let stack = SidebarTransfer.split(
      sessionID: store.dragSessionID, sourceSpaceID: space, splitID: split.id)
    let folderPayload = SidebarTransfer.folder(
      sessionID: store.dragSessionID, sourceSpaceID: space, folderID: folder.id)
    for refused in [stack, folderPayload] {
      store.sidebarDrag = refused
      try await mounted.settle()
      let favoriteTarget = try #require(
        mounted.receivers.last { $0.convert($0.bounds, to: mounted.host).minY < 10 })
      let before = store.session
      _ = try await mounted.drop(refused, on: favoriteTarget)
      #expect(mounted.lastOperation.isEmpty)
      #expect(store.session == before)
      #expect(store.favoritesDropIsRefused)
    }
  }

  @Test func restartProbePhase() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard let phase = environment["SHAAR_SIDEBAR_DND_PHASE"],
      let path = environment["SHAAR_SIDEBAR_DND_ROOT"]
    else { return }
    let root = URL(fileURLWithPath: path)
    let file = WorkspaceFile(
      url: root.appending(path: "workspace.json"),
      legacySessionURL: root.appending(path: "legacy.json"))
    if phase == "initial" {
      let store = BrowserStore()
      let space = store.session.selectedSpaceID
      let tabs = (0..<4).map { store.session.open(URL(string: "https://pane\($0).example")!)! }
      for tab in tabs { store.togglePin(tab) }
      let transfer = SidebarTransfer.tab(
        sessionID: store.dragSessionID, sourceSpaceID: space, tabID: tabs[3])
      let created = store.createFolderFromDrop(transfer, onto: tabs[2], name: "Projects")
      let folder = try #require(created)
      store.splitTabs(tabs[0], tabs[1])
      store.applySplitLayout(.rows)
      let split = try #require(store.session.selectedSpace.splits.first)
      store.setSplitWeights([0.3, 0.7], at: [], splitID: split.id)
      let stack = SidebarTransfer.split(
        sessionID: store.dragSessionID, sourceSpaceID: space, splitID: split.id)
      #expect(store.acceptSidebarDrop(stack, into: space, pinned: true, folderID: folder))
      #expect(!store.acceptFavoritesDrop(stack))
      #expect(store.acceptSidebarDrop(transfer, into: space, pinned: false))
      let empty = store.createFolder(name: "Empty", in: space)
      #expect(empty != nil)
      let temporary = store.createFolder(name: "Temporary", in: space)
      let removed = try #require(temporary)
      #expect(store.removeFolder(removed, in: space))
      let mounted = OffscreenSidebarMount(store: store)
      defer { mounted.close() }
      try await mounted.settle()
      try mounted.capture("initial.png", root: root)
      let draftMount = OffscreenSidebarMount(
        store: store, draft: SidebarFolderDraft(route: .create(spaceID: space, parentID: nil)))
      defer { draftMount.close() }
      try await draftMount.settle()
      try draftMount.capture("inline-folder.png", root: root)
      let favoriteTab = store.session.open(URL(string: "https://saved-favorite.example")!)!
      #expect(
        store.acceptFavoritesDrop(
          .tab(
            sessionID: store.dragSessionID, sourceSpaceID: space, tabID: favoriteTab)))
      var workspace = try BrowserWorkspace(session: store.session)
      let liveFile = WorkspaceFile(
        url: root.appending(path: "open-workspace.json"),
        legacySessionURL: root.appending(path: "legacy.json"))
      try liveFile.save(workspace)
      try workspace.removeWindow(workspace.windows[0].id)
      try file.save(workspace)
    } else {
      let liveFile = WorkspaceFile(
        url: root.appending(path: "open-workspace.json"),
        legacySessionURL: root.appending(path: "legacy.json"))
      let liveLoaded = try liveFile.load()
      let live = try #require(liveLoaded)
      let liveSession = try #require(live.windows.first?.session)
      #expect(
        liveSession.selectedSpace.tabs.filter { !$0.isPinned }.map(\.url.host) == ["pane3.example"])
      #expect(liveSession.selectedSpace.splits.first?.tabIDs.count == 2)
      #expect(liveSession.favorites.first?.originalURL.host == "saved-favorite.example")
      #expect(liveSession.selectedSpace.selectedFavoriteID == liveSession.favorites.first?.id)
      let loaded = try file.load()
      var workspace = try #require(loaded)
      #expect(workspace.windows.isEmpty)
      let opened = try workspace.addWindow()
      let session = try #require(workspace.window(opened)?.session)
      let split = try #require(session.selectedSpace.splits.first)
      #expect(split.tabIDs.count == 2)
      #expect(SplitLayoutPreset.matching(split.root) == .rows)
      if case .group(_, _, let weights) = split.root {
        #expect(weights == [0.3, 0.7])
      } else {
        Issue.record("Saved split was flattened")
      }
      #expect(
        session.selectedSpace.tabs.filter { split.tabIDs.contains($0.id) }.map(\.url.host) == [
          "pane0.example", "pane1.example",
        ])
      let folder = try #require(session.selectedSpace.folders.first { $0.name == "Projects" })
      #expect(
        session.selectedSpace.tabs.filter { split.tabIDs.contains($0.id) }.allSatisfy {
          $0.isPinned && $0.folderID == folder.id
        })
      #expect(session.selectedSpace.folders.contains { $0.name == "Empty" })
      #expect(!session.selectedSpace.folders.contains { $0.name == "Temporary" })
      try workspace.validate()
      let mounted = OffscreenSidebarMount(store: BrowserStore(session: session))
      defer { mounted.close() }
      try await mounted.settle()
      try mounted.capture("restart.png", root: root)
    }
    try JSONSerialization.data(
      withJSONObject: [
        "phase": phase, "passed": true, "visibleWindows": false, "physicalInput": false,
        "scope":
          "Native offscreen drop dispatch and separate-process workspace restoration; no physical mouse or trackpad input.",
      ], options: [.prettyPrinted, .sortedKeys]
    ).write(to: root.appending(path: "\(phase).json"), options: .atomic)
  }
}
