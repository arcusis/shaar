// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import BrowserCore
import SwiftUI
import XCTest

@testable import ArcusisBrowser

@MainActor
final class LibrarySpacesOverviewTests: XCTestCase {
  func testSpaceSelectionAccessibilityTraitTracksSelection() {
    XCTAssertTrue(LibrarySpacesOverview.spaceSelectionTraits(isSelected: true).contains(.isSelected))
    XCTAssertFalse(
      LibrarySpacesOverview.spaceSelectionTraits(isSelected: false).contains(.isSelected))
  }

  func testFolderSearchPathBenchmark() throws {
    let profile = BrowserProfile(name: "Scale")
    let folders = (0..<300).map { index in
      BrowserFolder(name: "Folder \(index)", isPinned: index.isMultiple(of: 2))
    }
    let tabs = (0..<3_000).map { index in
      BrowserTab(
        url: URL(string: "https://example.test/\(index)")!, title: "Tab \(index)",
        isPinned: index.isMultiple(of: 2), folderID: folders[index % folders.count].id)
    }
    let space = BrowserSpace(
      profileID: profile.id, name: "Main", symbol: "house", tint: .ocean,
      tabs: tabs, folders: folders)
    let session = try BrowserSession(
      profiles: [profile], spaces: [space], selectedSpaceID: space.id)

    let start = ContinuousClock.now
    var count = 0
    for _ in 0..<10 {
      count += LibrarySpacesOverviewModel.cards(in: session, query: "Folder 299").count
    }
    print("folderSearchPathBenchmark: \(start.duration(to: .now))")
    XCTAssertEqual(count, 10)
  }

  func testFolderPathLookupPreservesMatchingAncestry() throws {
    let profile = BrowserProfile(name: "Daily")
    let folderIDs = (0..<150).map { _ in UUID() }
    let folders = folderIDs.enumerated().map { index, id in
      BrowserFolder(
        id: id, name: "Folder \(index)", parentID: index == 0 ? nil : folderIDs[index - 1],
        isPinned: false)
    }
    let tabs = (0..<500).map { index in
      BrowserTab(
        url: URL(string: "https://example.com/\(index)")!, title: "Needle page \(index)",
        isPinned: false, folderID: folderIDs[index % folderIDs.count])
    }
    let space = BrowserSpace(
      profileID: profile.id, name: "Work", symbol: "tray", tint: .ocean,
      tabs: tabs, folders: folders)
    let session = try BrowserSession(
      profiles: [profile], spaces: [space], selectedSpaceID: space.id)

    let start = ContinuousClock.now
    for _ in 0..<10 {
      _ = LibrarySpacesOverviewModel.cards(in: session, query: "Folder 149")
    }
    print("librarySpacesFolderPathBenchmark: \(start.duration(to: .now))")

    let card = try XCTUnwrap(LibrarySpacesOverviewModel.cards(in: session, query: "Folder 149").first)
    let expectedItemIDs = Set(
      folderIDs.map { "folder-\($0)" }
        + [149, 299, 449].map { "tab-\(tabs[$0].id)" })
    XCTAssertEqual(Set(card.items.map(\.id)), expectedItemIDs)
  }

  func testTodayFoldersAndNestedTabsAppearInSpaceCard() throws {
    let profile = BrowserProfile(name: "Daily")
    let folder = BrowserFolder(name: "Reading list", isPinned: false)
    let tab = BrowserTab(
      url: URL(string: "https://example.com/article")!, title: "Article", folderID: folder.id)
    let space = BrowserSpace(
      profileID: profile.id, name: "Daily", symbol: "book", tint: .ocean,
      tabs: [tab], folders: [folder])
    let session = try BrowserSession(
      profiles: [profile], spaces: [space], selectedSpaceID: space.id)

    let card = try XCTUnwrap(LibrarySpacesOverviewModel.cards(in: session, query: "").first)
    XCTAssertEqual(card.items.count, 2)
    guard case .folder(let shownFolder, let folderDepth) = card.items[0],
      case .tab(let shownTab, let tabDepth) = card.items[1]
    else { return XCTFail("Today folder and nested tab should appear in order") }
    XCTAssertEqual(shownFolder.id, folder.id)
    XCTAssertEqual(folderDepth, 0)
    XCTAssertEqual(shownTab.id, tab.id)
    XCTAssertEqual(tabDepth, 1)

    let match = try XCTUnwrap(
      LibrarySpacesOverviewModel.cards(in: session, query: "Reading list").first)
    XCTAssertEqual(match.items.count, 2)
  }

