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
    XCTAssertTrue(
      try JSONDecoder().decode(BrowserSession.self, from: old).selectedSpace.splits.isEmpty)
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
    XCTAssertEqual(
      try XCTUnwrap(workspace.window(firstWindow)).session.selectedSpace.splits.first?.tabIDs,
      [first, second])
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
    let destination = try XCTUnwrap(
      session.addSpace(name: "Other", sharingProfile: session.selectedSpace.profileID))
    XCTAssertTrue(session.moveTab(second, from: spaceID, to: destination))
    XCTAssertTrue(try XCTUnwrap(session.spaces.first { $0.id == spaceID }).splits.isEmpty)
    try session.validate()
  }
}

final class SplitLayoutTests: XCTestCase {
  private func session(tabs count: Int) throws -> (BrowserSession, [UUID]) {
    var session = BrowserSession.fresh()
    let ids = try (0..<count).map { index in
      try XCTUnwrap(session.open(URL(string: "https://tab\(index).example")!))
    }
    return (session, ids)
  }

  func testEdgesBuildMixedLayoutAndCapAtFour() throws {
    var (session, ids) = try session(tabs: 5)
    let space = session.selectedSpaceID
    XCTAssertTrue(session.addToSplit(ids[1], beside: ids[0], edge: .right, in: space))
    XCTAssertTrue(session.addToSplit(ids[2], beside: ids[1], edge: .bottom, in: space))
    let split = try XCTUnwrap(session.selectedSpace.splits.first)
    XCTAssertEqual(
      split.root,
      .group(
        .columns, [.pane(ids[0]), .group(.rows, [.pane(ids[1]), .pane(ids[2])], [0.5, 0.5])],
        [0.5, 0.5]))
    XCTAssertEqual(SplitLayoutPreset.matching(split.root), .mainLeading)
    XCTAssertTrue(session.addToSplit(ids[3], beside: ids[0], edge: .left, in: space))
    XCTAssertEqual(session.selectedSpace.splits.first?.tabIDs, [ids[3], ids[0], ids[1], ids[2]])
    XCTAssertFalse(session.addToSplit(ids[4], beside: ids[0], edge: .right, in: space))
    try session.validate()
  }

  func testPresetsRearrangeKeepingOrder() throws {
    var (session, ids) = try session(tabs: 3)
    let space = session.selectedSpaceID
    XCTAssertTrue(session.splitTabs(ids[0], ids[1], in: space))
    XCTAssertTrue(session.addToSplit(ids[2], beside: ids[1], edge: .right, in: space))
    let splitID = try XCTUnwrap(session.selectedSpace.splits.first?.id)
    XCTAssertEqual(
      SplitLayoutPreset.matching(try XCTUnwrap(session.selectedSpace.splits.first).root), .columns)
    for preset in SplitLayoutPreset.available(paneCount: 3) {
      XCTAssertTrue(session.applySplitLayout(preset, splitID: splitID, in: space))
      let root = try XCTUnwrap(session.selectedSpace.splits.first).root
      XCTAssertEqual(SplitLayoutPreset.matching(root), preset)
      XCTAssertEqual(root.paneIDs, ids)
    }
    XCTAssertFalse(session.applySplitLayout(.grid, splitID: splitID, in: space))
    try session.validate()
  }

  func testClosingCollapsesGroupsAndWeightsStayValid() throws {
    var (session, ids) = try session(tabs: 3)
    let space = session.selectedSpaceID
    XCTAssertTrue(session.splitTabs(ids[0], ids[1], in: space))
    XCTAssertTrue(session.addToSplit(ids[2], beside: ids[1], edge: .bottom, in: space))
    let splitID = try XCTUnwrap(session.selectedSpace.splits.first?.id)
    session.setSplitWeights([0.3, 0.7], at: [1], splitID: splitID, in: space)
    session.setSplitWeights([2, 0], at: [], splitID: splitID, in: space)
    try session.validate()
    session.closeTab(ids[1])
    XCTAssertEqual(
      session.selectedSpace.splits.first?.root,
      .group(.columns, [.pane(ids[0]), .pane(ids[2])], [0.5, 0.5]))
    try session.validate()
  }

  func testLegacyTwoTabSplitDecodes() throws {
    let first = UUID()
    let second = UUID()
    let id = UUID()
    let json = #"{"id":"\#(id)","tabIDs":["\#(first)","\#(second)"],"ratio":0.3}"#
    let split = try JSONDecoder().decode(BrowserSplit.self, from: Data(json.utf8))
    XCTAssertEqual(split.root, .group(.columns, [.pane(first), .pane(second)], [0.3, 0.7]))
    let roundTrip = try JSONDecoder().decode(BrowserSplit.self, from: JSONEncoder().encode(split))
    XCTAssertEqual(roundTrip, split)
  }
}
