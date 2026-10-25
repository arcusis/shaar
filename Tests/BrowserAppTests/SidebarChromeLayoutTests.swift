import AppKit
import BrowserCore
import SwiftUI
import Testing
import XCTest

@testable import ArcusisBrowser

@Suite @MainActor
struct SidebarFolderDraftTests {
  @Test func inlineFolderDraftRejectsStaleSpaceAndKeepsCancellationModelFree() throws {
    let store = BrowserStore()
    let spaceID = store.session.selectedSpaceID
    let folderID = try #require(store.createFolder(name: "Projects", in: spaceID))
    let route = FolderEditorRoute.create(spaceID: spaceID, parentID: folderID)
    let draft = SidebarFolderDraft(route: route)
    let before = store.session

    #expect(draft.name == "Untitled")
    #expect(draft.isValid(in: store.session))
    #expect(store.session == before)
    store.cycleSpace(by: 1)
    #expect(!draft.isValid(in: store.session))
    #expect(
      store.createFolder(name: draft.name, in: draft.spaceID, parentID: draft.parentID) == nil)
    #expect(store.session.spaces.first { $0.id == spaceID }?.folders.map(\.name) == ["Projects"])
  }
}

@MainActor
final class SidebarChromeLayoutTests: XCTestCase {
  private final class CaptureMeasurements {
    var footerFrame: CGRect?
    var ordinaryRevealFrames = SidebarRevealFrames()
    var spaceRevealFrames = SidebarRevealFrames()
  }

  private struct CaptureCase {
    let name: String
    let store: BrowserStore
    let width: CGFloat
    let height: CGFloat
    let appearance: NSAppearance.Name
    let colorScheme: ColorScheme
    let draft: SidebarFolderDraft?
    let showsDownloads: Bool
    let scenario: String
  }

