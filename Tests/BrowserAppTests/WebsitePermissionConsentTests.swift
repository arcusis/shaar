// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import Foundation
import SwiftUI
import Testing

@testable import ArcusisBrowser

@Suite @MainActor
struct WebsitePermissionConsentTests {
  @Test func permissionConsentTitleIsVoiceOverHeading() {
    #expect(WebsitePermissionConsent.headingTraits == .isHeader)
  }

  private func store() -> BrowserStore {
    let store = BrowserStore()
    store.perform(.open(URL(string: "https://meet.google.com/example")!))
    return store
  }

  private func request(_ store: BrowserStore, id: String = "p1") throws -> WebsitePermissionRequest
  {
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

  @Test func protocolHandlerUsesTheSharedConsentSheet() throws {
    let store = store()
    let tab = try #require(store.session.selectedSpace.selectedTab)
    let request = try #require(
      WebsitePermissionRequest(
        id: "protocol-1", profileID: store.session.selectedSpace.profileID,
        tabID: tab.id, pageURL: tab.url, requestingOrigin: URL(string: "https://meet.google.com")!,
        kinds: [.protocolHandler]))
    #expect(store.requestWebsitePermission(request))
    #expect(store.sheet?.id == "permission-protocol-1")
    #expect(WebsitePermissionKind.protocolHandler.title == PanelsL10n.string("this protocol"))
    #expect(
      WebsitePermissionKind.protocolHandler.purpose
        == PanelsL10n.string("open links that use this protocol"))
    #expect(WebsitePermissionKind.protocolHandler.symbol == "link")
    let allowsOneTime = request.kinds.allSatisfy { $0.supportsOneTimeGrant }
    #expect(!allowsOneTime)
  }

  @Test func permissionPromptDismissesPendingSplitCommand() throws {
    let store = store()
    let tab = try #require(store.session.selectedSpace.selectedTab)
    store.openSplitPane(beside: tab.id, edge: .right)
    #expect(store.commandIsOpen)
    #expect(store.pendingSplitPlacement != nil)

    let request = try request(store)
    #expect(store.requestWebsitePermission(request))
    #expect(store.sheet?.id == "permission-\(request.id)")
    #expect(!store.commandIsOpen)
    #expect(store.pendingSplitPlacement == nil)
  }

  @Test func privateSheetSaysThisVisitOnlyAndDoesNotKeepTheGrant() throws {
    let first = UUID()
    let session = try BrowserSession.privateWindow(sourceProfileID: UUID(), firstTabID: first)
    let store = BrowserStore(privateSession: session)
    store.perform(.open(URL(string: "https://notes.example/private")!))
    let tab = try #require(store.session.selectedPage?.tab)
    let request = try #require(
      WebsitePermissionRequest(
        id: "private-note", profileID: store.session.selectedSpace.profileID,
        tabID: tab.id, pageURL: tab.url, requestingOrigin: URL(string: "https://notes.example")!,
        kinds: [.notifications], frameID: "0123456789abcdef0123456789abcdef"))
    #expect(store.isPrivate)
    #expect(
      WebsitePermissionPersistence.forGrant(isPrivate: true, kinds: request.kinds) == .thisVisit)
    #expect(
      WebsitePermissionSheetCopy.allowButton(isPrivate: true, oneTime: false) == "this visit only")
    #expect(
      WebsitePermissionSheetCopy.duration(isPrivate: true, oneTime: false)
        == "Only for this visit.")
    #expect(WebsitePermissionSheetCopy.allowButton(isPrivate: false, oneTime: false) == "Allow")
    store.rememberPermissionFrame(tab.id, frameID: try #require(request.frameID))
    var decisions: [Bool] = []
    store.onWebsitePermissionDecision = { _, accepted in decisions.append(accepted) }
    #expect(store.requestWebsitePermission(request))
    #expect(store.websitePermissionIsCurrent(request))
    store.resolveWebsitePermission(request.id, accepted: true)
    #expect(decisions == [true])
    #expect(store.websitePermissionRequests.isEmpty)
  }

  @Test func aReplacedFrameCannotReceiveTheGrant() throws {
    let store = store()
    let tab = try #require(store.session.selectedPage?.tab)
    let request = try #require(
      WebsitePermissionRequest(
        id: "framed", profileID: store.session.selectedSpace.profileID,
        tabID: tab.id, pageURL: tab.url, requestingOrigin: URL(string: "https://meet.google.com")!,
        kinds: [.notifications], frameID: "0123456789abcdef0123456789abcdef"))
    let replacement = String(repeating: "a", count: 32)
    store.rememberPermissionFrame(tab.id, frameID: try #require(request.frameID))
    var decisions: [Bool] = []
    store.onWebsitePermissionDecision = { _, accepted in decisions.append(accepted) }
    #expect(store.requestWebsitePermission(request))
    store.nativeTabChanged(tab.id, url: tab.url, title: "Renamed")
    #expect(store.websitePermissionIsCurrent(request))
    store.rememberPermissionFrame(tab.id, frameID: replacement)
    #expect(!store.websitePermissionIsCurrent(request))
    store.resolveWebsitePermission(request.id, accepted: true)
    #expect(decisions == [false])
    store.nativeTabChanged(
      tab.id, url: URL(string: "https://meet.google.com/moved")!, title: "Moved")
    #expect(!store.websitePermissionIsCurrent(request))
  }
}
