import AppKit
import BrowserCore
import ChromiumBridge
import Foundation

private struct NativeFavoritePageProof: Codable, Equatable {
  let favoriteID: UUID
  let tabID: UUID
  let url: String
}

private struct NativeFavoritesCheckpoint: Codable {
  let profileIDs: [UUID]
  let windowIDs: [UUID]
  let favoriteIDs: [UUID]
  let favoriteURLs: [String]
  let firstWindowPages: [NativeFavoritePageProof]
  let secondWindowPages: [NativeFavoritePageProof]
  let firstWindowFavoriteOrder: [UUID]
  let workspaceVersion: Int
  let sessionVersions: [Int]
}

/// Exercises shared Favorite definitions against production native windows in a disposable workspace.
@MainActor
final class NativeFavoritesProbe {
  private let primary: BrowserEngine
  private let root: URL
  private let fixture: URL
  private let phase: String
  private let directory: URL
  private let lock: WorkspaceProcessLock
  private let file: WorkspaceFile
  private var workspace: BrowserWorkspaceStore?
  private var host: NativeBrowserHost?
  private var closures: [UUID: Bool] = [:]
  private var checks: [String] = []
  private var callbackURLs: [String: String] = [:]
  private var callbackLoading: [String: Bool] = [:]
  private var documentCommits: [String: Int] = [:]
  private var documentStatus: [String: String] = [:]
  private var acceptanceDetails: [String: [String: Bool]] = [:]
  private var expectedAfterQuit: BrowserWorkspace?
  private var failure: Error?

  var passed: Bool { failure == nil }

  init(primary: BrowserEngine, root: URL, fixture: URL, phase: String) throws {
    self.primary = primary
    self.root = root
    self.fixture = fixture
    self.phase = phase
    directory = root.appending(path: "native-favorites-workspace")
    lock = try WorkspaceProcessLock(directory: directory)
    file = WorkspaceFile(
      url: directory.appending(path: "workspace.json"),
      legacySessionURL: directory.appending(path: "session.json"))
  }

  func run() async throws -> [String] {
    let previousChanged = primary.runtime.onTabChanged
    let previousCommitted = primary.runtime.onDocumentCommitted
    primary.runtime.onTabChanged = { [weak self] id, url, title, loading, back, forward in
      previousChanged?(id, url, title, loading, back, forward)
      guard let self else { return }
      self.callbackURLs[id] = url
      self.callbackLoading[id] = loading
    }
    primary.runtime.onDocumentCommitted = { [weak self] id, profile in
      previousCommitted?(id, profile)
      guard let self else { return }
      self.documentCommits[id, default: 0] += 1
    }
    defer {
      primary.runtime.onTabChanged = previousChanged
      primary.runtime.onDocumentCommitted = previousCommitted
    }
    do {
      try await exercise()
      try report(error: failure)
      return checks
    } catch {
      failure = failure ?? error
      try? report(error: failure)
      throw error
    }
  }

