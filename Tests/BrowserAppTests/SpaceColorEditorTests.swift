import AppKit
import BrowserCore
import SwiftUI
import Testing
import XCTest

@testable import ArcusisBrowser

@MainActor
@Test func appearanceDraftRejectsInvalidHexAndPickerComponents() {
  var draft = SpaceAppearanceDraft(
    tint: .lavender, customRGB: SpaceRGBColor(red: 18, green: 52, blue: 86))
  let accepted = draft.setHexDraft("#123ABC")
  #expect(accepted)
  #expect(draft.canSubmit)

  for invalidHex in ["", "#123", "#12345G", "#1234567"] {
    let rejected = draft.setHexDraft(invalidHex)
    #expect(!rejected)
    #expect(!draft.canSubmit)
    #expect(draft.color == SpaceRGBColor(red: 0x12, green: 0x3A, blue: 0xBC))
  }

  let nonFinite = draft.setCustomComponents(red: .nan, green: 0, blue: 1)
  #expect(!nonFinite)
  #expect(!draft.canSubmit)
  #expect(draft.color == SpaceRGBColor(red: 0x12, green: 0x3A, blue: 0xBC))
  #expect(SpaceEditorSavePolicy.isDisabled(name: "Design", appearance: draft))

  draft.selectPreset(.forest)
  #expect(draft.canSubmit)
  #expect(draft.customRGB == nil)
  #expect(!SpaceEditorSavePolicy.isDisabled(name: "Design", appearance: draft))
  #expect(SpaceEditorSavePolicy.isDisabled(name: "  ", appearance: draft))

  draft.rejectColorInput()
  #expect(!draft.canSubmit)
  draft.setCustom(SpaceRGBColor(red: 2, green: 3, blue: 4))
  #expect(draft.canSubmit)
}

@MainActor
@Test func pickerClampsFiniteComponentsBeforeByteConversion() {
  var draft = SpaceAppearanceDraft(tint: .lavender, customRGB: nil)
  let accepted = draft.setCustomComponents(red: -0.5, green: 1.5, blue: 0.5)
  #expect(accepted)
  #expect(draft.color == SpaceRGBColor(red: 0, green: 255, blue: 128))
  #expect(draft.canSubmit)

  let rejectedInfinity = draft.setCustomComponents(red: 0, green: .infinity, blue: 1)
  #expect(!rejectedInfinity)
  #expect(!draft.canSubmit)
}

@MainActor
final class SpaceColorEditorLayoutTests: XCTestCase {
  func testActualSpaceEditorRendersHiddenWindowCreationAndEditStates() throws {
    let output = URL(filePath: "/tmp/browser-rgb-space-color-editor")
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    let initial = BrowserSession.fresh()
    let store = BrowserStore(sessionFile: nil, session: initial)
    let initialSession = store.session
    let editID = initial.selectedSpaceID
    let editedSession = store.session
    let custom = SpaceRGBColor(red: 0x12, green: 0x84, blue: 0xD6)

    for (schemeName, scheme, sizeClass, width) in [
      ("normal", ColorScheme.light, UserInterfaceSizeClass.regular, CGFloat(380)),
      ("dark", ColorScheme.dark, UserInterfaceSizeClass.regular, CGFloat(380)),
      ("compact", ColorScheme.light, UserInterfaceSizeClass.compact, CGFloat(380)),
    ] {
      for (stateName, route) in [("create", SpaceEditorRoute.create), ("edit", .edit(editID))] {
        let view = SpaceEditor(store: store, route: route)
          .environment(\.colorScheme, scheme)
          .environment(\.horizontalSizeClass, sizeClass)
        let name = "\(schemeName)-\(stateName)"
        try capture(
          view, size: NSSize(width: width + 24, height: 600),
          to: output.appending(path: "\(name).png"))
        // Closing hidden host without Save must leave committed session untouched.
        XCTAssertEqual(store.session, initialSession)
      }
    }

    var changed = editedSession
    let changedColor = changed.updateSpace(
      editID, name: "Personal", tint: .lavender, customRGB: custom)
    XCTAssertTrue(changedColor)
    let editStore = BrowserStore(sessionFile: nil, session: changed)
    let editView = SpaceEditor(store: editStore, route: .edit(editID))
      .environment(\.colorScheme, .light)
      .environment(\.horizontalSizeClass, .regular)
    try capture(
      editView, size: NSSize(width: 404, height: 600), to: output.appending(path: "custom-edit.png")
    )
    XCTAssertEqual(editStore.session.spaces.first { $0.id == editID }?.customRGB, custom)
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: output.appending(path: "normal-create.png").path))
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: output.appending(path: "dark-edit.png").path))
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: output.appending(path: "compact-create.png").path))
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: output.appending(path: "custom-edit.png").path))

    var longNamed = editedSession
    XCTAssertTrue(
      longNamed.updateSpace(
        editID, name: "Research and product design across several teams", tint: .lavender,
        customRGB: custom))
    let longNameStore = BrowserStore(sessionFile: nil, session: longNamed)
    let longNameView = SpaceEditor(store: longNameStore, route: .edit(editID))
      .environment(\.colorScheme, .light)
      .environment(\.horizontalSizeClass, .regular)
    try capture(
      longNameView, size: NSSize(width: 404, height: 600),
      to: output.appending(path: "long-name-edit.png"))
    XCTAssertEqual(longNameStore.session, longNamed)
  }

}
@MainActor
private func capture<V: View>(_ view: V, size: NSSize, to url: URL) throws {
  let window = NSWindow(
    contentRect: NSRect(origin: .zero, size: size), styleMask: [], backing: .buffered,
    defer: false)
  window.isReleasedWhenClosed = false
  defer { window.close() }
  let host = NSHostingView(rootView: view)
  window.contentView = host
  host.frame = NSRect(origin: .zero, size: size)
  host.layoutSubtreeIfNeeded()
  window.displayIfNeeded()
  RunLoop.current.run(until: Date().addingTimeInterval(0.05))
  host.layoutSubtreeIfNeeded()

  let bounds = host.bounds
  XCTAssertGreaterThan(bounds.width, 0)
  XCTAssertGreaterThan(bounds.height, 0)
  XCTAssertLessThanOrEqual(host.fittingSize.width, size.width)
  XCTAssertLessThanOrEqual(host.fittingSize.height, size.height)
  let scale = 2.0
  let width = Int(bounds.width * scale)
  let height = Int(bounds.height * scale)
  guard
    let bitmap = NSBitmapImageRep(
      bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
      samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
      bytesPerRow: 0, bitsPerPixel: 0)
  else { throw ScreenshotError.bitmapCreation }
  bitmap.size = bounds.size
  host.cacheDisplay(in: bounds, to: bitmap)
  guard let png = bitmap.representation(using: .png, properties: [:]) else {
    throw ScreenshotError.encoding
  }
  try png.write(to: url)
}

private enum ScreenshotError: Error {
  case bitmapCreation
  case encoding
}

@MainActor
@Test func spaceSymbolPersistsThroughCreateAndUpdate() {
  let store = BrowserStore(sessionFile: nil, session: .fresh())
  #expect(store.createSpace(name: "Design", sharingProfile: nil, tint: .rose, symbol: "star.fill"))
  let id = store.session.selectedSpaceID
  #expect(store.session.selectedSpace.symbol == "star.fill")
  #expect(store.updateSpace(id, name: "Design", tint: .ocean, symbol: "globe"))
  #expect(store.session.selectedSpace.symbol == "globe")
  #expect(store.updateSpace(id, name: "Design", tint: .forest))
  #expect(store.session.selectedSpace.symbol == "globe")
}