  func testSearchMatchesSpaceProfileFolderTitleAndURL() throws {
    let (session, ids) = makeSession()

    XCTAssertEqual(
      LibrarySpacesOverviewModel.cards(in: session, query: "long project").map(\.id),
      [ids.longSpace])
    XCTAssertEqual(
      LibrarySpacesOverviewModel.cards(in: session, query: "Separate Account").map(\.id),
      [ids.separateSpace])
    XCTAssertEqual(
      LibrarySpacesOverviewModel.cards(in: session, query: "Research folder").map(\.id),
      [ids.longSpace])
    XCTAssertEqual(
      LibrarySpacesOverviewModel.cards(in: session, query: "needle.example/path").map(\.id),
      [ids.longSpace])
    XCTAssertTrue(
      LibrarySpacesOverviewModel.cards(in: session, query: "no matching content").isEmpty)
    XCTAssertEqual(LibrarySpacesOverviewModel.cards(in: session, query: "").count, 3)
  }

  func testTodayFolderAndItsTabKeepTheirHierarchyInSpaceCard() throws {
    let profile = BrowserProfile(name: "Daily")
    let folder = BrowserFolder(name: "Today's work", isPinned: false)
    let tab = BrowserTab(
      url: URL(string: "https://example.com/today")!, title: "Today page",
      isPinned: false, folderID: folder.id)
    let space = BrowserSpace(
      profileID: profile.id, name: "Work", symbol: "tray", tint: .ocean,
      tabs: [tab], selectedTabID: tab.id, folders: [folder])
    let session = try BrowserSession(
      profiles: [profile], spaces: [space], selectedSpaceID: space.id)

    let items = try XCTUnwrap(LibrarySpacesOverviewModel.cards(in: session, query: "").first).items
    XCTAssertEqual(items.map(\.id), ["folder-\(folder.id)", "tab-\(tab.id)"])
    if case .tab(_, let depth) = items.last {
      XCTAssertEqual(depth, 1)
    } else {
      XCTFail("Expected tab inside Today folder")
    }
  }

  func testSearchForTodayTabKeepsItsFolderContext() throws {
    let profile = BrowserProfile(name: "Daily")
    let parent = BrowserFolder(name: "Projects", isPinned: false)
    let child = BrowserFolder(name: "Notes", parentID: parent.id, isPinned: false)
    let tab = BrowserTab(
      url: URL(string: "https://example.com/needle")!, title: "Needle page",
      isPinned: false, folderID: child.id)
    let space = BrowserSpace(
      profileID: profile.id, name: "Work", symbol: "tray", tint: .ocean,
      tabs: [tab], selectedTabID: tab.id, folders: [parent, child])
    let session = try BrowserSession(
      profiles: [profile], spaces: [space], selectedSpaceID: space.id)

    let expected = ["folder-\(parent.id)", "folder-\(child.id)", "tab-\(tab.id)"]
    XCTAssertEqual(
      LibrarySpacesOverviewModel.cards(in: session, query: "Needle").first?.items.map(\.id),
      expected)
    XCTAssertEqual(
      LibrarySpacesOverviewModel.cards(in: session, query: "Projects").first?.items.map(\.id),
      expected)
  }

