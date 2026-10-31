import AppKit
import Foundation
import Testing

@testable import ArcusisBrowser

struct ExtensionManagementTests {
  private let validID = String(repeating: "b", count: 32)

  @Test func scriptsOnlyAcceptValidExtensionIDs() {
    #expect(ExtensionManagementScript.setEnabled(validID, false)?.contains(validID) == true)
    #expect(
      ExtensionManagementScript.uninstall(validID)?.contains("showConfirmDialog: false") == true)
    for invalid in ["", "abc", String(repeating: "z", count: 32), "'); alert(1); ('"] {
      #expect(ExtensionManagementScript.setEnabled(invalid, true) == nil)
      #expect(ExtensionManagementScript.uninstall(invalid) == nil)
    }
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
