import AppKit
import BrowserCore
import SwiftUI
import XCTest

@testable import ArcusisBrowser

@MainActor
final class LibraryDrawerTests: XCTestCase {
  func testRepeatedSectionChangesAndCloseClearDrawerState() {
    let store = BrowserStore()
    for section in LibraryDrawerSection.allCases {
      XCTAssertTrue(store.showLibraryDrawer(section))
      XCTAssertEqual(store.libraryDrawerSection, section)
      store.closeLibraryDrawer()
      XCTAssertNil(store.libraryDrawerSection)
      XCTAssertNil(store.libraryDrawerProfileID)
    }
  }

  func testSelectingEverySectionUpdatesDrawerAndProfile() {
    let store = BrowserStore()
    XCTAssertTrue(store.toggleLibraryDrawer())
    for section in LibraryDrawerSection.allCases {
      XCTAssertTrue(store.selectLibraryDrawerSection(section))
      XCTAssertEqual(store.libraryDrawerSection, section)
      XCTAssertEqual(
        store.libraryDrawerProfileID,
        section == .spaces ? nil : store.session.selectedSpace.profileID)
    }
  }

  func testDrawerToggleAndPresentationStateBelongToEachWindow() {
    let first = BrowserStore()
    let second = BrowserStore()

    XCTAssertTrue(first.toggleLibraryDrawer())
    XCTAssertEqual(first.libraryDrawerSection, .downloads)
    XCTAssertNil(second.libraryDrawerSection)

    XCTAssertTrue(first.selectLibraryDrawerSection(.downloads))
    XCTAssertEqual(first.libraryDrawerProfileID, first.session.selectedSpace.profileID)
    XCTAssertNil(second.libraryDrawerProfileID)
    XCTAssertTrue(first.toggleLibraryDrawer())
    XCTAssertNil(first.libraryDrawerSection)
    XCTAssertNil(first.libraryDrawerProfileID)
  }

  func testProfileSwitchClosesCapturedDownloadsAndRejectsStaleSpaceActions() throws {
    let (session, ids) = makeFixtureSession()
    let store = BrowserStore(sessionFile: nil, session: session)
    XCTAssertTrue(store.showLibraryDrawer(.downloads))
    XCTAssertEqual(store.libraryDrawerProfileID, ids.primaryProfile)

    store.perform(.space(ids.otherProfileSpace))
    XCTAssertNil(store.libraryDrawerSection)
    XCTAssertNil(store.libraryDrawerProfileID)

    XCTAssertTrue(store.showLibraryDrawer(.spaces))
    XCTAssertFalse(store.selectLibrarySpace(ids.emptySpace, expectedProfileID: ids.otherProfile))
    XCTAssertFalse(
      store.selectLibraryTab(
        ids.primaryTab, in: ids.primarySpace, expectedProfileID: ids.otherProfile))
    XCTAssertTrue(store.removeSpace(ids.emptySpace))
    XCTAssertFalse(store.selectLibrarySpace(ids.emptySpace, expectedProfileID: ids.primaryProfile))
  }

  func testSpaceAndTabActionsCloseDrawerBeforeSelectingCurrentIDs() {
    let (session, ids) = makeFixtureSession()
    let store = BrowserStore(sessionFile: nil, session: session)
    XCTAssertTrue(store.showLibraryDrawer(.spaces))
    XCTAssertTrue(
      store.selectLibraryTab(
        ids.otherTab, in: ids.otherProfileSpace, expectedProfileID: ids.otherProfile))
    XCTAssertNil(store.libraryDrawerSection)
    XCTAssertEqual(store.session.selectedSpaceID, ids.otherProfileSpace)
    XCTAssertEqual(store.session.selectedSpace.selectedTabID, ids.otherTab)
  }

  func testCommandModalAndConsentConflictsDismissOrRejectDrawer() throws {
    let (session, ids) = makeFixtureSession()
    let store = BrowserStore(sessionFile: nil, session: session)
    XCTAssertTrue(store.showLibraryDrawer(.spaces))
    store.showPageFind()
    XCTAssertNil(store.libraryDrawerSection)
    XCTAssertNotNil(store.pageFind)
    XCTAssertTrue(store.showLibraryDrawer(.spaces))
    XCTAssertNil(store.pageFind)
    store.closeLibraryDrawer()
    XCTAssertTrue(store.showLibraryDrawer(.spaces))
    store.showCommand()
    XCTAssertNil(store.libraryDrawerSection)
    XCTAssertFalse(store.toggleLibraryDrawer())
    store.dismissCommand()

    XCTAssertTrue(store.showLibraryDrawer(.media))
    store.showDownloads()
    XCTAssertNil(store.libraryDrawerSection)
    guard case .downloads(let profileID)? = store.sheet else {
      XCTFail("Downloads modal was not preserved")
      return
    }
    XCTAssertEqual(profileID, ids.primaryProfile)
    store.sheet = nil

    let request = try XCTUnwrap(
      WebsitePermissionRequest(
        id: "drawer-consent", profileID: ids.primaryProfile, tabID: ids.primaryTab,
        pageURL: URL(string: "https://example.test/notes")!,
        requestingOrigin: URL(string: "https://example.test")!, kinds: [.camera]))
    XCTAssertTrue(store.requestWebsitePermission(request))
    XCTAssertFalse(store.showLibraryDrawer(.spaces))
    XCTAssertEqual(store.sheet?.id, "permission-drawer-consent")
  }