  func testTabAccessibilityLabelFallsBackForWhitespaceOnlyTitles() {
    let address = "https://example.com/page"
    XCTAssertEqual(
      LibrarySpaceItemsAccessibility.tabLabel(title: "", address: address),
      address)
    XCTAssertEqual(
      LibrarySpaceItemsAccessibility.tabLabel(title: " \n\t", address: address),
      address)
    XCTAssertEqual(LibrarySpaceItemsAccessibility.tabLabel(title: address, address: address), address)
    XCTAssertEqual(
      LibrarySpaceItemsAccessibility.tabLabel(title: " Article ", address: address),
      " Article , \(address)")
  }

  func testSearchRetainsNestedFolderContextForMatchingTabOrParentFolder() throws {
    let profile = BrowserProfile(name: "Daily")
    let parent = BrowserFolder(name: "Research")
    let child = BrowserFolder(name: "Reports", parentID: parent.id)
    let tab = BrowserTab(
      url: URL(string: "https://example.com/report")!, title: "Quarterly results",
      isPinned: true, folderID: child.id)
    let space = BrowserSpace(
      profileID: profile.id, name: "Work", symbol: "tray", tint: .ocean,
      tabs: [tab], selectedTabID: tab.id, folders: [parent, child])
    let session = try BrowserSession(
      profiles: [profile], spaces: [space], selectedSpaceID: space.id)
    let expected = ["folder-\(parent.id)", "folder-\(child.id)", "tab-\(tab.id)"]

    XCTAssertEqual(
      LibrarySpacesOverviewModel.cards(in: session, query: "Quarterly").first?.items.map(\.id),
      expected)
    XCTAssertEqual(
      LibrarySpacesOverviewModel.cards(in: session, query: "Research").first?.items.map(\.id),
      expected)
  }

  func testCapturedCallbacksRejectRemovedOrReassignedSpaceAndTab() throws {
    let (session, ids) = makeSession()
    let liveSpace = session.spaces.first { $0.id == ids.longSpace }!
    let tabID = liveSpace.tabs.last!.id
    XCTAssertTrue(
      LibrarySpacesOverviewModel.canEdit(
        spaceID: ids.longSpace, profileID: ids.sharedProfile, in: session))
    XCTAssertTrue(
      LibrarySpacesOverviewModel.canSelectTab(
        spaceID: ids.longSpace, profileID: ids.sharedProfile, tabID: tabID, in: session))
    XCTAssertFalse(
      LibrarySpacesOverviewModel.canEdit(
        spaceID: ids.longSpace, profileID: ids.separateProfile, in: session))
    var reassignedSpaces = session.spaces
    let reassigned = BrowserSpace(
      id: liveSpace.id, profileID: ids.separateProfile, name: liveSpace.name,
      symbol: liveSpace.symbol, tint: liveSpace.tint, customRGB: liveSpace.customRGB,
      tabs: liveSpace.tabs, selectedTabID: liveSpace.selectedTabID,
      selectedFavoriteID: liveSpace.selectedFavoriteID, folders: liveSpace.folders)
    reassignedSpaces[reassignedSpaces.firstIndex { $0.id == ids.longSpace }!] = reassigned
    let reassignedSession = try BrowserSession(
      profiles: session.profiles, spaces: reassignedSpaces, selectedSpaceID: ids.longSpace)
    XCTAssertFalse(
      LibrarySpacesOverviewModel.canSelectSpace(
        spaceID: ids.longSpace, profileID: ids.sharedProfile, in: reassignedSession))
    XCTAssertFalse(
      LibrarySpacesOverviewModel.canEdit(
        spaceID: ids.longSpace, profileID: ids.sharedProfile, in: reassignedSession))
    XCTAssertFalse(
      LibrarySpacesOverviewModel.canSelectTab(
        spaceID: ids.longSpace, profileID: ids.sharedProfile, tabID: tabID, in: reassignedSession))
    XCTAssertFalse(
      LibrarySpacesOverviewModel.canSelectTab(
        spaceID: ids.emptySpace, profileID: ids.sharedProfile, tabID: tabID, in: session))

    let removedSpace = try BrowserSession(
      profiles: session.profiles,
      spaces: session.spaces.filter { $0.id != ids.longSpace },
      selectedSpaceID: ids.emptySpace)
    XCTAssertFalse(
      LibrarySpacesOverviewModel.canEdit(
        spaceID: ids.longSpace, profileID: ids.sharedProfile, in: removedSpace))
    XCTAssertFalse(
      LibrarySpacesOverviewModel.canSelectTab(
        spaceID: ids.longSpace, profileID: ids.sharedProfile, tabID: tabID, in: removedSpace))
  }

