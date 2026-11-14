import BrowserCore
import ChromiumBridge
import Foundation
import Testing

@testable import ArcusisBrowser

@Suite @MainActor
struct InspectorConnectionTests {
  @Test func beginRequiresMatchingProfileAndNativeWindowOwnership() throws {
    let store = BrowserStore()
    store.perform(.open(try #require(URL(string: "https://inspector.example/page"))))
    let tab = try #require(store.session.selectedSpace.selectedTab)
    let profileID = try #require(store.session.profileID(forTabID: tab.id))
    let runtime = InspectorConnectionRuntime()
    let tabID = tab.id.uuidString
    runtime.tabOwners[tabID] = "inspector-window"
    runtime.profileOwners[tabID] = profileID.uuidString
    let engine = try BrowserEngine(
      events: BrowserRuntimeEvents(runtime: runtime), windowID: "inspector-window", store: store)
    let connection = InspectorConnection(engine: engine)
    let target = SiteControlTarget(tabID: tab.id, profileID: profileID, url: tab.url)

    #expect(connection.begin(target))
    #expect(runtime.begunTabs == [tabID])

    runtime.tabOwners[tabID] = "another-window"
    #expect(!connection.begin(target))
    #expect(runtime.begunTabs == [tabID])

    let wrongProfile = SiteControlTarget(tabID: tab.id, profileID: UUID(), url: tab.url)
    #expect(!connection.begin(wrongProfile))
    #expect(runtime.begunTabs == [tabID])
  }
}

@MainActor
private final class InspectorConnectionRuntime: ARCChromiumRuntime {
  nonisolated(unsafe) var tabOwners: [String: String] = [:]
  nonisolated(unsafe) var profileOwners: [String: String] = [:]
  nonisolated(unsafe) var begunTabs: [String] = []

  override func windowID(forTabID tabID: String) -> String? { tabOwners[tabID] }
  override func profileID(forTabID tabID: String) -> String? { profileOwners[tabID] }

  override func beginInspector(forTabID tabID: String, profileID: String, windowID: String) -> Bool
  {
    begunTabs.append(tabID)
    return true
  }
}
