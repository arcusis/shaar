// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import BrowserCore
import ChromiumBridge
import Foundation
import Testing

@testable import ArcusisBrowser

@Suite @MainActor
struct ExtensionManagementIconSymlinkTests {
  @Test func iconSymlinkCannotEscapeVersionDirectory() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }

    let extensionID = String(repeating: "a", count: 32)
    let folder = root.appending(path: "\(extensionID)/1.0_fixture")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

    let externalIcon = root.appending(path: "outside.png")
    let tiff = try #require(FaviconFixture.icon(.red).tiffRepresentation)
    let bitmap = try #require(NSBitmapImageRep(data: tiff))
    let png = try #require(bitmap.representation(using: .png, properties: [:]))
    try png.write(to: externalIcon)
    try FileManager.default.createSymbolicLink(
      at: folder.appending(path: "icon.png"), withDestinationURL: externalIcon)
    try Data(#"{"icons":{"16":"icon.png"}}"#.utf8)
      .write(to: folder.appending(path: "manifest.json"))

    #expect(ExtensionIconLoader.icon(for: extensionID, version: "1.0", in: root) == nil)
  }
}