  private func exercise() async throws {
    let manager: BrowserWorkspaceStore
    if phase == "initial" {
      let alpha = BrowserProfile(name: "Favorites Alpha")
      let beta = BrowserProfile(name: "Favorites Beta")
      let alphaTarget = fixture.appending(path: "native-favorite-alpha-target")
      let alphaPeer = fixture.appending(path: "native-favorite-alpha-peer")
      let sharedPeer = fixture.appending(path: "native-favorite-shared-peer")
      let betaPeer = fixture.appending(path: "native-favorite-beta-peer")
      let spaces = [
        BrowserSpace(
          profileID: alpha.id, name: "Favorites Alpha One", symbol: "house", tint: .lavender,
          tabs: [BrowserTab(url: alphaTarget), BrowserTab(url: alphaPeer)]),
        BrowserSpace(
          profileID: alpha.id, name: "Favorites Alpha Two", symbol: "square.stack", tint: .forest,
          tabs: [BrowserTab(url: sharedPeer)]),
        BrowserSpace(
          profileID: beta.id, name: "Favorites Beta", symbol: "briefcase", tint: .ocean,
          tabs: [BrowserTab(url: betaPeer)]),
      ]
      let session = try BrowserSession(
        profiles: [alpha, beta], spaces: spaces, selectedSpaceID: spaces[0].id)
      manager = try BrowserWorkspaceStore(file: file, initialSession: session)
    } else {
      manager = try BrowserWorkspaceStore(file: file)
    }
    workspace = manager
    let host = NativeBrowserHost(
      events: primary.events, workspace: manager, presentation: .hiddenProbe,
      usesPrimaryWindow: false, keyWindow: { [weak self] in self?.focusedWindow },
      screens: { [NSRect(x: 0, y: 0, width: 1920, height: 1080)] })
    self.host = host
    host.onClosed = { [weak self] id, quitting in self?.closures[id] = quitting }
    try host.restore()
    if phase == "initial" {
      try await exerciseInitial(manager, host: host)
    } else {
      try await exerciseRestart(manager, host: host)
    }
    try expect(
      host.lastError == nil && manager.storageNotice == nil
        && host.contexts.values.allSatisfy { !$0.window.isVisible },
      "favorite workspace has no storage or native host errors and keeps every window hidden")
  }

  private var focusedWindow: NSWindow? {
    guard let id = workspace?.workspace.focusedWindowID else { return nil }
    return host?.contexts[id]?.window
  }

