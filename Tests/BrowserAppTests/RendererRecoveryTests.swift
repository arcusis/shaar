import BrowserCore
import Foundation
import Testing

@testable import ArcusisBrowser

@Suite @MainActor
struct RendererRecoveryTests {
  @Test func backgroundFailureKeepsSpaceSelectionAndRejectsForeignCallbacks() throws {
    let store = pageStore()
    let space = store.session.selectedSpace
    let tab = try #require(space.selectedTab)
    store.cycleSpace(by: 1)
    store.showCommand()
    let before = store.session
    store.nativeRendererGone(tab.id, profileID: UUID(), status: "crashed", exitCode: 1)
    store.nativeRendererGone(UUID(), profileID: space.profileID, status: "crashed", exitCode: 1)
    store.nativeRendererGone(tab.id, profileID: space.profileID, status: "normal", exitCode: 0)
    #expect(store.rendererFailures.isEmpty)
    store.nativeRendererGone(tab.id, profileID: space.profileID, status: "oom", exitCode: 7)
    #expect(store.session == before && store.commandIsOpen)
    let failure = try #require(store.rendererFailures[tab.id])
    #expect(failure.profileID == space.profileID && failure.pageURL == tab.url)
    #expect(failure.message.contains("memory") && failure.exitCode == 7)
    #expect(!store.reloadFailedPage(failure.id))
  }

  @Test func recoveryRequiresCurrentFailureAndOwningProfileWithoutRepeatingReload() throws {
    let store = pageStore()
    let space = store.session.selectedSpace
    let tab = try #require(space.selectedTab)
    var reloaded: [UUID] = []
    store.onReloadPage = { id, profile in
      #expect(profile == space.profileID)
      reloaded.append(id)
      return true
    }
    store.nativeRendererGone(tab.id, profileID: space.profileID, status: "crashed", exitCode: 1)
    let first = try #require(store.rendererFailures[tab.id])
    store.showCommand()
    #expect(!store.reloadFailedPage(first.id))
    store.dismissCommand()
    store.spaceEditor = .create
    #expect(!store.reloadFailedPage(first.id))
    store.sheet = nil
    #expect(store.reloadFailedPage(first.id))
    #expect(!store.reloadFailedPage(first.id) && reloaded == [tab.id])
    store.nativePageLoading(tab.id, loading: false)
    #expect(store.rendererFailures[tab.id]?.reloading == true)
    store.nativePageLoading(tab.id, loading: true)
    store.nativePageLoading(tab.id, loading: false)
    #expect(store.canReloadFailure(first.id))
    store.nativeRendererGone(tab.id, profileID: space.profileID, status: "killed", exitCode: 2)
    let second = try #require(store.rendererFailures[tab.id])
    #expect(second.id != first.id && !store.reloadFailedPage(first.id))
    store.nativeDocumentCommitted(tab.id, profileID: UUID())
    #expect(store.rendererFailures[tab.id] != nil)
    store.nativeDocumentCommitted(tab.id, profileID: space.profileID)
    #expect(store.rendererFailures[tab.id] == nil && !store.reloadFailedPage(second.id))
    #expect(store.session.selectedSpace.selectedTabID == tab.id)
  }

  @Test func rejectedNativeReloadLeavesRecoveryAvailable() throws {
    let store = pageStore()
    let space = store.session.selectedSpace
    let tab = try #require(space.selectedTab)
    store.nativeRendererGone(
      tab.id, profileID: space.profileID, status: "launchFailed", exitCode: 1)
    let failure = try #require(store.rendererFailures[tab.id])
    #expect(!store.reloadFailedPage(failure.id))
    store.onReloadPage = { _, _ in false }
    #expect(!store.reloadFailedPage(failure.id))
    #expect(store.rendererFailures[tab.id]?.reloading == false)
    #expect(store.canReloadFailure(failure.id))
  }

  @Test func failureCancelsPageConsentAndFindWithoutGrantingLateReplies() throws {
    let store = pageStore()
    let space = store.session.selectedSpace
    let tab = try #require(space.selectedTab)
    var stopped: [UUID] = []
    store.onStopFinding = { stopped.append($0) }
    store.showPageFind()
    store.updatePageFindQuery("draft")
    store.nativeRendererGone(tab.id, profileID: space.profileID, status: "crashed", exitCode: 1)
    #expect(store.pageFind == nil && stopped == [tab.id] && !store.canFindCurrentPage)
    store.showPageFind()
    #expect(store.pageFind == nil)
    store.nativeDocumentCommitted(tab.id, profileID: space.profileID)
    let requests = try (0..<2).map { index in
      try #require(
        WebsiteMediaRequest(
          id: "crash-media-\(index)", profileID: space.profileID, tabID: tab.id,
          pageURL: tab.url, requestingOrigin: URL(string: "https://example.com")!, kinds: [.camera])
      )
    }
    var decisions: [Bool] = []
    store.onWebsiteMediaDecision = { _, accepted in decisions.append(accepted) }
    for request in requests { #expect(store.requestWebsiteMedia(request)) }
    store.nativeRendererGone(tab.id, profileID: space.profileID, status: "crashed", exitCode: 1)
    #expect(
      store.websiteMediaRequests.isEmpty && store.sheet == nil && decisions == [false, false])
    store.resolveWebsiteMedia(requests[0].id, accepted: true)
    #expect(decisions == [false, false])
    #expect(!store.requestWebsiteMedia(requests[0]))
  }

  @Test func failureIsTransientAndRemovalNeverArchivesCrashState() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appending(path: "session.json")
    let store = BrowserStore(sessionFile: SessionFile(url: file))
    store.perform(.open(URL(string: "https://example.com/account")!))
    let space = store.session.selectedSpace
    let tab = try #require(space.selectedTab)
    let before = try Data(contentsOf: file)
    store.nativeRendererGone(tab.id, profileID: space.profileID, status: "crashed", exitCode: 1)
    #expect(try Data(contentsOf: file) == before)
    #expect(BrowserStore(sessionFile: SessionFile(url: file)).rendererFailures.isEmpty)
    #expect(store.session.closedTabs.isEmpty)
    store.nativeTabClosed(tab.id)
    #expect(store.rendererFailures.isEmpty && store.session.closedTabs.first?.tab.url == tab.url)
    store.perform(.open(tab.url))
    let next = try #require(store.session.selectedSpace.selectedTab)
    store.nativeRendererGone(next.id, profileID: space.profileID, status: "crashed", exitCode: 1)
    #expect(store.removeSpace(space.id) && store.rendererFailures.isEmpty)
  }

  private func pageStore() -> BrowserStore {
    let store = BrowserStore()
    store.perform(.open(URL(string: "https://example.com/account")!))
    return store
  }
}
