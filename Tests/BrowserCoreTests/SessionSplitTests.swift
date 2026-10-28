import BrowserCore
import Foundation
import XCTest

final class SessionSplitTests: XCTestCase {
  func testRoundTripAndOldSessionDecode() throws {
    var session = BrowserSession.fresh()
    let first = try XCTUnwrap(session.open(URL(string: "https://one.example")!))
    let second = try XCTUnwrap(session.open(URL(string: "https://two.example")!))
    XCTAssertTrue(session.splitTabs(first, second, in: session.selectedSpaceID))
    let data = try JSONEncoder().encode(session)
    XCTAssertEqual(try JSONDecoder().decode(BrowserSession.self, from: data), session)
    var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    var spaces = try XCTUnwrap(object["spaces"] as? [[String: Any]])
    for index in spaces.indices { spaces[index].removeValue(forKey: "splits") }
    object["spaces"] = spaces
    let old = try JSONSerialization.data(withJSONObject: object)
    XCTAssertTrue(try JSONDecoder().decode(BrowserSession.self, from: old).selectedSpace.splits.isEmpty)
  }

  func testWorkspaceProjectionPreservesWindowSplits() throws {
    var session = BrowserSession.fresh()
    let first = try XCTUnwrap(session.open(URL(string: "https://one.example")!))
    let second = try XCTUnwrap(session.open(URL(string: "https://two.example")!))
    XCTAssertTrue(session.splitTabs(first, second, in: session.selectedSpaceID))
    var workspace = try BrowserWorkspace(session: session)
    let firstWindow = try XCTUnwrap(workspace.focusedWindowID)
    let otherWindow = try workspace.addWindow(from: firstWindow)
    XCTAssertTrue(try XCTUnwrap(workspace.window(otherWindow)).session.selectedSpace.splits.isEmpty)
    _ = try workspace.createProfile(name: "Another")
    XCTAssertEqual(try XCTUnwrap(workspace.window(firstWindow)).session.selectedSpace.splits.first?.tabIDs, [first, second])
    try workspace.validate()
  }

  func testCloseAndMoveReconcileSplits() throws {
    var session = BrowserSession.fresh()
    let spaceID = session.selectedSpaceID
    let first = try XCTUnwrap(session.open(URL(string: "https://one.example")!))
    let second = try XCTUnwrap(session.open(URL(string: "https://two.example")!))
    XCTAssertTrue(session.splitTabs(first, second, in: spaceID))
    session.closeTab(first)
    XCTAssertTrue(session.selectedSpace.splits.isEmpty)
    let third = try XCTUnwrap(session.open(URL(string: "https://three.example")!))
    XCTAssertTrue(session.splitTabs(second, third, in: spaceID))
    let destination = try XCTUnwrap(session.addSpace(name: "Other", sharingProfile: session.selectedSpace.profileID))
    XCTAssertTrue(session.moveTab(second, from: spaceID, to: destination))
    XCTAssertTrue(try XCTUnwrap(session.spaces.first { $0.id == spaceID }).splits.isEmpty)
    try session.validate()
  }
}