  func testActualOverviewFitsMinimumWindowWithEmptyLongAndManyTabSpaces() throws {
    let (session, _) = makeSession()
    let store = BrowserStore(sessionFile: nil, session: session)
    let output = URL(filePath: "/tmp/browser-library-spaces-overview")
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

    for (name, scheme, query) in [
      ("light", ColorScheme.light, ""),
      ("dark", ColorScheme.dark, ""),
      ("url-search", ColorScheme.light, "needle.example/path"),
    ] {
      let view = LibrarySpacesOverview(
        store: store,
        query: query,
        onSelectSpace: { _ in },
        onSelectTab: { _, _ in },
        onEditSpace: { _ in },
        onCreateSpace: {}
      )
      .environment(\.colorScheme, scheme)
      try capture(
        view, size: NSSize(width: 760, height: 520), to: output.appending(path: "\(name).png"))
    }

    for image in ["light.png", "dark.png", "url-search.png"] {
      XCTAssertTrue(FileManager.default.fileExists(atPath: output.appending(path: image).path))
    }
  }
}

private struct SessionIDs {
  let sharedProfile: UUID
  let separateProfile: UUID
  let emptySpace: UUID
  let longSpace: UUID
  let separateSpace: UUID
}

private func makeSession() -> (BrowserSession, SessionIDs) {
  let sharedProfile = BrowserProfile(name: "Daily Profile")
  let separateProfile = BrowserProfile(name: "Separate Account")
  let emptySpace = BrowserSpace(
    profileID: sharedProfile.id, name: "Empty", symbol: "tray", tint: .lavender)
  let folder = BrowserFolder(name: "Research folder")
  let tabs = (0..<80).map { index in
    BrowserTab(
      url: URL(string: "https://needle.example/path/\(index)")!,
      title: index == 0
        ? "A very long project name for testing wrapping inside a narrow native Space card"
        : "Research page \(index)",
      isPinned: index < 4,
      folderID: index < 4 ? folder.id : nil)
  }
  let longSpace = BrowserSpace(
    profileID: sharedProfile.id,
    name: "Long named research and planning Space for a large project",
    symbol: "sparkles.rectangle.stack",
    tint: .ocean,
    tabs: tabs,
    selectedTabID: tabs[0].id,
    folders: [folder])
  let separateSpace = BrowserSpace(
    profileID: separateProfile.id, name: "Account Space", symbol: "person.crop.square", tint: .rose)
  let session = try! BrowserSession(
    profiles: [sharedProfile, separateProfile],
    spaces: [emptySpace, longSpace, separateSpace],
    selectedSpaceID: longSpace.id)
  return (
    session,
    SessionIDs(
      sharedProfile: sharedProfile.id,
      separateProfile: separateProfile.id,
      emptySpace: emptySpace.id,
      longSpace: longSpace.id,
      separateSpace: separateSpace.id)
  )
}

@MainActor
private func capture<V: View>(_ view: V, size: NSSize, to url: URL) throws {
  let window = NSWindow(
    contentRect: NSRect(origin: .zero, size: size), styleMask: [], backing: .buffered,
    defer: false)
  window.isReleasedWhenClosed = false
  defer { window.close() }
  let host = NSHostingView(rootView: view)
  window.contentView = host
  host.frame = NSRect(origin: .zero, size: size)
  host.layoutSubtreeIfNeeded()
  window.displayIfNeeded()
  RunLoop.current.run(until: Date().addingTimeInterval(0.05))
  host.layoutSubtreeIfNeeded()
  let bounds = host.bounds
  XCTAssertEqual(bounds.size, size)
  _ = try VisualCapture.render(host, to: url)
}