  private func exerciseInitial(_ manager: BrowserWorkspaceStore, host: NativeBrowserHost)
    async throws
  {
    guard let firstID = manager.workspace.windows.first?.id,
      let first = host.contexts[firstID], first.store.session.spaces.count == 3
    else { throw NativeFavoritesFailure("Initial owned favorite window missing.") }
    let spaces = first.store.session.spaces
    let alphaOne = spaces[0]
    let alphaTwo = spaces[1]
    let betaSpace = spaces[2]
    let target = alphaOne.tabs[0].id
    let peer = alphaOne.tabs[1].id
    let sharedPeer = alphaTwo.tabs[0].id
    let betaPeer = betaSpace.tabs[0].id
    let profileAlpha = alphaOne.profileID
    first.store.perform(.tab(space: alphaOne.id, tab: target))
    _ = try await document(target)
    first.store.perform(.tab(space: alphaOne.id, tab: peer))
    _ = try await document(peer)
    first.store.perform(.tab(space: alphaTwo.id, tab: sharedPeer))
    _ = try await document(sharedPeer)
    first.store.perform(.tab(space: betaSpace.id, tab: betaPeer))
    _ = try await document(betaPeer)
    first.store.perform(.tab(space: alphaOne.id, tab: target))
    try await setCookie("favorites=alpha", in: target)
    first.store.perform(.tab(space: alphaOne.id, tab: peer))
    try await setCookie("favorites=alpha", in: peer)
    first.store.perform(.tab(space: alphaTwo.id, tab: sharedPeer))
    try await setCookie("favorites=alpha", in: sharedPeer)
    first.store.perform(.tab(space: betaSpace.id, tab: betaPeer))
    try await setCookie("favorites=beta", in: betaPeer)
    first.store.perform(.tab(space: alphaOne.id, tab: target))
    let targetBefore = try await document(target)
    first.store.perform(.tab(space: alphaOne.id, tab: peer))
    let peerBefore = try await document(peer)
    first.store.perform(.tab(space: betaSpace.id, tab: betaPeer))
    let betaBefore = try await document(betaPeer)
    let firstNativeID = primary.runtime.nativeTabID(forID: target.uuidString)
    let firstWindowNativeID = first.nativeID
    try expect(
      targetBefore["cookie"] as? String == "favorites=alpha"
        && peerBefore["cookie"] as? String == "favorites=alpha"
        && betaBefore["cookie"] as? String == "favorites=beta",
      "two independent native Profiles retain separate authored loopback cookies")

    first.store.perform(.tab(space: alphaOne.id, tab: target))
    let original = first.store.session.selectedSpace.selectedTab!.url
    try expect(
      first.store.canFavoriteCurrentPage && first.store.addCurrentPageAsFavorite(),
      "owned native page promotes to one Profile Favorite")
    guard
      let firstFavorite = first.store.session.favorites.first(where: {
        $0.profileID == profileAlpha
      }),
      let promoted = first.store.session.favoritePages.first(where: {
        $0.favoriteID == firstFavorite.id
      })
    else { throw NativeFavoritesFailure("Promotion did not create a live Favorite page.") }
    let promotedDocument = try await document(promoted.tab.id)
    try expect(
      promoted.tab.id == target
        && primary.runtime.nativeTabID(forID: target.uuidString) == firstNativeID
        && primary.runtime.windowID(forTabID: target.uuidString) == firstWindowNativeID
        && promoted.tab.url == original
        && promotedDocument["instance"] as? String == targetBefore["instance"] as? String,
      "promotion preserves native tab UUID, window owner, URL, and document nonce")
    try expect(
      first.store.profileFavorites.map(\.id) == [firstFavorite.id]
        && first.store.session.selectedPage?.tab.id == target,
      "selected promoted page and Profile Favorite catalog point to same live native tab")

    first.store.perform(.space(alphaTwo.id))
    let commitsBeforeShare = documentCommits[target.uuidString, default: 0]
    try expect(
      first.store.selectFavorite(firstFavorite.id),
      "same Profile Favorite selects from second Space")
    let sharedPage = first.store.session.favoritePages.first { $0.favoriteID == firstFavorite.id }!
    let sharedDocument = try await document(sharedPage.tab.id)
    try expect(
      sharedPage.tab.id == target
        && sharedDocument["instance"] as? String == targetBefore["instance"] as? String
        && documentCommits[target.uuidString, default: 0] == commitsBeforeShare,
      "same-window Spaces share Favorite native page without document reload")

    first.store.perform(.space(betaSpace.id))
    try expect(
      first.store.profileFavorites.isEmpty && !first.store.selectFavorite(firstFavorite.id),
      "unrelated Profile sees no Alpha Favorite and rejects cross-Profile selection")
    first.store.perform(.space(alphaOne.id))
    first.store.perform(.tab(space: alphaOne.id, tab: peer))
    try expect(
      first.store.addCurrentPageAsFavorite(), "same-Profile peer promotes to second Favorite")
    let secondFavorite = first.store.session.favorites.first { $0.id != firstFavorite.id }!
    first.store.perform(.space(alphaTwo.id))
    first.store.perform(.tab(space: alphaTwo.id, tab: sharedPeer))
    try expect(first.store.addCurrentPageAsFavorite(), "second Space promotes to third Favorite")
    let thirdFavorite = first.store.session.favorites.first {
      $0.id != firstFavorite.id && $0.id != secondFavorite.id
    }!
    try expect(
      first.store.moveFavorite(thirdFavorite.id, before: secondFavorite.id)
        && first.store.profileFavorites.map(\.id) == [
          firstFavorite.id, thirdFavorite.id, secondFavorite.id,
        ],
      "Favorite order updates Profile-wide across Spaces")

    first.store.perform(.space(alphaOne.id))
    try expect(
      first.store.selectFavorite(firstFavorite.id),
      "original Favorite page reselected before navigation")
    let liveURL = fixture.appending(path: "native-favorite-live-navigation")
    let commitCountBeforeNavigation = documentCommits[target.uuidString, default: 0]
    try expect(
      primary.runtime.navigateTabID(
        target.uuidString, profileID: profileAlpha.uuidString, windowID: firstWindowNativeID,
        url: liveURL.absoluteString), "native live Favorite page accepts owned loopback navigation")
    try await wait("live Favorite URL callback") {
      first.store.session.favoritePages.first { $0.favoriteID == firstFavorite.id }?.tab.url
        == liveURL
        && self.callbackURLs[target.uuidString] == liveURL.absoluteString
        && self.callbackLoading[target.uuidString] == false
        && self.documentCommits[target.uuidString, default: 0] > commitCountBeforeNavigation
    }
    let liveDocument = try await document(target)
    try expect(
      liveDocument["instance"] as? String != targetBefore["instance"] as? String
        && documentCommits[target.uuidString, default: 0] > commitCountBeforeNavigation,
      "accepted navigation commits new owned document and reports current URL callback")
    let commitCountBeforeReset = documentCommits[target.uuidString, default: 0]
    try expect(
      first.store.resetFavorite(firstFavorite.id), "native Reset accepts Favorite original URL")
    try await wait("Favorite Reset URL") {
      first.store.session.favoritePages.first { $0.favoriteID == firstFavorite.id }?.tab.url
        == original
        && self.callbackURLs[target.uuidString] == original.absoluteString
        && self.callbackLoading[target.uuidString] == false
        && self.documentCommits[target.uuidString, default: 0] > commitCountBeforeReset
    }
    _ = try await document(target)
    try expect(
      primary.runtime.nativeTabID(forID: target.uuidString) == firstNativeID
        && primary.runtime.windowID(forTabID: target.uuidString) == firstWindowNativeID,
      "live navigation and Reset keep same native tab identity and window owner")

    let secondWindowID = try host.newWindow(from: firstID)
    guard let second = host.contexts[secondWindowID] else {
      throw NativeFavoritesFailure("Second production window failed to attach.")
    }
    try expect(
      second.store.selectFavorite(firstFavorite.id),
      "second owned window opens shared Profile Favorite definition")
    let secondPage = second.store.session.favoritePages.first { $0.favoriteID == firstFavorite.id }!
    _ = try await document(secondPage.tab.id)
    try expect(
      secondPage.tab.id != target
        && primary.runtime.windowID(forTabID: secondPage.tab.id.uuidString) == second.nativeID
        && secondPage.tab.url == original,
      "second native window owns distinct live tab UUID for shared Favorite")
    second.store.closeCurrentPage()
    try await wait("local Favorite page closure") {
      !second.store.session.favoritePages.contains(where: { $0.favoriteID == firstFavorite.id })
    }
    try expect(
      second.store.session.favorites.contains(where: { $0.id == firstFavorite.id })
        && !second.store.session.favoritePages.contains(where: { $0.favoriteID == firstFavorite.id }
        ),
      "local Favorite page close keeps shared Profile definition")
    try expect(second.store.selectFavorite(firstFavorite.id), "closed local Favorite page reopens")
    let reopenedPage = second.store.session.favoritePages.first {
      $0.favoriteID == firstFavorite.id
    }!
    second.store.perform(
      .tab(space: second.store.session.selectedSpace.id, tab: reopenedPage.tab.id))
    _ = try await document(reopenedPage.tab.id)
    let reopenedNativeID = primary.runtime.nativeTabID(forID: reopenedPage.tab.id.uuidString)
    let reopenedSpaceID = second.store.session.selectedSpaceID
    try expect(
      reopenedPage.tab.id != secondPage.tab.id,
      "reopened local Favorite page receives fresh native UUID")

    first.store.perform(.tab(space: alphaOne.id, tab: peer))
    let peerBeforeRemoval = try await document(peer)
    first.store.perform(.tab(space: alphaTwo.id, tab: sharedPeer))
    let sharedPeerBeforeRemoval = try await document(sharedPeer)
    first.store.perform(.tab(space: betaSpace.id, tab: betaPeer))
    let betaBeforeRemoval = try await document(betaPeer)
    second.store.perform(.tab(space: reopenedSpaceID, tab: reopenedPage.tab.id))
    let reopenedBeforeRemoval = try await document(reopenedPage.tab.id)
    first.store.perform(.space(alphaOne.id))
    try expect(
      first.store.selectFavorite(firstFavorite.id), "original Favorite selected before removal")
    let targetBeforeRemoval = try await document(target)
    try manager.focusWindow(firstID)
    try expect(
      first.store.removeFavorite(firstFavorite.id), "unfavorite preserves live page as ordinary tab"
    )
    try expect(
      first.store.session.selectedSpaceID == alphaOne.id
        && first.store.session.selectedPage?.tab.id == target
        && second.store.session.selectedSpaceID == reopenedSpaceID
        && second.store.session.selectedPage?.tab.id == reopenedPage.tab.id,
      "unfavorite preserves both windows' selections before any further selection command")
    let retainedTarget = first.store.session.spaces.flatMap(\.tabs).first { $0.id == target }
    first.store.perform(.tab(space: alphaOne.id, tab: peer))
    let peerAfterRemoval = try await document(peer)
    first.store.perform(.tab(space: alphaTwo.id, tab: sharedPeer))
    let sharedPeerAfterRemoval = try await document(sharedPeer)
    first.store.perform(.tab(space: betaSpace.id, tab: betaPeer))
    let betaAfterRemoval = try await document(betaPeer)
    first.store.perform(.tab(space: alphaOne.id, tab: target))
    let targetAfterRemoval = try await document(target)
    let reopenedAfterRemoval = try await document(reopenedPage.tab.id)
    let reopenedRetainedSpace = second.store.session.spaces.first(where: {
      $0.id == reopenedSpaceID
    })
    acceptanceDetails["unfavorite"] = [
      "retainedOriginalURL": retainedTarget?.url == original,
      "nativeTabIDPreserved": primary.runtime.nativeTabID(forID: target.uuidString)
        == firstNativeID,
      "windowOwnerPreserved": primary.runtime.windowID(forTabID: target.uuidString)
        == firstWindowNativeID,
      "documentInstancePreserved": targetAfterRemoval["instance"] as? String
        == targetBeforeRemoval["instance"] as? String,
      "peerNativeTabIDPreserved": primary.runtime.nativeTabID(forID: reopenedPage.tab.id.uuidString)
        == reopenedNativeID,
      "peerDocumentInstancePreserved": reopenedAfterRemoval["instance"] as? String
        == reopenedBeforeRemoval["instance"] as? String,
      "peerRemainsSelectedInSameSpace": second.store.session.selectedSpaceID == reopenedSpaceID
        && second.store.session.selectedPage?.tab.id == reopenedPage.tab.id,
      "peerPreservedAsOrdinaryTab": reopenedRetainedSpace?.tabs.contains(where: {
        $0.id == reopenedPage.tab.id && $0.url == reopenedPage.tab.url
      }) == true,
    ]
    try expect(
      acceptanceDetails["unfavorite"]?.values.allSatisfy { $0 } == true,
      "unfavorite preserves original document and native identity as ordinary page")
    try expect(
      peerAfterRemoval["instance"] as? String == peerBeforeRemoval["instance"] as? String
        && sharedPeerAfterRemoval["instance"] as? String
          == sharedPeerBeforeRemoval["instance"] as? String
        && betaAfterRemoval["instance"] as? String == betaBeforeRemoval["instance"] as? String
        && manager.workspace.focusedWindowID == firstID
        && first.store.profileFavorites.map(\.id) == [thirdFavorite.id, secondFavorite.id]
        && !second.store.session.favorites.contains(where: { $0.id == firstFavorite.id })
        && !second.store.session.favoritePages.contains(where: { $0.favoriteID == firstFavorite.id }
        )
        && second.store.session.selectedSpaceID == reopenedSpaceID
        && second.store.session.spaces.contains(where: {
          $0.id == reopenedSpaceID && $0.tabs.contains(where: { $0.id == reopenedPage.tab.id })
        })
        && primary.runtime.nativeTabID(forID: reopenedPage.tab.id.uuidString) == reopenedNativeID,
      "unfavorite removes shared definition and preserves same-Profile and unrelated Profile peers"
    )

    func favoritePages(_ context: NativeBrowserContext) -> [NativeFavoritePageProof] {
      context.store.session.favoritePages.map {
        NativeFavoritePageProof(
          favoriteID: $0.favoriteID, tabID: $0.tab.id, url: $0.tab.url.absoluteString)
      }.sorted { $0.favoriteID.uuidString < $1.favoriteID.uuidString }
    }
    let checkpoint = NativeFavoritesCheckpoint(
      profileIDs: first.store.session.profiles.map(\.id), windowIDs: [firstID, secondWindowID],
      favoriteIDs: first.store.session.favorites.map(\.id),
      favoriteURLs: first.store.session.favorites.map { $0.originalURL.absoluteString },
      firstWindowPages: favoritePages(first),
      secondWindowPages: favoritePages(second),
      firstWindowFavoriteOrder: first.store.profileFavorites.map(\.id),
      workspaceVersion: manager.workspace.version,
      sessionVersions: manager.workspace.windows.map(\.session.version))
    try JSONEncoder().encode(checkpoint).write(
      to: root.appending(path: "native-favorites-identities.json"), options: .atomic)
    try expect(
      checkpoint.workspaceVersion == 2 && checkpoint.sessionVersions.allSatisfy { $0 == 4 }
        && manager.workspace.windows.count == 2,
      "initial favorite checkpoint records workspace v2, session v4, and two owned windows")
    try captureFavoriteChrome(second)
  }

