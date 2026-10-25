import AppKit
import BrowserCore
import Foundation
import Testing

@testable import ArcusisBrowser

@Suite
struct SpaceSwipeNavigationTests {
  @MainActor
  @Test func monitorRoutesAuthoredWindowEventWithLibraryDrawerGuard() throws {
    let pageURL = URL(string: "https://example.test")!
    let profile = BrowserProfile(name: "Personal")
    let otherProfile = BrowserProfile(name: "Work")
    let tab = BrowserTab(url: pageURL)
    let selectedSpace = BrowserSpace(
      profileID: profile.id, name: "Personal", symbol: "house", tint: .lavender,
      tabs: [tab], selectedTabID: tab.id)
    let otherSpace = BrowserSpace(
      profileID: otherProfile.id, name: "Work", symbol: "briefcase", tint: .ocean)
    let session = try BrowserSession(
      profiles: [profile, otherProfile], spaces: [selectedSpace, otherSpace],
      selectedSpaceID: selectedSpace.id)
    let store = BrowserStore(sessionFile: nil, session: session)
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
      styleMask: [.titled], backing: .buffered, defer: false)
    let foreignWindow = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
      styleMask: [.titled], backing: .buffered, defer: false)
    let monitor = SpaceSwipeWindowMonitor.owner(for: window)
    let client = NSObject()
    monitor.attach(client, store: store)
    defer { monitor.detach(client) }
    let initialSpaceID = store.session.selectedSpaceID
    let authoredEvent = try #require(makeWindowEvent(for: window))

    #expect(store.showLibraryDrawer(.spaces))
    #expect(monitor.route(authoredEvent, deltaX: 2, deltaY: 0) === authoredEvent)
    #expect(store.session.selectedSpaceID == initialSpaceID)

    store.closeLibraryDrawer()
    #expect(monitor.route(authoredEvent, deltaX: 2, deltaY: 0) == nil)
    #expect(store.session.selectedSpaceID != initialSpaceID)
    let afterClosedDrawerSwipeSpaceID = store.session.selectedSpaceID

    let wrongWindowSwipe = try #require(makeWindowEvent(for: foreignWindow))
    #expect(monitor.route(wrongWindowSwipe, deltaX: 2, deltaY: 0) === wrongWindowSwipe)
    #expect(store.session.selectedSpaceID == afterClosedDrawerSwipeSpaceID)

    store.perform(.space(selectedSpace.id))
    let afterSwipeSpaceID = store.session.selectedSpaceID
    let request = try #require(
      WebsiteMediaRequest(
        id: "swipe-consent", profileID: profile.id,
        tabID: tab.id, pageURL: pageURL,
        requestingOrigin: URL(string: "https://example.test")!, kinds: [.camera]))
    #expect(store.requestWebsiteMedia(request))
    #expect(monitor.route(authoredEvent, deltaX: 2, deltaY: 0) === authoredEvent)
    #expect(store.session.selectedSpaceID == afterSwipeSpaceID)
  }

  @Test func handledSwipeConsumesEventAndCyclesInExpectedDirection() {
    var offsets: [Int] = []

    let previous = SpaceSwipeNavigationDecision.route(
      deltaX: 2, deltaY: 0, eventBelongsToWindow: true,
      commandPressed: false, modalOwnsInput: false
    ) { offsets.append($0) }
    let next = SpaceSwipeNavigationDecision.route(
      deltaX: -2, deltaY: 0, eventBelongsToWindow: true,
      commandPressed: false, modalOwnsInput: false
    ) { offsets.append($0) }

    #expect(previous == .consumed)
    #expect(next == .consumed)
    #expect(offsets == [-1, 1])
  }

  @Test func ignoredSwipeForwardsEventWithoutChangingSpace() {
    let cases: [(CGFloat, CGFloat, Bool, Bool, Bool)] = [
      (0, 2, true, false, false),
      (2, 2, true, false, false),
      (2, 0, false, false, false),
      (2, 0, true, true, false),
      (2, 0, true, false, true),
    ]
    var actions = 0

    for (deltaX, deltaY, belongs, command, modal) in cases {
      let result = SpaceSwipeNavigationDecision.route(
        deltaX: deltaX, deltaY: deltaY, eventBelongsToWindow: belongs,
        commandPressed: command, modalOwnsInput: modal
      ) { _ in actions += 1 }
      #expect(result == .forwarded)
    }

    #expect(actions == 0)
  }

  @MainActor
  @Test func monitorOwnershipInstallsOnceAndCleansUpAtLastDetachOrInvalidation() {
    final class Client {}
    var installs = 0
    var removals = 0
    let ownership = SpaceSwipeMonitorOwnership(
      install: { installs += 1 }, remove: { removals += 1 })
    let first = Client()
    let second = Client()

    ownership.attach(first)
    ownership.attach(first)
    ownership.attach(second)
    #expect(installs == 1)
    #expect(removals == 0)

    ownership.detach(first)
    #expect(removals == 0)
    #expect(ownership.hasClients)

    ownership.detach(second)
    ownership.detach(second)
    #expect(removals == 1)
    #expect(!ownership.hasClients)

    ownership.attach(first)
    ownership.invalidate()
    ownership.invalidate()
    #expect(installs == 2)
    #expect(removals == 2)
  }

  @MainActor
  @Test func destroyedClientReleasesMonitorOwnership() {
    final class Client {}
    var installs = 0
    var removals = 0
    let ownership = SpaceSwipeMonitorOwnership(
      install: { installs += 1 }, remove: { removals += 1 })
    var client: Client? = Client()

    ownership.attach(client!)
    #expect(installs == 1)
    #expect(ownership.hasClients)

    client = nil

    #expect(!ownership.hasClients)
    #expect(removals == 1)
  }

  @MainActor
  private func makeWindowEvent(for window: NSWindow) -> NSEvent? {
    NSEvent.mouseEvent(
      with: .leftMouseDragged, location: NSPoint(x: 2, y: 0), modifierFlags: [],
      timestamp: 0, windowNumber: window.windowNumber, context: nil,
      eventNumber: 1, clickCount: 1,
      pressure: 1)
  }
}
