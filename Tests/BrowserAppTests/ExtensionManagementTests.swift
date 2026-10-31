// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import Foundation
import Testing

@testable import ArcusisBrowser

struct ExtensionManagementTests {
  private let validID = String(repeating: "b", count: 32)

  @Test func operationsMapToBridgeOperationsWithTheirArguments() {
    let enable = ExtensionManagementOperation.setEnabled(id: validID, enabled: true)
    #expect(enable.bridgeOperation == .setEnabled)
    #expect(enable.extensionID == validID)
    #expect(enable.enabled)
    #expect(!ExtensionManagementOperation.setEnabled(id: validID, enabled: false).enabled)
    #expect(ExtensionManagementOperation.uninstall(id: validID).bridgeOperation == .uninstall)
    #expect(ExtensionManagementOperation.details(id: validID).bridgeOperation == .details)
    #expect(ExtensionManagementOperation.list.bridgeOperation == .list)
    #expect(ExtensionManagementOperation.list.extensionID == nil)
    #expect(!ExtensionManagementOperation.uninstall(id: validID).enabled)
  }

  @Test func profileIDsMustBeCanonicalUUIDs() {
    #expect(ExtensionManagementOperation.isValidProfileID(UUID().uuidString))
    #expect(!ExtensionManagementOperation.isValidProfileID("profile';alert(1)"))
    #expect(!ExtensionManagementOperation.isValidProfileID(""))
  }

  @Test func resultsSeparateErrorsFromValues() throws {
    guard case .failure(let message)? = ExtensionManagementResult(json: #"{"error":"denied"}"#)
    else {
      Issue.record("expected failure")
      return
    }
    #expect(message == "denied")
    guard case .value(let data)? = ExtensionManagementResult(json: "[]") else {
      Issue.record("expected value")
      return
    }
    #expect(try JSONDecoder().decode([ManagedExtension].self, from: data).isEmpty)
    #expect(ExtensionManagementResult(json: nil) == nil)
  }

  @Test @MainActor func iconLoaderUsesTheLargestManifestIconInsideTheExtension() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let folder = root.appending(path: "\(validID)/2.1_0")
    try FileManager.default.createDirectory(
      at: folder.appending(path: "icons"), withIntermediateDirectories: true)
    try png(size: 128).write(to: folder.appending(path: "icons/large.png"))
    try png(size: 16).write(to: folder.appending(path: "small.png"))
    try Data(#"{"icons":{"16":"small.png","128":"icons/large.png"}}"#.utf8)
      .write(to: folder.appending(path: "manifest.json"))

    let icon = ExtensionIconLoader.icon(for: validID, version: "2.1", in: root)
    #expect(icon?.representations.first?.pixelsWide == 128)
    #expect(ExtensionIconLoader.icon(for: validID, version: "9.9", in: root) == nil)

    try Data(#"{"icons":{"128":"../../escape.png"}}"#.utf8)
      .write(to: folder.appending(path: "manifest.json"))
    try png(size: 32).write(to: root.appending(path: "escape.png"))
    #expect(ExtensionIconLoader.icon(for: validID, version: "2.1", in: root) == nil)
  }

  @Test @MainActor func pinnedExtensionsPersistPerProfile() throws {
    let file = FileManager.default.temporaryDirectory.appending(path: "\(UUID()).json")
    defer { try? FileManager.default.removeItem(at: file) }
    let work = UUID()
    let personal = UUID()
    let store = BrowserPreferencesStore(fileURL: file)
    store.setExtension(validID, pinned: true, for: work)
    store.setExtension(String(repeating: "c", count: 32), pinned: true, for: work)
    store.setExtension(validID, pinned: false, for: work)

    let reloaded = BrowserPreferencesStore(fileURL: file)
    #expect(reloaded.pinnedExtensionIDs(for: work) == [String(repeating: "c", count: 32)])
    #expect(reloaded.pinnedExtensionIDs(for: personal).isEmpty)
  }

  private func png(size: Int) throws -> Data {
    let bitmap = try #require(
      NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0))
    return try #require(bitmap.representation(using: .png, properties: [:]))
  }
}

extension ExtensionManagementTests {
  @Test @MainActor func iconLoaderFallsBackToTheToolbarActionIcon() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let folder = root.appending(path: "\(validID)/1.0_0")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try png(size: 48).write(to: folder.appending(path: "action.png"))

    try Data(#"{"action":{"default_icon":"action.png"}}"#.utf8)
      .write(to: folder.appending(path: "manifest.json"))
    #expect(ExtensionIconLoader.icon(for: validID, version: "1.0", in: root) != nil)

    try Data(#"{"browser_action":{"default_icon":{"19":"missing.png","48":"action.png"}}}"#.utf8)
      .write(to: folder.appending(path: "manifest.json"))
    #expect(
      ExtensionIconLoader.icon(for: validID, version: "1.0", in: root)?.representations.first?
        .pixelsWide == 48)

    try Data(#"{"name":"No icons"}"#.utf8).write(to: folder.appending(path: "manifest.json"))
    #expect(ExtensionIconLoader.icon(for: validID, version: "1.0", in: root) == nil)
    #expect(ExtensionIconLoader.icon(for: "../\(validID)", version: "1.0", in: root) == nil)
  }

  @Test func consentListsSiteAccessAndFlagsIncompletePermissions() {
    #expect(
      ExtensionConsentPermissions.displayValues(
        permissions: ["storage"], hostPermissions: ["https://example.com/*"], complete: true)
        == ["storage", "Site access: https://example.com/*"])
    #expect(
      ExtensionConsentPermissions.displayValues(
        permissions: ["tabs"], hostPermissions: nil, complete: true)
        == ["tabs", ExtensionConsentPermissions.unknownAccess])
    #expect(
      ExtensionConsentPermissions.displayValues(
        permissions: [], hostPermissions: [], complete: false)
        == [ExtensionConsentPermissions.unknownAccess])
  }

  @Test @MainActor func previewManagerListsEnabledPinsAndKeepsThemReadOnly() {
    let profile = UUID()
    let enabled = managed(id: String(repeating: "c", count: 32), enabled: true)
    let disabled = managed(id: String(repeating: "d", count: 32), enabled: false)
    let model = ExtensionManagerModel(
      profileID: profile, extensions: [enabled, disabled],
      pinnedIDs: [disabled.id, enabled.id, String(repeating: "e", count: 32)])
    #expect(model.pinnedExtensions == [enabled])
    model.setPinned(enabled.id, pinned: false)
    #expect(model.pinnedIDs.contains(enabled.id))
  }

  private func managed(id: String, enabled: Bool) -> ManagedExtension {
    ManagedExtension(
      id: id, name: "Extension \(id.prefix(1))", version: "1.0", description: "",
      enabled: enabled, mayDisable: true, permissions: [], hostPermissions: [])
  }
}