  private func exerciseRestart(_ manager: BrowserWorkspaceStore, host: NativeBrowserHost)
    async throws
  {
    let checkpoint = try JSONDecoder().decode(
      NativeFavoritesCheckpoint.self,
      from: Data(contentsOf: root.appending(path: "native-favorites-identities.json")))
    let windows = Dictionary(uniqueKeysWithValues: host.contexts.map { ($0.key, $0.value) })
    let originalStates = windows.mapValues { context in
      (
        context.store.session.selectedSpaceID, context.store.session.selectedPage?.tab.id,
        context.store.session.selectedSpace.selectedFavoriteID
      )
    }
    try expect(
      manager.workspace.version == 2
        && manager.workspace.windows.allSatisfy { $0.session.version == 4 }
        && Set(windows.keys) == Set(checkpoint.windowIDs)
        && manager.workspace.catalog.favorites.map(\.id) == checkpoint.favoriteIDs
        && manager.workspace.catalog.favorites.map { $0.originalURL.absoluteString }
          == checkpoint.favoriteURLs
        && manager.workspace.windows.allSatisfy {
          $0.session.profiles.map(\.id) == checkpoint.profileIDs
        },
      "restart restores v2 workspace, v4 sessions, exact Profiles, windows, and Favorite definitions"
    )
    for windowID in checkpoint.windowIDs {
      guard let context = windows[windowID] else {
        throw NativeFavoritesFailure("Restart omitted an owned native Favorite window.")
      }
      let expected =
        windowID == checkpoint.windowIDs[0]
        ? checkpoint.firstWindowPages : checkpoint.secondWindowPages
      let actual = context.store.session.favoritePages.map { page in
        NativeFavoritePageProof(
          favoriteID: page.favoriteID, tabID: page.tab.id, url: page.tab.url.absoluteString)
      }.sorted { $0.favoriteID.uuidString < $1.favoriteID.uuidString }
      for page in actual {
        try expect(
          context.store.selectFavorite(page.favoriteID),
          "restart selects saved Favorite before native document materialization")
        let restoredDocument = try await document(page.tabID)
        try expect(
          restoredDocument["cookie"] as? String == "favorites=alpha",
          "restart restores Alpha Profile Favorite cookie")
      }
      try expect(
        actual == expected
          && actual.allSatisfy {
            primary.runtime.windowID(forTabID: $0.tabID.uuidString) == context.nativeID
          },
        "restart restores window-local Favorite UUIDs, current URLs, and native owner for \(windowID)"
      )
    }
    guard let first = windows[checkpoint.windowIDs[0]] else {
      throw NativeFavoritesFailure("Restart primary Favorite window missing.")
    }
    try expect(
      first.store.profileFavorites.map(\.id) == checkpoint.firstWindowFavoriteOrder,
      "restart preserves Profile Favorite order exactly")
    guard let betaProfileID = first.store.session.profiles.dropFirst().first?.id,
      let betaSpace = first.store.session.spaces.first(where: { $0.profileID == betaProfileID }),
      let betaTab = betaSpace.selectedTab ?? betaSpace.tabs.first
    else { throw NativeFavoritesFailure("Restart Beta ordinary page missing.") }
    first.store.perform(.tab(space: betaSpace.id, tab: betaTab.id))
    let betaDocument = try await document(betaTab.id)
    try expect(
      betaDocument["cookie"] as? String == "favorites=beta",
      "restart restores Beta Profile ordinary-page cookie")
    if let favoriteID = first.store.profileFavorites.first?.id {
      try expect(
        first.store.selectFavorite(favoriteID),
        "restart Favorite view selected for hidden native chrome capture")
    }
    try captureFavoriteChrome(first)
    for (windowID, state) in originalStates {
      guard let context = windows[windowID] else { continue }
      context.store.perform(.space(state.0))
      if let favoriteID = state.2 {
        try expect(
          context.store.selectFavorite(favoriteID), "restart restores saved Favorite selection")
      } else if let tabID = state.1 {
        context.store.perform(.tab(space: state.0, tab: tabID))
      }
      try expect(
        context.store.session.selectedSpaceID == state.0
          && context.store.session.selectedPage?.tab.id == state.1
          && context.store.session.selectedSpace.selectedFavoriteID == state.2,
        "restart restores saved Space and page selection after native chrome capture")
    }
  }