  func testCapturesActualSidebarAtProductionWidthAndMinimumHeight() async throws {
    let store = BrowserStore()
    let spaceID = store.session.selectedSpaceID
    let folderID = try XCTUnwrap(
      store.createFolder(name: String(repeating: "Long folder label ", count: 7), in: spaceID))
    for index in 0..<8 {
      XCTAssertTrue(
        store.createSpace(
          name: "Research Space \(index)", sharingProfile: store.session.selectedSpace.profileID,
          tint: .ocean))
    }
    store.perform(.space(spaceID))

    let download = try XCTUnwrap(
      BrowserDownload(
        id: UUID().uuidString, profileID: store.session.selectedSpace.profileID,
        filename: String(repeating: "recent-report-", count: 12) + "final.pdf",
        path: "/tmp/recent-report-final.pdf", sourceURL: "https://example.com/report",
        state: .finished, paused: false, dangerous: false, offTheRecord: false,
        received: 1024, total: 1024, startTime: 1_735_689_600))
    let root = URL(fileURLWithPath: "/tmp/browser-sidebar-chrome", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let emptyStore = try makeStore(populated: false)
    let populatedStore = try makeStore(populated: true)
    let captures = [
      CaptureCase(
        name: "sidebar-empty-light.png", store: emptyStore,
        width: BrowserChromeLayout.sidebarWidth, height: 760, appearance: .aqua,
        colorScheme: .light, draft: nil, showsDownloads: false, scenario: "empty"),
      CaptureCase(
        name: "sidebar-empty-dark.png", store: emptyStore,
        width: BrowserChromeLayout.sidebarWidth, height: 760, appearance: .darkAqua,
        colorScheme: .dark, draft: nil, showsDownloads: false, scenario: "empty"),
      CaptureCase(
        name: "sidebar-empty-minimum-height.png", store: emptyStore,
        width: BrowserChromeLayout.sidebarWidth, height: 520, appearance: .aqua,
        colorScheme: .light, draft: nil, showsDownloads: false, scenario: "empty-minimum"),
      CaptureCase(
        name: "sidebar-populated-long-tabs.png", store: populatedStore,
        width: BrowserChromeLayout.sidebarWidth, height: 760, appearance: .aqua,
        colorScheme: .light, draft: nil, showsDownloads: false, scenario: "populated"),
      CaptureCase(
        name: "sidebar-recent-files.png", store: store,
        width: BrowserChromeLayout.sidebarWidth, height: 520, appearance: .aqua,
        colorScheme: .light, draft: nil, showsDownloads: true, scenario: "recent-downloads"),
      CaptureCase(
        name: "sidebar-inline-folder.png", store: store,
        width: BrowserChromeLayout.sidebarWidth, height: 760, appearance: .aqua,
        colorScheme: .light,
        draft: SidebarFolderDraft(route: .create(spaceID: spaceID, parentID: folderID)),
        showsDownloads: false, scenario: "inline-folder-draft"),
    ]
    var captureIndex: [[String: Any]] = []

    for capture in captures {
      let path = root.appending(path: capture.name)
      let measurements = CaptureMeasurements()
      let view = BrowserSidebar(
        store: capture.store,
        previewRecentDownloads: capture.showsDownloads ? [download] : nil,
        previewFolderDraft: capture.draft
      )
      .frame(width: capture.width, height: capture.height)
      .background(Color(nsColor: .windowBackgroundColor))
      .environment(\.colorScheme, capture.colorScheme)
      .onPreferenceChange(SidebarFooterBoundsPreferenceKey.self) {
        measurements.footerFrame = $0
      }
      let bounds = try await captureView(
        view, size: NSSize(width: capture.width, height: capture.height),
        appearance: capture.appearance, to: path, measurements: measurements)
      let footer = try XCTUnwrap(measurements.footerFrame, "Footer bounds missing: \(capture.name)")
      XCTAssertGreaterThan(footer.width, 0, "Footer width missing: \(capture.name)")
      XCTAssertGreaterThan(footer.height, 0, "Footer height missing: \(capture.name)")
      let footerFits = footer.minY >= 0 && footer.maxY <= capture.height
      if capture.height == 520 {
        XCTAssertTrue(footerFits, "Sidebar footer clipped: \(capture.name), frame=\(footer)")
      }

      let session = capture.store.session
      let selectedSpace = session.selectedSpace
      XCTAssertEqual(
        selectedSpace.tabs.filter { !$0.isPinned }.count, capture.scenario == "populated" ? 240 : 0)
      XCTAssertEqual(
        selectedSpace.tabs.filter(\.isPinned).count, capture.scenario == "populated" ? 4 : 0)
      XCTAssertEqual(bounds.width, Int(capture.width))
      XCTAssertEqual(bounds.height, Int(capture.height))
      captureIndex.append([
        "name": capture.name,
        "path": path.path,
        "scenario": capture.scenario,
        "width": capture.width,
        "height": capture.height,
        "colorScheme": capture.colorScheme == .dark ? "dark" : "light",
        "appearance": capture.appearance == .darkAqua ? "dark" : "light",
        "ordinaryTabCount": selectedSpace.tabs.filter { !$0.isPinned }.count,
        "pinnedTabCount": selectedSpace.tabs.filter(\.isPinned).count,
        "folderCount": selectedSpace.folders.count,
        "favoriteCount": session.favorites(for: selectedSpace.profileID).count,
        "includesRecentFileCard": capture.showsDownloads,
        "includesFolderDraft": capture.draft != nil,
        "capturePixelWidth": bounds.width,
        "capturePixelHeight": bounds.height,
        "footerBounds": [
          "x": footer.origin.x, "y": footer.origin.y,
          "width": footer.width, "height": footer.height,
        ],
        "footerFits": footerFits,
      ])
    }

    let index = try JSONSerialization.data(
      withJSONObject: captureIndex, options: [.prettyPrinted, .sortedKeys])
    try index.write(to: root.appending(path: "capture-index.json"), options: .atomic)
  }

  func testCapturesSidebarTabRowPresentationStatesInOwnedOffscreenWindows() throws {
    let root = URL(fileURLWithPath: "/tmp/browser-sidebar-rows", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let tabID = UUID(uuidString: "30000000-0000-0000-0000-000000000099")!
    let longTitle = String(repeating: "Long ordinary tab label with useful context ", count: 4)
    let states: [(String, String, Bool, Bool, Bool)] = [
      ("idle-ordinary", "Ordinary tab", false, false, false),
      ("selected-ordinary", "Ordinary tab", false, true, false),
      ("close-visible-ordinary", "Ordinary tab", false, false, true),
      ("long-label-ordinary", longTitle, false, false, false),
      ("close-visible-pinned", "Pinned tab", true, false, true),
    ]
    var index: [[String: Any]] = []

    for (name, title, isPinned, isSelected, closeIsVisible) in states {
      let path = root.appending(path: "\(name).png")
      let row = SidebarTabRow(
        tabID: tabID,
        title: title,
        favicon: nil,
        isPinned: isPinned,
        isSelected: isSelected,
        closeIsVisible: closeIsVisible,
        onSelect: {},
        onClose: {},
        onHoverChanged: { _ in }
      )
      .background(Color(nsColor: .windowBackgroundColor))
      let size = NSSize(width: BrowserChromeLayout.sidebarWidth, height: 48)
      let pixels = try captureRow(row, size: size, to: path)
      XCTAssertEqual(pixels.width, Int(size.width))
      XCTAssertEqual(pixels.height, Int(size.height))
      XCTAssertGreaterThan(try Data(contentsOf: path).count, 100)
      index.append([
        "name": name,
        "path": path.path,
        "captureKind": "pure-presentation-state",
        "physicalHoverVerified": false,
        "title": title,
        "isPinned": isPinned,
        "isSelected": isSelected,
        "closeIsVisible": closeIsVisible,
        "width": pixels.width,
        "height": pixels.height,
      ])
    }

    let data = try JSONSerialization.data(
      withJSONObject: index, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: root.appending(path: "capture-index.json"), options: .atomic)
  }

  func testProgrammaticSelectionRevealsLastOrdinaryTabAndCapturesBeforeAfter() async throws {
    let store = try makeStore(populated: true, selectedLastOrdinaryTab: true)
    let spaceID = store.session.selectedSpaceID
    let lastTab = try XCTUnwrap(store.session.selectedSpace.tabs.last(where: { !$0.isPinned }))
    let firstTab = try XCTUnwrap(store.session.selectedSpace.tabs.first(where: { !$0.isPinned }))
    XCTAssertEqual(store.session.selectedSpace.selectedTabID, lastTab.id)
    guard case .tab(let restoredTab) = store.session.selectedPage else {
      return XCTFail("Expected restored ordinary tab selection")
    }
    XCTAssertEqual(restoredTab.id, lastTab.id)
    let root = URL(fileURLWithPath: "/tmp/browser-sidebar-reveal", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    var captures: [[String: Any]] = []
    let measurements = CaptureMeasurements()
    let view = BrowserSidebar(store: store)
      .frame(width: BrowserChromeLayout.sidebarWidth, height: 520)
      .background(Color(nsColor: .windowBackgroundColor))
      .environment(
        \.browserChromeAccessibilityOverrides,
        BrowserChromeAccessibilityOverrides(reduceMotion: true)
      )
      .onPreferenceChange(SidebarFooterBoundsPreferenceKey.self) {
        measurements.footerFrame = $0
      }
      .onPreferenceChange(SidebarOrdinaryRevealFramesPreferenceKey.self) {
        measurements.ordinaryRevealFrames = $0
      }
    let mounted = try MountedChromeSidebar(
      view: view, size: NSSize(width: BrowserChromeLayout.sidebarWidth, height: 520),
      appearance: .aqua)
    defer { mounted.close() }
    for (phase, tabID) in [("initial-restored-last", lastTab.id)] {
      guard
        await mounted.waitUntil({
          isVisible(measurements.ordinaryRevealFrames, selectedID: tabID)
        })
      else {
        XCTFail("Restored last ordinary tab not visible: \(measurements.ordinaryRevealFrames)")
        return
      }
      let path = root.appending(path: "ordinary-\(phase).png")
      try mounted.capture(to: path)
      captures.append(["phase": phase, "path": path.path, "selectedTabID": tabID.uuidString])
    }
    store.perform(.tab(space: spaceID, tab: firstTab.id))
    guard
      await mounted.waitUntil({
        isVisible(measurements.ordinaryRevealFrames, selectedID: firstTab.id)
          && measurements.ordinaryRevealFrames.selected.minY < 100
      })
    else {
      XCTFail("Programmatically selected first ordinary tab not visible")
      return
    }
    let firstPath = root.appending(path: "ordinary-programmatic-first.png")
    try mounted.capture(to: firstPath)
    captures.append([
      "phase": "programmatic-first", "path": firstPath.path,
      "selectedTabID": firstTab.id.uuidString,
    ])
    store.perform(.tab(space: spaceID, tab: lastTab.id))
    guard
      await mounted.waitUntil({
        isVisible(measurements.ordinaryRevealFrames, selectedID: lastTab.id)
          && measurements.ordinaryRevealFrames.selected.minY > 0
      })
    else {
      XCTFail("Programmatically selected last ordinary tab not visible")
      return
    }
    let lastPath = root.appending(path: "ordinary-programmatic-last.png")
    try mounted.capture(to: lastPath)
    captures.append([
      "phase": "programmatic-last", "path": lastPath.path,
      "selectedTabID": lastTab.id.uuidString,
    ])
    let index = try JSONSerialization.data(
      withJSONObject: captures, options: [.prettyPrinted, .sortedKeys])
    try index.write(to: root.appending(path: "ordinary-capture-index.json"), options: .atomic)
  }

  func testSelectedLastSpaceRevealsOnRestoreAndProgrammaticChange() async throws {
    let store = try makeSpaceStore(count: 20)
    let lastSpace = try XCTUnwrap(store.session.spaces.last)
    let firstSpace = try XCTUnwrap(store.session.spaces.first)
    let root = URL(fileURLWithPath: "/tmp/browser-sidebar-reveal", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let measurements = CaptureMeasurements()
    let view = BrowserSidebar(store: store)
      .frame(width: BrowserChromeLayout.sidebarWidth, height: 520)
      .background(Color(nsColor: .windowBackgroundColor))
      .environment(
        \.browserChromeAccessibilityOverrides,
        BrowserChromeAccessibilityOverrides(reduceMotion: true)
      )
      .onPreferenceChange(SidebarSpaceRevealFramesPreferenceKey.self) {
        measurements.spaceRevealFrames = $0
      }
    let mounted = try MountedChromeSidebar(
      view: view, size: NSSize(width: BrowserChromeLayout.sidebarWidth, height: 520),
      appearance: .aqua)
    defer { mounted.close() }
    guard
      await mounted.waitUntil({
        isVisible(measurements.spaceRevealFrames, selectedID: lastSpace.id)
      })
    else {
      XCTFail("Restored last Space not visible: \(measurements.spaceRevealFrames)")
      return
    }
    let initialPath = root.appending(path: "space-initial-restored-last.png")
    try mounted.capture(to: initialPath)

    store.perform(.space(firstSpace.id))
    guard
      await mounted.waitUntil({
        isVisible(measurements.spaceRevealFrames, selectedID: firstSpace.id)
          && measurements.spaceRevealFrames.selected.minX < 100
      })
    else {
      XCTFail("Programmatically selected first Space not visible")
      return
    }
    let firstPath = root.appending(path: "space-programmatic-first.png")
    try mounted.capture(to: firstPath)

    store.perform(.space(lastSpace.id))
    guard
      await mounted.waitUntil({
        isVisible(measurements.spaceRevealFrames, selectedID: lastSpace.id)
      })
    else {
      XCTFail("Programmatically selected last Space not visible")
      return
    }
    let lastPath = root.appending(path: "space-programmatic-last.png")
    try mounted.capture(to: lastPath)
    let index: [[String: Any]] = [
      [
        "phase": "initial-restored-last", "path": initialPath.path,
        "selectedSpaceID": lastSpace.id.uuidString, "spaceCount": 20,
      ],
      [
        "phase": "programmatic-first", "path": firstPath.path,
        "selectedSpaceID": firstSpace.id.uuidString, "spaceCount": 20,
      ],
      [
        "phase": "programmatic-last", "path": lastPath.path,
        "selectedSpaceID": lastSpace.id.uuidString, "spaceCount": 20,
      ],
    ]
    let data = try JSONSerialization.data(
      withJSONObject: index, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: root.appending(path: "space-capture-index.json"), options: .atomic)
  }

  private func makeStore(populated: Bool, selectedLastOrdinaryTab: Bool = false) throws
    -> BrowserStore
  {
    let profileID = stableID(10)
    let spaceID = stableID(20)
    let folderID = stableID(30)
    let favorites =
      populated
      ? (0..<3).map { index in
        BrowserFavorite(
          id: stableID(100 + index), profileID: profileID,
          originalURL: URL(string: "https://favorite-\(index).example/start")!,
          title: "Favorite \(index) — research workspace")
      }
      : []
    let favoritePages = favorites.enumerated().map { index, favorite in
      BrowserFavoritePage(
        favoriteID: favorite.id,
        tab: BrowserTab(
          id: stableID(200 + index),
          url: URL(string: "https://favorite-\(index).example/live")!,
          title: "Live Favorite \(index)"))
    }
    let pinnedTabs =
      populated
      ? (0..<4).map { index in
        BrowserTab(
          id: stableID(300 + index),
          url: URL(string: "https://pinned-\(index).example/project")!,
          title: index < 2
            ? String(repeating: "Pinned folder research reference ", count: 4) + "\(index)"
            : "Pinned tab \(index)",
          isPinned: true, folderID: index < 2 ? folderID : nil)
      }
      : []
    let ordinaryTabs =
      populated
      ? (0..<240).map { index in
        BrowserTab(
          id: stableID(1_000 + index),
          url: URL(string: "https://ordinary-\(index).example/research")!,
          title: "\(index): "
            + String(repeating: "Long ordinary tab title with useful context ", count: 3))
      }
      : []
    let space = BrowserSpace(
      id: spaceID, profileID: profileID,
      name: populated ? "Research Space" : "Personal", symbol: "house", tint: .lavender,
      tabs: pinnedTabs + ordinaryTabs,
      selectedTabID: selectedLastOrdinaryTab ? ordinaryTabs.last?.id : ordinaryTabs.first?.id,
      selectedFavoriteID: nil,
      folders: populated ? [BrowserFolder(id: folderID, name: "Research & planning")] : [])
    let session = try BrowserSession(
      profiles: [BrowserProfile(id: profileID, name: populated ? "Research Profile" : "Personal")],
      spaces: [space], selectedSpaceID: spaceID, favorites: favorites, favoritePages: favoritePages)
    return BrowserStore(session: session)
  }

  private func stableID(_ value: Int) -> UUID {
    UUID(uuidString: String(format: "30000000-0000-0000-0000-%012d", value))!
  }

  private func isVisible(_ frames: SidebarRevealFrames, selectedID: UUID) -> Bool {
    guard frames.selectedID == selectedID, !frames.selected.isEmpty, !frames.viewport.isEmpty
    else { return false }
    let visible = frames.selected.intersection(frames.viewport)
    return visible.width >= frames.selected.width - 0.5
      && visible.height >= frames.selected.height - 0.5
  }

  private func makeSpaceStore(count: Int) throws -> BrowserStore {
    let profileID = stableID(900)
    let spaces = (0..<count).map { index in
      BrowserSpace(
        id: stableID(1_900 + index), profileID: profileID, name: "Space \(index + 1)",
        symbol: "globe", tint: .ocean,
        tabs: [
          BrowserTab(
            id: stableID(2_900 + index), url: URL(string: "https://space\(index).example")!)
        ],
        selectedTabID: stableID(2_900 + index))
    }
    let session = try BrowserSession(
      profiles: [BrowserProfile(id: profileID, name: "Shared profile")], spaces: spaces,
      selectedSpaceID: spaces.last!.id)
    return BrowserStore(session: session)
  }

  private func captureView<V: View>(
    _ view: V, size: NSSize, appearance: NSAppearance.Name, to url: URL,
    measurements: CaptureMeasurements
  ) async throws -> (width: Int, height: Int) {
    let host = NSHostingView(rootView: view)
    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered,
      defer: false)
    window.isReleasedWhenClosed = false
    window.appearance = NSAppearance(named: appearance)
    window.contentView = host
    host.frame = NSRect(origin: .zero, size: size)
    defer { window.close() }

    try await Task.sleep(for: .milliseconds(100))
    host.layoutSubtreeIfNeeded()
    XCTAssertEqual(host.bounds.size, size)
    let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    XCTAssertEqual(bitmap.pixelsWide, Int(size.width))
    XCTAssertEqual(bitmap.pixelsHigh, Int(size.height))
    host.cacheDisplay(in: host.bounds, to: bitmap)
    try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(
      to: url, options: .atomic)
    XCTAssertNotNil(measurements.footerFrame)
    return (bitmap.pixelsWide, bitmap.pixelsHigh)
  }

  private func captureRow<V: View>(_ view: V, size: NSSize, to url: URL) throws
    -> (width: Int, height: Int)
  {
    let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered,
      defer: false)
    window.isReleasedWhenClosed = false
    window.appearance = NSAppearance(named: .aqua)
    window.contentView = host
    defer { window.close() }

    host.layoutSubtreeIfNeeded()
    XCTAssertFalse(window.isVisible, "Presentation capture window must remain offscreen")
    let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: bitmap)
    try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(
      to: url, options: .atomic)
    return (bitmap.pixelsWide, bitmap.pixelsHigh)
  }
}

@MainActor
private final class MountedChromeSidebar {
  private let host: NSHostingView<AnyView>
  private let window: NSWindow

  init<V: View>(view: V, size: NSSize, appearance: NSAppearance.Name) throws {
    host = NSHostingView(rootView: AnyView(view))
    window = NSWindow(
      contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered,
      defer: false)
    window.isReleasedWhenClosed = false
    window.appearance = NSAppearance(named: appearance)
    window.contentView = host
  }

  func waitUntil(_ condition: () -> Bool) async -> Bool {
    let deadline = Date(timeIntervalSinceNow: 1)
    while Date() < deadline {
      host.layoutSubtreeIfNeeded()
      if condition() { return true }
      try? await Task.sleep(for: .milliseconds(10))
    }
    return false
  }

  func capture(to url: URL) throws {
    host.layoutSubtreeIfNeeded()
    let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: bitmap)
    try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(
      to: url, options: .atomic)
  }

  func close() { window.close() }
}
