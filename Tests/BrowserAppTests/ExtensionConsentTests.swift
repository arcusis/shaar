import BrowserCore
import Foundation
import Testing

@testable import ArcusisBrowser

@Suite @MainActor
struct ExtensionConsentTests {
  private func storeWithPage() -> BrowserStore {
    let store = BrowserStore()
    store.perform(.open(URL(string: "https://chromewebstore.google.com/example")!))
    return store
  }

  @Test func consentShowsEffectiveHostAccessAndKnownScope() {
    let values = ExtensionConsentPermissions.displayValues(
      permissions: ["storage"], hostPermissions: ["https://example.com/*"], complete: true)
    #expect(values == ["storage", "Site access: https://example.com/*"])
    #expect(!values.contains(ExtensionConsentPermissions.unknownAccess))
  }

  @Test func consentMarksMissingOrIncompleteHostScopeAsUnknown() {
    let missing = ExtensionConsentPermissions.displayValues(
      permissions: [], hostPermissions: nil, complete: false)
    #expect(missing == [ExtensionConsentPermissions.unknownAccess])
    let incomplete = ExtensionConsentPermissions.displayValues(
      permissions: [], hostPermissions: ["<all_urls>"], complete: false)
    #expect(incomplete.contains("Site access: <all_urls>"))
    #expect(incomplete.contains(ExtensionConsentPermissions.unknownAccess))
  }

  private func request(_ store: BrowserStore, id: String = "install1", profile: UUID? = nil) throws
    -> ExtensionInstallRequest
  {
    let space = store.session.selectedSpace
    let tab = try #require(space.selectedTabID)
    let source = try #require(space.selectedTab?.url)
    let browserExtension = try #require(
      BrowserExtension(id: String(repeating: "a", count: 32), name: "Example", version: "1.0"))
    return try #require(
      ExtensionInstallRequest(
        id: id, profileID: profile ?? space.profileID, tabID: tab,
        sourceURL: source, browserExtension: browserExtension,
        kind: .install, permissions: ["Read and change site data"]
      ))
  }

  @Test func cancellationResolvesExactlyOnceAndCannotLaterApprove() throws {
    let store = storeWithPage()
    var decisions: [Bool] = []
    store.onInstallDecision = { _, accepted in decisions.append(accepted) }
    let request = try request(store)
    #expect(store.requestInstallation(request))
    store.resolveInstallation(request.id, accepted: false)
    store.resolveInstallation(request.id, accepted: true)
    #expect(decisions == [false])
    #expect(store.installationRequests.isEmpty)
    #expect(store.sheet == nil)
  }

  @Test func dismissingNativeSheetCancelsItsRequestAndPresentsTheNextOne() throws {
    let store = storeWithPage()
    let first = try request(store)
    let second = try request(store, id: "install2")
    var decisions: [Bool] = []
    store.onInstallDecision = { _, accepted in decisions.append(accepted) }
    #expect(store.requestInstallation(first))
    #expect(store.requestInstallation(second))
    store.sheet = nil
    store.sheetDidDismiss()
    #expect(decisions == [false])
    if case .extensionInstall(let current) = store.sheet {
      #expect(current.id == second.id)
    } else {
      Issue.record("Next consent was not presented")
    }
    store.resolveInstallation(first.id, accepted: true)
    #expect(decisions == [false])
  }

  @Test func switchingProfilesCancelsConsentAndLateApprovalIsIgnored() throws {
    let store = storeWithPage()
    let request = try request(store)
    var decisions: [Bool] = []
    store.onInstallDecision = { _, accepted in decisions.append(accepted) }
    #expect(store.requestInstallation(request))
    store.cycleSpace(by: 1)
    store.resolveInstallation(request.id, accepted: true)
    #expect(decisions == [false])
    #expect(store.installationRequests.isEmpty)
  }

  @Test func pageNavigationInvalidatesTheOriginalConsent() throws {
    let store = storeWithPage()
    let request = try request(store)
    var decisions: [Bool] = []
    store.onInstallDecision = { _, accepted in decisions.append(accepted) }
    #expect(store.requestInstallation(request))
    store.nativeTabChanged(
      request.tabID, url: URL(string: "https://example.com/other")!, title: "Other")
    store.resolveInstallation(request.id, accepted: true)
    #expect(decisions == [false])
  }

  @Test func queuedConsentDoesNotReplaceSpaceEditorOrApproveUnseenRequest() throws {
    let store = storeWithPage()
    let request = try request(store)
    store.spaceEditor = .create
    var decisions: [Bool] = []
    store.onInstallDecision = { _, accepted in decisions.append(accepted) }
    #expect(store.requestInstallation(request))
    #expect(store.spaceEditor == .create)
    store.resolveInstallation(request.id, accepted: true)
    #expect(decisions == [false])
    #expect(store.spaceEditor == .create)
  }

  @Test func onlyPresentedRequestCanApproveAndQueuePreservesBothRequests() throws {
    let store = storeWithPage()
    let first = try request(store)
    let second = try request(store, id: "install2")
    var decisions: [String] = []
    store.onInstallDecision = { id, accepted in decisions.append("\(id):\(accepted)") }
    #expect(store.requestInstallation(first))
    #expect(store.requestInstallation(second))
    #expect(!store.requestInstallation(first))
    store.spaceEditor = .create
    #expect(store.spaceEditor == nil)
    store.resolveInstallation(first.id, accepted: true)
    store.presentNextConsent()
    store.resolveInstallation(second.id, accepted: false)
    #expect(decisions == ["install1:true", "install2:false"])
    #expect(store.installationRequests.isEmpty)
  }

  @Test func unknownProfileNeverGetsAConsentSheet() throws {
    let store = storeWithPage()
    let foreign = try request(store, profile: UUID())
    #expect(!store.requestInstallation(foreign))
    #expect(store.sheet == nil)
  }
}
