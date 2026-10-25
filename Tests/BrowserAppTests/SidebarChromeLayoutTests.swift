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

  private func makeStore(populated: Bool) throws -> BrowserStore {
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
      tabs: pinnedTabs + ordinaryTabs, selectedTabID: ordinaryTabs.first?.id,
      selectedFavoriteID: favoritePages.first?.favoriteID,
      folders: populated ? [BrowserFolder(id: folderID, name: "Research & planning")] : [])
    let session = try BrowserSession(
      profiles: [BrowserProfile(id: profileID, name: populated ? "Research Profile" : "Personal")],
      spaces: [space], selectedSpaceID: spaceID, favorites: favorites, favoritePages: favoritePages)
    return BrowserStore(session: session)
  }

  private func stableID(_ value: Int) -> UUID {
    UUID(uuidString: String(format: "30000000-0000-0000-0000-%012d", value))!
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
}
