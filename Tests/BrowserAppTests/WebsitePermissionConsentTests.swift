import BrowserCore
import Foundation
import Testing

@testable import ArcusisBrowser

@Suite @MainActor
struct WebsitePermissionConsentTests {
  private func store() -> BrowserStore {
    let store = BrowserStore()
    store.perform(.open(URL(string: "https://meet.google.com/example")!))
    return store
  }

  private func request(_ store: BrowserStore, id: String = "p1") throws -> WebsitePermissionRequest {
    let tab = try #require(store.session.selectedSpace.selectedTab)
    return try #require(
      WebsitePermissionRequest(
        id: id, profileID: store.session.selectedSpace.profileID,
        tabID: tab.id, pageURL: tab.url, requestingOrigin: URL(string: "https://meet.google.com")!,
        kinds: [.camera, .microphone]))
  }

  @Test func staleProfileCannotApproveMediaAndLateApprovalIsIgnored() throws {
    let store = store()
    let request = try request(store)
    var decisions: [Bool] = []
    store.onWebsitePermissionDecision = { _, accepted in decisions.append(accepted) }
    #expect(store.requestWebsitePermission(request))
    store.cycleSpace(by: 1)
    store.resolveWebsitePermission(request.id, accepted: true)
    #expect(decisions == [false])
    #expect(store.websitePermissionRequests.isEmpty)
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
    store.onWebsitePermissionDecision = { _, accepted in mediaDecisions.append(accepted) }
    store.onInstallDecision = { _, accepted in installDecisions.append(accepted) }
    #expect(store.requestInstallation(install))
    #expect(store.requestWebsitePermission(media))
    store.resolveWebsitePermission(media.id, accepted: true)
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
    store.onWebsitePermissionDecision = { id, accepted in decisions.append("\(id):\(accepted)") }
    #expect(store.requestWebsitePermission(first))
    #expect(store.requestWebsitePermission(second))
    store.sheet = nil
    store.sheetDidDismiss()
    store.resolveWebsitePermission(second.id, accepted: true)
    #expect(decisions == ["p1:false", "p2:true"])
  }

  @Test func nativeDismissalCancelsOnlyItsOwnRequest() throws {
    let store = store()
    let request = try request(store)
    var decisions: [Bool] = []
    store.onWebsitePermissionDecision = { _, accepted in decisions.append(accepted) }
    #expect(store.requestWebsitePermission(request))
    store.resolveWebsitePermission(request.id, accepted: false)
    store.resolveWebsitePermission(request.id, accepted: true)
    #expect(decisions == [false])
    #expect(store.sheet == nil)
  }
}