  private func document(_ id: UUID) async throws -> [String: Any] {
    for _ in 0..<100 {
      let result: String? = await withCheckedContinuation { continuation in
        primary.runtime.evaluate(
          inTabID: id.uuidString,
          script:
            "({fixture:document.documentElement.dataset.arcusisFixture,instance:window.arcusisInstance,cookie:document.cookie})"
        ) { continuation.resume(returning: $0) }
      }
      if let result {
        if let data = result.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        {
          documentStatus[id.uuidString] =
            "fixture=\(object["fixture"] as? String ?? "missing");instance=\(object["instance"] is String)"
        } else {
          documentStatus[id.uuidString] = "result=invalid-json"
        }
      } else {
        documentStatus[id.uuidString] =
          primary.runtime.view(forTabID: id.uuidString) == nil
          ? "result=nil;view=missing" : "result=nil;view=owned"
      }
      if let data = result?.data(using: .utf8),
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        object["fixture"] as? String == "v1", object["instance"] as? String != nil
      {
        return object
      }
      try await Task.sleep(for: .milliseconds(100))
    }
    throw NativeFavoritesFailure("Owned loopback Favorite document did not become ready.")
  }

  private func setCookie(_ value: String, in id: UUID) async throws {
    let result: String? = await withCheckedContinuation { continuation in
      primary.runtime.evaluate(
        inTabID: id.uuidString,
        script: "(()=>{document.cookie='\(value); Max-Age=3600; path=/';return document.cookie;})()"
      ) { continuation.resume(returning: $0) }
    }
    try expect(result?.contains(value) == true, "owned Profile fixture cookie seeded")
  }

