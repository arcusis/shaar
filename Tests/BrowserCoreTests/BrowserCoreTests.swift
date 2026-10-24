import Foundation
import Testing

@testable import BrowserCore

private func openTab(_ address: String, in session: inout BrowserSession) throws -> UUID {
  let id = session.open(try #require(URL(string: address)))
  return try #require(id)
}

@Test func switchingSpacesPreservesTabIdentityAndSelection() throws {
  var session = BrowserSession.fresh()
  let personal = session.selectedSpaceID
  let first = try openTab("https://example.com/personal", in: &session)
  session.cycleSpace(by: 1)
  let work = session.selectedSpaceID
  let second = try openTab("https://example.com/work", in: &session)
  #expect(session.spaces[0].profileID != session.spaces[1].profileID)
  for _ in 0..<20 {
    session.selectSpace(personal)
    #expect(session.selectedSpace.selectedTabID == first)
    session.selectSpace(work)
    #expect(session.selectedSpace.selectedTabID == second)
  }
  #expect(session.spaces.flatMap(\.tabs).count == 2)
}

@Test func profileSharingIsExplicitAndNewSpacesDefaultToNewProfiles() throws {
  var session = BrowserSession.fresh()
  let initialProfile = session.selectedSpace.profileID
  session.addSpace(name: "Project", sharingProfile: initialProfile)
  #expect(session.selectedSpace.profileID == initialProfile)
  #expect(session.profiles.count == 2)
  session.addSpace(name: "Separate account")
  #expect(session.selectedSpace.profileID != initialProfile)
  #expect(session.profiles.count == 3)
  let before = session
  let empty = session.addSpace(name: " ")
  let invalid = session.addSpace(name: "Invalid", sharingProfile: UUID())
  #expect(empty == nil)
  #expect(invalid == nil)
  #expect(session == before)
}

@Test func selectingCrossSpaceResultDoesNotDuplicateTab() throws {
  var session = BrowserSession.fresh()
  let personal = session.selectedSpaceID
  let tab = try openTab("https://example.com", in: &session)
  session.cycleSpace(by: 1)
  let result = try #require(CommandSearch.results(for: "example", in: session).first)
  #expect(result.action == .tab(space: personal, tab: tab))
  session.selectTab(tab, in: personal)
  #expect(session.selectedSpaceID == personal)
  #expect(session.selectedSpace.selectedTabID == tab)
  #expect(session.spaces.flatMap(\.tabs).count == 1)
}

@Test func closingTabsSelectsNeighborAndNeverChangesOtherSpaces() throws {
  var session = BrowserSession.fresh()
  let first = try openTab("https://example.com/1", in: &session)
  let second = try openTab("https://example.com/2", in: &session)
  let third = try openTab("https://example.com/3", in: &session)
  let otherSpace = session.spaces[1]
  session.closeTab(first)
  #expect(session.selectedSpace.selectedTabID == third)
  session.closeTab(third)
  #expect(session.selectedSpace.selectedTabID == second)
  session.closeTab(second)
  #expect(session.selectedSpace.tabs.isEmpty)
  #expect(session.selectedSpace.selectedTabID == nil)
  #expect(session.spaces[1] == otherSpace)
}

@Test func sessionRoundTripPreservesProfileAssignmentsPinsAndSelection() throws {
  let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: directory) }
  let file = SessionFile(url: directory.appending(path: "session.json"))
  #expect(try file.load() == nil)
  var session = BrowserSession.fresh()
  let tab = try openTab("https://example.com", in: &session)
  session.togglePin(tab)
  session.cycleSpace(by: 1)
  try file.save(session)
  #expect(try file.load() == session)
  let attributes = try FileManager.default.attributesOfItem(atPath: file.url.path)
  #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
}

@Test func malformedOrFutureSessionsFailAtDecodeBoundary() throws {
  let valid = try JSONEncoder().encode(BrowserSession.fresh())
  var object = try #require(JSONSerialization.jsonObject(with: valid) as? [String: Any])
  object["version"] = 99
  let future = try JSONSerialization.data(withJSONObject: object)
  #expect(throws: SessionError.unsupportedVersion) {
    try JSONDecoder().decode(BrowserSession.self, from: future)
  }
  object["version"] = 1
  object["selectedSpaceID"] = UUID().uuidString
  let broken = try JSONSerialization.data(withJSONObject: object)
  #expect(throws: SessionError.invalidState) {
    try JSONDecoder().decode(BrowserSession.self, from: broken)
  }
}

@Test func profilesAndTabsCannotBeOrphanedOrDuplicated() throws {
  let profile = BrowserProfile(name: "Work")
  let tab = BrowserTab(url: URL(string: "https://example.com")!)
  let orphan = BrowserSpace(profileID: UUID(), name: "Orphan", symbol: "house", tint: .ocean)
  #expect(throws: SessionError.invalidState) {
    try BrowserSession(profiles: [profile], spaces: [orphan], selectedSpaceID: orphan.id)
  }
  let duplicated = BrowserSpace(
    profileID: profile.id, name: "Work", symbol: "briefcase", tint: .ocean, tabs: [tab, tab]
  )
  #expect(throws: SessionError.invalidState) {
    try BrowserSession(profiles: [profile], spaces: [duplicated], selectedSpaceID: duplicated.id)
  }
}

@Test func navigationInputDistinguishesURLsSearchAndUnsupportedSchemes() throws {
  #expect(
    NavigationInput.destination(for: " example.com/path ")?.absoluteString
      == "https://example.com/path")
  #expect(
    NavigationInput.destination(for: "http://localhost:3000")?.absoluteString
      == "http://localhost:3000")
  let search = try #require(NavigationInput.destination(for: "SwiftUI & AppKit"))
  let parts = try #require(URLComponents(url: search, resolvingAgainstBaseURL: false))
  #expect(parts.queryItems?.first?.value == "SwiftUI & AppKit")
  for input in [
    "", " ", "javascript:alert(1)", "data:text/html,hello", "file:///etc/passwd", "custom://host",
  ] {
    #expect(NavigationInput.destination(for: input) == nil)
  }
}

@Test func commandResultsAlwaysKeepNavigationAvailable() {
  var session = BrowserSession.fresh()
  for index in 0..<20 { session.open(URL(string: "https://example.com/\(index)")!) }
  let results = CommandSearch.results(for: "example.com", in: session)
  #expect(results.count == 10)
  #expect(results.last?.action == .open(URL(string: "https://example.com")!))
}
