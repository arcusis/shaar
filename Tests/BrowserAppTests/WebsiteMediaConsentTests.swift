import BrowserCore
import Foundation
import Testing

@testable import ArcusisBrowser

@Suite @MainActor
struct WebsiteMediaConsentTests {
  private func store() -> BrowserStore {
    let store = BrowserStore()
    store.perform(.open(URL(string: "https://meet.google.com/example")!))
    return store
  }

  private func request(_ store: BrowserStore, id: String = "p1") throws -> WebsiteMediaRequest {
    let tab = try #require(store.session.selectedSpace.selectedTab)
    return try #require(
      WebsiteMediaRequest(
        id: id, profileID: store.session.selectedSpace.profileID,
        tabID: tab.id, pageURL: tab.url, requestingOrigin: URL(string: "https://meet.google.com")!,
        kinds: [.camera, .microphone]))
  }

  @Test func staleProfileCannotApproveMediaAndLateApprovalIsIgnored() throws {
    let store = store()
    let request = try request(store)
    var decisions: [Bool] = []
    store.onWebsiteMediaDecision = { _, accepted in decisions.append(accepted) }
    #expect(store.requestWebsiteMedia(request))
    store.cycleSpace(by: 1)
    store.resolveWebsiteMedia(request.id, accepted: true)
    #expect(decisions == [false])
    #expect(store.websiteMediaRequests.isEmpty)
  }

  @Test func extensionAndMediaRequestsShareOneModalQueueWithoutGrantingUnseenRequests() throws {
    let store = store()
    let media = try request(store, id: "same-id")
    let extensionInfo = try #require(
      BrowserExtension(id: String(repeating: "a", count: 32), name: "Example", version: "1"))
    let install = try #require(
      ExtensionInstallRequest(
        id: "same-id", profileID: media.profileID,
        tabID: media.tabID, sourceURL: media.pageURL, browserExtension: extensionInfo,
        kind: .install, permissions: []))
    var mediaDecisions: [Bool] = []
    var installDecisions: [Bool] = []
    store.onWebsiteMediaDecision = { _, accepted in mediaDecisions.append(accepted) }
    store.onInstallDecision = { _, accepted in installDecisions.append(accepted) }
    #expect(store.requestInstallation(install))
    #expect(store.requestWebsiteMedia(media))
    store.resolveWebsiteMedia(media.id, accepted: true)
    #expect(mediaDecisions == [false])
    #expect(installDecisions.isEmpty)
    store.resolveInstallation(install.id, accepted: true)
    #expect(installDecisions == [true])
  }

  @Test func closingPermissionSheetDeniesOnceAndDoesNotLoseQueuedConsent() throws {
    let store = store()
    let first = try request(store)
    let second = try request(store, id: "p2")
    var decisions: [String] = []
    store.onWebsiteMediaDecision = { id, accepted in decisions.append("\(id):\(accepted)") }
    #expect(store.requestWebsiteMedia(first))
    #expect(store.requestWebsiteMedia(second))
    store.sheet = nil
    store.sheetDidDismiss()
    store.resolveWebsiteMedia(second.id, accepted: true)
    #expect(decisions == ["p1:false", "p2:true"])
  }

  @Test func nativeDismissalCancelsOnlyItsOwnRequest() throws {
    let store = store()
    let request = try request(store)
    var decisions: [Bool] = []
    store.onWebsiteMediaDecision = { _, accepted in decisions.append(accepted) }
    #expect(store.requestWebsiteMedia(request))
    store.resolveWebsiteMedia(request.id, accepted: false)
    store.resolveWebsiteMedia(request.id, accepted: true)
    #expect(decisions == [false])
    #expect(store.sheet == nil)
  }
}