  private func wait(_ label: String, until ready: () -> Bool) async throws {
    for _ in 0..<100 {
      if ready() { return }
      try await Task.sleep(for: .milliseconds(100))
    }
    throw NativeFavoritesFailure("Timed out: \(label).")
  }

  private func captureFavoriteChrome(_ context: NativeBrowserContext) throws {
    let normal = NSRect(x: 80, y: 90, width: 1120, height: 760)
    for (name, size) in [("normal", normal.size), ("minimum", context.window.minSize)] {
      context.window.setFrame(NSRect(origin: normal.origin, size: size), display: false)
      context.hosting.layoutSubtreeIfNeeded()
      guard
        let bitmap = context.hosting.bitmapImageRepForCachingDisplay(in: context.hosting.bounds),
        let png =
          ({ () -> Data? in
            context.hosting.cacheDisplay(in: context.hosting.bounds, to: bitmap)
            return bitmap.representation(using: .png, properties: [:])
          })()
      else { throw NativeFavoritesFailure("Hidden Favorite chrome PNG capture failed.") }
      try png.write(
        to: root.appending(path: "\(phase)-native-favorite-window-\(name).png"), options: .atomic)
    }
  }

  func prepareForQuit() throws {
    guard let host, let workspace else { return }
    do {
      host.flushGeometry()
      guard workspace.persistSnapshot() else {
        throw NativeFavoritesFailure("Native Favorite workspace quit snapshot failed.")
      }
      expectedAfterQuit = workspace.workspace
    } catch {
      failure = failure ?? error
      try? report(error: failure)
      throw error
    }
  }

