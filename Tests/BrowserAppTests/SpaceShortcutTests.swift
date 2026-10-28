import Testing

@testable import ArcusisBrowser

@Test func spaceShortcutMapsOnlyFirstNineIndices() {
  #expect(
    (-1...10).map(SpaceShortcut.key(forIndex:)) == [
      nil, "1", "2", "3", "4", "5", "6", "7", "8", "9", nil, nil,
    ])
}