  func testCapturesActualWindowDrawerAtStandardMinimumDarkAndHiddenSidebarSizes() async throws {
    let root = URL(fileURLWithPath: "/tmp/browser-library-drawer-captures", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let cases: [(String, CGFloat, CGFloat, NSAppearance.Name, Bool)] = [
      ("library-drawer-normal.png", 1200, 780, .aqua, true),
      ("library-drawer-minimum.png", 760, 520, .aqua, true),
      ("library-drawer-dark.png", 1200, 780, .darkAqua, true),
      ("library-drawer-hidden-sidebar.png", 1000, 700, .aqua, false),
    ]

    for (name, width, height, appearance, sidebarVisible) in cases {
      let (session, _) = makeFixtureSession()
      let store = BrowserStore(sessionFile: nil, session: session)
      store.sidebarIsVisible = sidebarVisible
      XCTAssertTrue(store.showLibraryDrawer(.spaces))
      let view = BrowserWindow(store: store)
        .environment(\.colorScheme, appearance == .darkAqua ? .dark : .light)
      try await capture(
        view, size: NSSize(width: width, height: height), appearance: appearance,
        to: root.appending(path: name))
    }

    for section in [LibraryDrawerSection.downloads, .media] {
      let (session, _) = makeFixtureSession()
      let store = BrowserStore(sessionFile: nil, session: session)
      XCTAssertTrue(store.showLibraryDrawer(section))
      try await capture(
        BrowserWindow(store: store).environment(\.colorScheme, .dark),
        size: NSSize(width: 1200, height: 780), appearance: .darkAqua,
        to: root.appending(path: "library-drawer-\(section.rawValue.lowercased()).png"))
    }

    for (name, _, _, _, _) in cases {
      XCTAssertTrue(FileManager.default.fileExists(atPath: root.appending(path: name).path))
    }
  }

  private func makeFixtureSession() -> (BrowserSession, FixtureIDs) {
    let primary = BrowserProfile(name: "Personal")
    let other = BrowserProfile(name: "Research")
    let primaryTab = BrowserTab(
      url: URL(string: "https://example.test/notes")!, title: "Project notes")
    let otherTab = BrowserTab(
      url: URL(string: "https://archive.example.test/report")!, title: "Archived report")
    let primarySpace = BrowserSpace(
      profileID: primary.id, name: "Studio", symbol: "paintpalette", tint: .forest,
      tabs: [primaryTab])
    let emptySpace = BrowserSpace(
      profileID: primary.id, name: "Quiet space", symbol: "sparkles", tint: .lavender)
    let otherSpace = BrowserSpace(
      profileID: other.id, name: "Research", symbol: "magnifyingglass", tint: .rose,
      tabs: [otherTab])
    let session = try! BrowserSession(
      profiles: [primary, other], spaces: [primarySpace, emptySpace, otherSpace],
      selectedSpaceID: primarySpace.id)
    return (
      session,
      FixtureIDs(
        primaryProfile: primary.id, otherProfile: other.id, primarySpace: primarySpace.id,
        emptySpace: emptySpace.id, otherProfileSpace: otherSpace.id, primaryTab: primaryTab.id,
        otherTab: otherTab.id)
    )
  }

  private func capture<V: View>(
    _ view: V, size: NSSize, appearance: NSAppearance.Name, to url: URL
  ) async throws {
    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered,
      defer: false)
    window.isReleasedWhenClosed = false
    window.appearance = NSAppearance(named: appearance)
    defer { window.close() }
    let host = NSHostingView(rootView: view)
    window.contentView = host
    host.frame = NSRect(origin: .zero, size: size)
    try await Task.sleep(for: .milliseconds(80))
    host.layoutSubtreeIfNeeded()
    XCTAssertEqual(host.bounds.size, size)
    _ = try VisualCapture.render(host, to: url)
  }
}

private struct FixtureIDs {
  let primaryProfile: UUID
  let otherProfile: UUID
  let primarySpace: UUID
  let emptySpace: UUID
  let otherProfileSpace: UUID
  let primaryTab: UUID
  let otherTab: UUID
}