  func auditAfterQuit() throws -> [String] {
    guard let host, let expectedAfterQuit else { return [] }
    for _ in 0..<20 where !host.contexts.isEmpty {
      RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
    do {
      guard host.contexts.isEmpty,
        expectedAfterQuit.windows.allSatisfy({ closures[$0.id] == true }),
        try file.load() == expectedAfterQuit
      else { throw NativeFavoritesFailure("Engine quit failed Favorite window persistence audit.") }
      try report(error: failure)
      host.detach()
      return ["engine quit closes hidden Favorite windows and persists exact owned workspace"]
    } catch {
      failure = failure ?? error
      try? report(error: failure)
      throw error
    }
  }

  private func expect(_ passed: Bool, _ message: String) throws {
    guard passed else { throw NativeFavoritesFailure(message) }
    checks.append(message)
  }

  private func report(error: Error?) throws {
    let proof: [String: Any] = [
      "schema": 1, "phase": phase, "passed": error == nil && failure == nil, "checks": checks,
      "callbackURLs": callbackURLs, "documentCommitCounts": documentCommits,
      "callbackLoading": callbackLoading,
      "chromeEvidence": [
        "\(phase)-native-favorite-window-normal.png", "\(phase)-native-favorite-window-minimum.png",
      ],
      "documentStatus": documentStatus,
      "acceptanceDetails": acceptanceDetails,
      "workspaceVersion": workspace?.workspace.version as Any? ?? NSNull(),
      "sessionVersions": workspace?.workspace.windows.map(\.session.version) as Any? ?? NSNull(),
      "closedWindows": Dictionary(
        uniqueKeysWithValues: closures.map { ($0.key.uuidString, $0.value) }),
      "unverified": [
        "native beforeunload cancel and accept prompts; hidden harness has no deterministic native prompt controller"
      ],
      "error": (error ?? failure)?.localizedDescription as Any? ?? NSNull(),
    ]
    let data = try JSONSerialization.data(
      withJSONObject: proof, options: [.prettyPrinted, .sortedKeys])
    guard data.count <= 64 * 1024 else {
      throw NativeFavoritesFailure("Favorite proof exceeded report bound.")
    }
    try data.write(to: root.appending(path: "\(phase)-native-favorites.json"), options: .atomic)
  }
}

private struct NativeFavoritesFailure: LocalizedError {
  let message: String
  init(_ message: String) { self.message = message }
  var errorDescription: String? { message }
}
