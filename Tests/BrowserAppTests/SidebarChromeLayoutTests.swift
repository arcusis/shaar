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
        received: 1024, total: 1024, startTime: Date().timeIntervalSince1970))
    let root = URL(fileURLWithPath: "/tmp/browser-sidebar-chrome", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let captures: [(String, CGFloat, CGFloat, ColorScheme, SidebarFolderDraft?, Bool)] = [
      (
        "sidebar-minimum-width-minimum-height.png", BrowserChromeLayout.sidebarWidth, 520,
        .light, nil, false
      ),
      ("sidebar-standard-width.png", BrowserChromeLayout.sidebarWidth, 760, .light, nil, false),
      ("sidebar-standard-dark.png", BrowserChromeLayout.sidebarWidth, 760, .dark, nil, false),
      (
        "sidebar-recent-files.png", BrowserChromeLayout.sidebarWidth, 520, .light, nil, true
      ),
      (
        "sidebar-inline-folder.png", BrowserChromeLayout.sidebarWidth, 760, .light,
        SidebarFolderDraft(route: .create(spaceID: spaceID, parentID: folderID)), false
      ),
    ]

    for (name, width, height, scheme, draft, showsDownloads) in captures {
      try await capture(
        BrowserSidebar(
          store: store, previewRecentDownloads: showsDownloads ? [download] : nil,
          previewFolderDraft: draft
        )
        .frame(width: width, height: height)
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(\.colorScheme, scheme),
        size: NSSize(width: width, height: height), to: root.appending(path: name))
    }

    let captureIndex: [[String: Any]] = captures.map {
      name, width, height, scheme, _, showsDownloads in
      [
        "name": name,
        "width": width,
        "height": height,
        "colorScheme": scheme == .dark ? "dark" : "light",
        "includesRecentFileCard": showsDownloads,
        "sidebarWidth": BrowserChromeLayout.sidebarWidth,
      ]
    }
    let index = try JSONSerialization.data(
      withJSONObject: captureIndex, options: [.prettyPrinted, .sortedKeys])
    try index.write(to: root.appending(path: "capture-index.json"), options: .atomic)
  }

  private func capture<V: View>(_ view: V, size: NSSize, to url: URL) async throws {
    let host = NSHostingView(rootView: view)
    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered,
      defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    defer { window.close() }

    try await Task.sleep(for: .milliseconds(80))
    host.layoutSubtreeIfNeeded()
    let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: bitmap)
    try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(
      to: url, options: .atomic)
  }
}
