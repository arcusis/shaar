// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import Foundation
import Testing

@testable import ArcusisBrowser

@Suite @MainActor
struct DesktopCaptureConsentTests {
  private func store() -> BrowserStore {
    let store = BrowserStore()
    store.perform(.open(URL(string: "https://meet.google.com/example")!))
    return store
  }

  private func request(_ store: BrowserStore, id: String = UUID().uuidString)
    throws -> DesktopCaptureRequest
  {
    let tab = try #require(store.session.selectedSpace.selectedTab)
    return try #require(
      DesktopCaptureRequest(payload: [
        "id": id,
        "profileID": store.session.selectedSpace.profileID.uuidString,
        "tabID": tab.id.uuidString,
        "pageURL": tab.url.absoluteString,
        "origin": "https://meet.google.com",
        "frameID": "0123456789abcdef0123456789abcdef",
      ]))
  }

  @Test func parsesSecureDesktopCaptureRequestAndBuildsConsentIdentity() throws {
    let store = store()
    let capture = try request(store, id: UUID().uuidString)

    #expect(capture.pageURL == URL(string: "https://meet.google.com/example"))
    #expect(capture.requestingOrigin == URL(string: "https://meet.google.com"))
    #expect(capture.displayOrigin == capture.requestingOrigin.absoluteString)
    #expect(capture.frameID == "0123456789abcdef0123456789abcdef")
    #expect(capture.sheetID == "desktop-capture-\(capture.id)")
    #expect(capture.matches(store.session))
    #expect(
      !capture.matches(
        store.session, frameID: "fedcba9876543210fedcba9876543210",
        origin: capture.requestingOrigin))
    #expect(
      !capture.matches(
        store.session, frameID: capture.frameID, origin: URL(string: "https://other.example")))

    let sheet = BrowserSheet.desktopCapture(capture)
    #expect(sheet.id == capture.sheetID)
    #expect(sheet.isConsent)
    #expect(sheet.tabID == capture.tabID)
    #expect(sheet.matches(store.session))
  }

  @Test func capturePromptShowsTheCompleteFrameOriginIncludingPort() throws {
    let store = store()
    let tab = try #require(store.session.selectedSpace.selectedTab)
    let capture = try #require(
      DesktopCaptureRequest(payload: [
        "id": UUID().uuidString,
        "profileID": store.session.selectedSpace.profileID.uuidString,
        "tabID": tab.id.uuidString,
        "pageURL": "https://portal.example/meeting",
        "origin": "https://meet.google.com:8443",
        "frameID": "0123456789abcdef0123456789abcdef",
      ]))

    #expect(capture.pageURL.host() == "portal.example")
    #expect(capture.displayOrigin == "https://meet.google.com:8443")
  }

  @Test func pickerStartsInItsLoadingState() throws {
    let store = store()
    let capture = try request(store)
    let picker = DesktopCapturePicker(request: capture, store: store)
    _ = picker.body

    let display = DesktopCaptureSource(id: "screen:1:0", name: "Main Display", kind: .display)
    let window = DesktopCaptureSource(id: "window:4:0", name: "Browser — Meet", kind: .window)
    #expect(display.label.contains("Main Display"))
    #expect(window.label.contains("Browser"))
    #expect(display.systemImageName == "display")
    #expect(window.systemImageName == "macwindow")

    let states = [
      DesktopCapturePickerContent(
        request: capture, sources: [], loading: true, error: nil, onSelect: { _ in },
        onCancel: {}),
      DesktopCapturePickerContent(
        request: capture, sources: [], loading: false, error: "Screen Recording unavailable",
        onSelect: { _ in }, onCancel: {}),
      DesktopCapturePickerContent(
        request: capture, sources: [], loading: false, error: nil, onSelect: { _ in },
        onCancel: {}),
      DesktopCapturePickerContent(
        request: capture, sources: [display, window], loading: false, error: nil,
        onSelect: { _ in }, onCancel: {}),
    ]
    for state in states { _ = state.body }
  }

  @Test func cancelledSourceDiscoveryDoesNotAuthorizeLateScreenResults() async throws {
    let store = store()
    let capture = try request(store)
    #expect(store.requestDesktopCapture(capture))
    var decision: String? = "not-resolved"
    store.onDesktopCaptureDecision = { _, sourceID in decision = sourceID }
    var providerStarted = false
    var providerContinuation: CheckedContinuation<[DesktopCaptureSource], Never>?
    let picker = DesktopCapturePicker(
      request: capture, store: store,
      hasScreenRecordingAccess: { true },
      screenSourcesProvider: {
        providerStarted = true
        return await withCheckedContinuation { providerContinuation = $0 }
      })
    let load = Task { await picker.loadSources() }
    for _ in 0..<100 where !providerStarted { await Task.yield() }
    #expect(providerStarted)

    load.cancel()
    let screen = DesktopCaptureSource(id: "screen:1:0", name: "Main Display", kind: .display)
    providerContinuation?.resume(returning: [screen])
    await load.value
    store.resolveDesktopCapture(capture.id, sourceID: screen.id)

    #expect(decision == nil)
  }

  @Test func sourceDiscoveryHandlesDeniedAndUnavailableScreenAccess() async throws {
    let store = store()
    let capture = try request(store)
    let denied = DesktopCapturePicker(
      request: capture,
      store: store,
      hasScreenRecordingAccess: { false },
      requestScreenRecordingAccess: { false },
      shareableContent: { throw CocoaError(.fileReadUnknown) }
    )
    await denied.loadSources()

    let unavailable = DesktopCapturePicker(
      request: capture,
      store: store,
      hasScreenRecordingAccess: { true },
      shareableContent: { throw CocoaError(.fileReadUnknown) }
    )
    await unavailable.loadSources()
  }

  @Test func requestsScreenRecordingPermissionBeforeEnumeratingSources() async throws {
    let store = store()
    let capture = try request(store)
    var requestCount = 0
    var enumerationCount = 0
    let denied = DesktopCapturePicker(
      request: capture,
      store: store,
      hasScreenRecordingAccess: { false },
      requestScreenRecordingAccess: {
        requestCount += 1
        return false
      },
      shareableContent: {
        enumerationCount += 1
        throw CocoaError(.fileReadUnknown)
      }
    )

    await denied.loadSources()
    #expect(requestCount == 1)
    #expect(enumerationCount == 0)

    let granted = DesktopCapturePicker(
      request: capture,
      store: store,
      hasScreenRecordingAccess: { false },
      requestScreenRecordingAccess: {
        requestCount += 1
        return true
      },
      shareableContent: {
        enumerationCount += 1
        throw CocoaError(.fileReadUnknown)
      }
    )
    await granted.loadSources()
    #expect(requestCount == 2)
    #expect(enumerationCount == 1)
  }

  @Test func rejectsMalformedOrInsecureDesktopCapturePayloads() throws {
    let original = try request(store(), id: UUID().uuidString)
    let valid: [String: Any] = [
      "id": original.id,
      "profileID": original.profileID.uuidString,
      "tabID": original.tabID.uuidString,
      "pageURL": original.pageURL.absoluteString,
      "origin": original.requestingOrigin.absoluteString,
      "frameID": original.frameID,
    ]
    #expect(DesktopCaptureRequest(payload: valid) != nil)

    for (key, value) in [
      ("id", "not-a-uuid" as Any),
      ("profileID", "not-a-uuid" as Any),
      ("tabID", "not-a-uuid" as Any),
      ("pageURL", "file:///tmp/page" as Any),
      ("origin", "http://meet.google.com" as Any),
      ("origin", "https://meet.google.com/path" as Any),
      ("frameID", 4 as Any),
      ("frameID", "wrong-frame" as Any),
    ] {
      var malformed = valid
      malformed[key] = value
      #expect(DesktopCaptureRequest(payload: malformed) == nil)
    }

    for key in valid.keys {
      var missing = valid
      missing.removeValue(forKey: key)
      #expect(DesktopCaptureRequest(payload: missing) == nil)
    }

    var localHTTP = valid
    localHTTP["origin"] = "http://localhost:3000"
    #expect(DesktopCaptureRequest(payload: localHTTP) != nil)
  }

  @Test func resolvesOnlyPresentedCurrentRequestAndCancelsDismissedRequest() throws {
    let store = store()
    let first = try request(store, id: UUID().uuidString)
    let second = try request(store, id: UUID().uuidString)
    var decisions: [String] = []
    store.onDesktopCaptureDecision = { id, sourceID in
      decisions.append("\(id):\(sourceID ?? "cancel")")
    }

    #expect(store.requestDesktopCapture(first))
    #expect(store.requestDesktopCapture(second))
    store.setDesktopCaptureSources(["screen:1:0"], for: first.id)
    store.setDesktopCaptureSources(["window:2:0"], for: second.id)
    #expect(store.sheet?.id == first.sheetID)
    store.resolveDesktopCapture(first.id, sourceID: "screen:1:0")
    #expect(decisions == ["\(first.id):screen:1:0"])
    #expect(store.sheet?.id == second.sheetID)

    store.resolveDesktopCapture(second.id, sourceID: "window:2:0")
    #expect(decisions == ["\(first.id):screen:1:0", "\(second.id):window:2:0"])

    let third = try request(store, id: UUID().uuidString)
    let fourth = try request(store, id: UUID().uuidString)
    #expect(store.requestDesktopCapture(third))
    #expect(store.requestDesktopCapture(fourth))
    store.setDesktopCaptureSources(["screen:3:0"], for: third.id)
    store.setDesktopCaptureSources(["window:4:0"], for: fourth.id)
    store.resolveDesktopCapture(fourth.id, sourceID: "window:4:0")
    #expect(
      decisions == [
        "\(first.id):screen:1:0", "\(second.id):window:2:0", "\(fourth.id):cancel",
      ])
    #expect(store.sheet?.id == third.sheetID)

    store.dismissDesktopCapture(third.id)
    store.resolveDesktopCapture(third.id, sourceID: "window:3:0")
    #expect(
      decisions == [
        "\(first.id):screen:1:0", "\(second.id):window:2:0", "\(fourth.id):cancel",
      ])
    #expect(store.sheet == nil)
  }

  @Test func stalePageAndRendererFailureDenyDesktopCapture() throws {
    let browser = store()
    let stale = try request(browser, id: UUID().uuidString)
    var decisions: [String] = []
    browser.onDesktopCaptureDecision = { id, sourceID in
      decisions.append("\(id):\(sourceID ?? "cancel")")
    }

    #expect(browser.requestDesktopCapture(stale))
    browser.setDesktopCaptureSources(["screen:1:0"], for: stale.id)
    browser.perform(.open(URL(string: "https://meet.google.com/another")!))
    browser.resolveDesktopCapture(stale.id, sourceID: "screen:1:0")
    #expect(decisions == ["\(stale.id):cancel"])

    let failedStore = store()
    let rendererFailure = try request(failedStore, id: UUID().uuidString)
    var rendererDecisions: [String?] = []
    failedStore.onDesktopCaptureDecision = { _, sourceID in rendererDecisions.append(sourceID) }
    #expect(failedStore.requestDesktopCapture(rendererFailure))
    failedStore.setDesktopCaptureSources(["window:1:0"], for: rendererFailure.id)
    failedStore.nativeRendererGone(
      rendererFailure.tabID, profileID: rendererFailure.profileID, status: "crashed", exitCode: 1)
    failedStore.resolveDesktopCapture(rendererFailure.id, sourceID: "window:1:0")
    #expect(rendererDecisions == [nil])
  }

  @Test func aPageTitleCannotOpenTheCaptureSheet() throws {
    let store = store()
    let tab = try #require(store.session.selectedSpace.selectedTab)
    let marker = "\u{2060}shaar-prompt\u{2060}display\u{2060}\(UUID().uuidString)"
    store.nativeTabChanged(tab.id, url: tab.url, title: marker)
    #expect(store.sheet == nil)
    #expect(store.session.selectedSpace.selectedTab?.title == marker)
  }

  @Test func rejectsAnUnsolicitedCaptureRequest() throws {
    let store = store()
    let capture = try request(store)
    var payload: [String: Any] = [
      "id": UUID().uuidString,
      "profileID": capture.profileID.uuidString,
      "tabID": UUID().uuidString,
      "pageURL": capture.pageURL.absoluteString,
      "origin": capture.requestingOrigin.absoluteString,
      "frameID": "fedcba9876543210fedcba9876543210",
    ]
    let foreign = try #require(DesktopCaptureRequest(payload: payload))
    #expect(!store.requestDesktopCapture(foreign))
    #expect(store.sheet == nil)

    payload["tabID"] = capture.tabID.uuidString
    payload["sourceTypes"] = ["printer"]
    #expect(DesktopCaptureRequest(payload: payload) == nil)
    payload["sourceTypes"] = ["tab"]
    let tabsOnly = try #require(DesktopCaptureRequest(payload: payload))
    #expect(tabsOnly.allowedKinds == [.tab])
    #expect(store.requestDesktopCapture(tabsOnly))
    store.setDesktopCaptureSources(["tab:\(capture.tabID.uuidString):0"], for: tabsOnly.id)
    var decision: String?
    store.onDesktopCaptureDecision = { _, sourceID in decision = sourceID }
    store.resolveDesktopCapture(tabsOnly.id, sourceID: "tab:\(capture.tabID.uuidString):0")
    #expect(decision == "tab:\(capture.tabID.uuidString):0")
    #expect(store.sheet == nil)
  }

  @Test func rejectsMalformedOrUnlistedCaptureTokens() throws {
    let store = store()
    let capture = try request(store)
    #expect(store.requestDesktopCapture(capture))
    store.setDesktopCaptureSources(["screen:1:0"], for: capture.id)
    var decision: String?
    store.onDesktopCaptureDecision = { _, sourceID in decision = sourceID ?? "cancel" }

    store.resolveDesktopCapture(capture.id, sourceID: "screen:999:0")
    #expect(decision == "cancel")
    #expect(!DesktopCaptureSource.isValidToken("screen:-1:0"))
    #expect(!DesktopCaptureSource.isValidToken("screen:0:0"))
    #expect(!DesktopCaptureSource.isValidToken("window:0:0"))
    #expect(!DesktopCaptureSource.isValidToken("window:01:0"))
    #expect(!DesktopCaptureSource.isValidToken("tab:not-a-uuid:0"))
  }

  @Test func deniesCaptureWhenRememberedFrameOrOriginChanged() throws {
    let store = store()
    let capture = try request(store)
    let tab = try #require(store.session.selectedSpace.selectedTab)
    store.rememberPermissionFrame(
      tab.id, frameID: "fedcba9876543210fedcba9876543210",
      origin: URL(string: "https://other.example")!)
    #expect(store.requestDesktopCapture(capture))
    store.setDesktopCaptureSources(["screen:1:0"], for: capture.id)
    var decision: String?
    store.onDesktopCaptureDecision = { _, sourceID in decision = sourceID }
    store.resolveDesktopCapture(capture.id, sourceID: "screen:1:0")
    #expect(decision == nil)
  }

  @Test func privateWindowListsOnlyItsOwnTab() throws {
    let regular = store()
    let regularTab = try #require(regular.session.selectedSpace.selectedTab)
    let privateTab = UUID()
    var privateSession = try BrowserSession.privateWindow(
      sourceProfileID: regular.session.selectedSpace.profileID, firstTabID: privateTab)
    let updatedPrivateTab = privateSession.updateTab(
      privateTab, url: URL(string: "https://private.example")!, title: "Private page")
    #expect(updatedPrivateTab)
    let listed = DesktopCaptureCatalog.tabSources(
      session: privateSession, profileID: privateSession.selectedSpace.profileID,
      requestingTabID: privateTab)
    #expect(listed.map(\.id) == ["tab:\(privateTab.uuidString):0"])
    #expect(listed.allSatisfy { !$0.id.contains(regularTab.id.uuidString) })

    let other = try #require(
      regular.session.spaces.first { $0.profileID != regular.session.selectedSpace.profileID })
    let own = DesktopCaptureCatalog.tabSources(
      session: regular.session, profileID: regular.session.selectedSpace.profileID,
      requestingTabID: regularTab.id)
    let otherIDs = Set(other.tabs.map { "tab:\($0.id.uuidString):0" })
    #expect(own.allSatisfy { !otherIDs.contains($0.id) })
  }

  @Test func tabSourcesStayAvailableWithoutScreenRecording() throws {
    let store = store()
    let capture = try request(store)
    let tab = try #require(store.session.selectedSpace.selectedTab)
    let tabs = DesktopCaptureCatalog.tabSources(
      session: store.session, profileID: capture.profileID, requestingTabID: capture.tabID)
    let denied = DesktopCaptureCatalog.listing(tabs: tabs, screens: [], screenAccessFailed: true)
    #expect(denied.error == nil)
    #expect(denied.note == DesktopCaptureCatalog.screenAccessNote)
    #expect(denied.sources.first?.id == "tab:\(tab.id.uuidString):0")
    #expect(denied.sources.first?.label == PanelsL10n.string("This Tab"))

    let screen = DesktopCaptureSource(id: "screen:1:0", name: "Main Display", kind: .display)
    let window = DesktopCaptureSource(id: "window:4:0", name: "Notes", kind: .window)
    let ready = DesktopCaptureCatalog.listing(
      tabs: tabs, screens: [screen, window], screenAccessFailed: false)
    #expect(ready.sources.map(\.kind) == [.tab, .display, .window])
    #expect(ready.note == nil)
    #expect(window.label.contains("Notes"))
    let other = DesktopCaptureSource(id: "tab:other:0", name: "Mail", kind: .tab)
    #expect(other.label == PanelsL10n.format("Tab: %@", .string("Mail")))

    let empty = DesktopCaptureCatalog.listing(tabs: [], screens: [], screenAccessFailed: true)
    #expect(empty.error == DesktopCaptureCatalog.screenAccessNote)
    #expect(empty.sources.isEmpty)
  }

  @Test func tabSourcesExcludeBrowserInternalPages() throws {
    var session = store().session
    let profileID = session.selectedSpace.profileID
    let requestingTabID = try #require(session.selectedSpace.selectedTab?.id)
    #expect(
      session.insertNativeTab(
        BrowserTab(url: URL(string: "about:blank")!), profileID: profileID,
        openerID: requestingTabID, foreground: false) != nil)
    #expect(
      session.insertNativeTab(
        BrowserTab(url: URL(string: "devtools://devtools/bundled/js_app.html")!),
        profileID: profileID, openerID: requestingTabID, foreground: false) != nil)

    let sources = DesktopCaptureCatalog.tabSources(
      session: session,
      profileID: profileID,
      requestingTabID: requestingTabID
    )

    #expect(sources.map(\.id) == ["tab:\(requestingTabID.uuidString):0"])
  }

  @Test func tabSourceFallsBackToPageHostWhenSavedTitleIsBlank() throws {
    let original = store().session
    let spaceIndex = try #require(
      original.spaces.firstIndex {
        $0.profileID == original.selectedSpace.profileID
      })
    var spaces = original.spaces
    let tabIndex = try #require(spaces[spaceIndex].tabs.indices.first)
    let tabID = spaces[spaceIndex].tabs[tabIndex].id
    spaces[spaceIndex].tabs[tabIndex].title = " \n\t"
    let session = try BrowserSession(
      profiles: original.profiles,
      spaces: spaces,
      selectedSpaceID: original.selectedSpaceID
    )

    let sources = DesktopCaptureCatalog.tabSources(
      session: session,
      profileID: session.selectedSpace.profileID,
      requestingTabID: UUID()
    )

    #expect(sources.first?.id == "tab:\(tabID.uuidString):0")
    #expect(sources.first?.name == "meet.google.com")
    #expect(sources.first?.label == PanelsL10n.format("Tab: %@", .string("meet.google.com")))
  }

  @Test func catalogExposesOnlyRequestedCaptureSourceKinds() throws {
    let store = store()
    let base = try request(store)
    let sources = [
      DesktopCaptureSource(
        id: "tab:\(base.tabID.uuidString):0", name: "Current", kind: .tab),
      DesktopCaptureSource(id: "screen:0:0", name: "Invalid Display", kind: .display),
      DesktopCaptureSource(id: "screen:1:0", name: "Display", kind: .display),
      DesktopCaptureSource(id: "screen:3:0", name: "Wrong kind", kind: .window),
      DesktopCaptureSource(id: "window:0:0", name: "Invalid Window", kind: .window),
      DesktopCaptureSource(id: "window:2:0", name: "Notes", kind: .window),
    ]

    var screenPayload: [String: Any] = [
      "id": UUID().uuidString,
      "profileID": base.profileID.uuidString,
      "tabID": base.tabID.uuidString,
      "pageURL": base.pageURL.absoluteString,
      "origin": base.requestingOrigin.absoluteString,
      "frameID": base.frameID,
      "sourceTypes": ["screen"],
    ]
    let screenOnly = try #require(DesktopCaptureRequest(payload: screenPayload))
    #expect(
      DesktopCaptureCatalog.allowedSources(sources, for: screenOnly).map(\.id)
        == ["screen:1:0"])

    screenPayload["sourceTypes"] = ["window"]
    let windowOnly = try #require(DesktopCaptureRequest(payload: screenPayload))
    #expect(
      DesktopCaptureCatalog.allowedSources(sources, for: windowOnly).map(\.id)
        == ["window:2:0"])

    screenPayload["sourceTypes"] = ["tab"]
    let tabOnly = try #require(DesktopCaptureRequest(payload: screenPayload))
    #expect(
      DesktopCaptureCatalog.allowedSources(sources, for: tabOnly).map(\.id)
        == ["tab:\(base.tabID.uuidString):0"])
  }

  @Test func staleProfileAndNavigationInvalidateRequestOwnership() throws {
    let browser = store()
    let capture = try request(browser, id: UUID().uuidString)
    browser.cycleSpace(by: 1)
    #expect(!capture.matches(browser.session))

    let sameProfileStore = store()
    let sameProfileRequest = try request(sameProfileStore, id: UUID().uuidString)
    sameProfileStore.perform(.open(URL(string: "https://meet.google.com/another")!))
    #expect(!sameProfileRequest.matches(sameProfileStore.session))
  }
}
