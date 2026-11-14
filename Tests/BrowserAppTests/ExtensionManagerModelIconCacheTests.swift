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
struct ExtensionManagerModelIconCacheTests {
  @Test func versionChangesReloadIconsAndRemovedExtensionsArePruned() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let extensionID = String(repeating: "a", count: 32)
    let versionFolder = root.appending(path: "\(extensionID)/2.0_0")
    try FileManager.default.createDirectory(at: versionFolder, withIntermediateDirectories: true)
    let tiff = try #require(FaviconFixture.icon(.blue).tiffRepresentation)
    let bitmap = try #require(NSBitmapImageRep(data: tiff))
    let png = try #require(bitmap.representation(using: .png, properties: [:]))
    try png.write(to: versionFolder.appending(path: "icon.png"))
    try Data(#"{"icons":{"16":"icon.png"}}"#.utf8)
      .write(to: versionFolder.appending(path: "manifest.json"))

    let item = try JSONDecoder().decode(
      ManagedExtension.self,
      from: Data(
        #"{"id":"\#(extensionID)","name":"Example","version":"2.0","description":"","enabled":true,"mayDisable":true,"permissions":[],"hostPermissions":[]}"#.utf8))
    let removedID = String(repeating: "b", count: 32)
    let result = ExtensionManagerModel.updatedIconCache(
      extensions: [item],
      icons: [extensionID: FaviconFixture.icon(.red), removedID: FaviconFixture.icon(.red)],
      versions: [extensionID: "1.0", removedID: "1.0"], directory: root)

    #expect(result.versions == [extensionID: "2.0"])
    #expect(result.icons[removedID] == nil)
    #expect(FaviconFixture.matches(try #require(result.icons[extensionID]), .blue))
  }
}
