import Foundation
import Testing

@testable import BrowserCore

@Test func spaceRGBColorRoundTripsExactChannelsAndHex() throws {
  let color = SpaceRGBColor(red: 0, green: 127, blue: 255)
  let data = try JSONEncoder().encode(color)
  #expect(try JSONDecoder().decode(SpaceRGBColor.self, from: data) == color)
  #expect(color.hex == "#007FFF")
  #expect(SpaceRGBColor(hex: "#007fff") == color)
  #expect(SpaceRGBColor(hex: "GG0000") == nil)
  #expect(SpaceRGBColor(hex: "#FFFFF") == nil)
  #expect(SpaceRGBColor(hex: "+00001") == nil)
}

@Test func spaceRGBColorRejectsOutOfRangeAndMalformedJSON() throws {
  for json in [
    #"{"red":256,"green":0,"blue":0}"#,
    #"{"red":0,"green":-1,"blue":0}"#,
    #"{"red":0,"green":0}"#,
  ] {
    #expect(throws: (any Error).self) {
      try JSONDecoder().decode(SpaceRGBColor.self, from: Data(json.utf8))
    }
  }
}

@Test func legacySpaceJSONDecodesWithNoCustomColor() throws {
  let session = BrowserSession.fresh()
  var json = try #require(
    JSONSerialization.jsonObject(with: JSONEncoder().encode(session)) as? [String: Any])
  var spaces = try #require(json["spaces"] as? [[String: Any]])
  for index in spaces.indices { spaces[index].removeValue(forKey: "customRGB") }
  json["spaces"] = spaces
  let data = try JSONSerialization.data(withJSONObject: json)
  let restored = try JSONDecoder().decode(BrowserSession.self, from: data)
  #expect(restored.spaces.map(\.customRGB) == [nil, nil])
  #expect(restored.spaces.map(\.tint) == session.spaces.map(\.tint))
}

@Test func customSpaceColorsPersistAndPropagateAcrossWorkspaceWindows() throws {
  var workspace = try BrowserWorkspace(session: .fresh())
  let firstID = workspace.windows[0].id
  let secondID = try workspace.addWindow(from: firstID)
  let targetID = workspace.catalog.spaces[0].id
  let exactColor = SpaceRGBColor(red: 1, green: 127, blue: 254)

  var first = workspace.window(firstID)!.session
  let didUpdate = first.updateSpace(
    targetID, name: "Personal", tint: .lavender, customRGB: exactColor)
  #expect(didUpdate)
  try workspace.updateWindow(firstID, session: first)

  let projected = try #require(workspace.window(secondID)?.session.spaces.first)
  #expect(projected.id == targetID)
  #expect(projected.customRGB == exactColor)
  #expect(workspace.catalog.spaces.first?.customRGB == exactColor)
  let restored = try JSONDecoder().decode(
    BrowserWorkspace.self, from: JSONEncoder().encode(workspace))
  #expect(restored == workspace)

  #expect(restored.window(firstID)?.session.spaces.first?.customRGB == exactColor)
}

@Test func separateSpacesKeepIndependentCustomColors() throws {
  var session = BrowserSession.fresh()
  let first = session.spaces[0].id
  let second = session.spaces[1].id
  let red = SpaceRGBColor(red: 255, green: 0, blue: 0)
  let blue = SpaceRGBColor(red: 0, green: 0, blue: 255)
  let updatedFirst = session.updateSpace(first, name: "Personal", tint: .lavender, customRGB: red)
  let updatedSecond = session.updateSpace(second, name: "Work", tint: .ocean, customRGB: blue)
  #expect(updatedFirst)
  #expect(updatedSecond)
  #expect(session.spaces.first { $0.id == first }?.customRGB == red)
  #expect(session.spaces.first { $0.id == second }?.customRGB == blue)
}
