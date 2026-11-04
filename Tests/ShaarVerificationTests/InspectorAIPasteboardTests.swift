// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import Testing

@testable import ArcusisBrowser
@testable import ShaarVerification

@Suite @MainActor struct InspectorAIPasteboardTests {
  @Test func detailedDiagnosticsReadinessRequiresEachCollectedSignal() {
    let console = ["AI fixture console error"]
    let statuses = [503]
    let signals = ["Inspector AI fixture"]
    #expect(
      !InspectorAICopyProbe.diagnosticsReady(
        consoleMessages: [], requestStatuses: statuses, signalNames: signals))
    #expect(
      !InspectorAICopyProbe.diagnosticsReady(
        consoleMessages: console, requestStatuses: [], signalNames: signals))
    #expect(
      !InspectorAICopyProbe.diagnosticsReady(
        consoleMessages: console, requestStatuses: statuses, signalNames: []))
    #expect(
      InspectorAICopyProbe.diagnosticsReady(
        consoleMessages: console, requestStatuses: statuses, signalNames: signals))
  }

  @Test func detailedCopyWaitsForCollectedContext() {
    var details = InspectorAIFormatter.Details()
    details.computed = [.init(name: "color", value: "red")]
    details.rules = [
      .init(
        selector: "button", source: "fixture", declarations: [.init(name: "color", value: "red")])
    ]
    details.consoleErrors = ["AI fixture console error"]
    details.networkErrors = ["GET /inspector-ai-failure — status 503"]
    details.technologies = ["Inspector AI fixture"]
    #expect(InspectorAICopyProbe.detailedContextReady(details))
    var missing = details
    missing.computed = []
    #expect(!InspectorAICopyProbe.detailedContextReady(missing))
    missing = details
    missing.rules = []
    #expect(!InspectorAICopyProbe.detailedContextReady(missing))
    missing = details
    missing.consoleErrors = []
    #expect(!InspectorAICopyProbe.detailedContextReady(missing))
    missing = details
    missing.networkErrors = []
    #expect(!InspectorAICopyProbe.detailedContextReady(missing))
    missing = details
    missing.technologies = []
    #expect(!InspectorAICopyProbe.detailedContextReady(missing))
  }

  @Test func receiptRequiresActualPNGAfterMatchingMarkdownRepresentations() throws {
    let board = NSPasteboard.withUniqueName()
    defer { board.releaseGlobally() }
    #expect(throws: InspectorFailure.self) { _ = try InspectorAICopyProbe.pasteboardReceipt(board) }
    let image = try #require(
      NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: 20, pixelsHigh: 12, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
      ))
    var gray: [UInt] = [128, 128, 128, 255]
    image.setPixel(&gray, atX: 0, y: 0)
    var white: [UInt] = [255, 255, 255, 255]
    image.setPixel(&white, atX: 1, y: 0)
    let png = try #require(image.representation(using: .png, properties: [:]))
    try InspectorAICopyModel.write(
      "Attached browser context from https://example.com", png: png, to: board)
    let decoded = try #require(NSBitmapImageRep(data: png))
    #expect(InspectorAICopyProbe.isMaskedPixel(decoded, x: 0, y: 0))
    #expect(!InspectorAICopyProbe.isMaskedPixel(decoded, x: 1, y: 0))
    #expect(!InspectorAICopyProbe.isMaskedPixel(decoded, x: -1, y: 0))
    let receipt = try InspectorAICopyProbe.pasteboardReceipt(board)
    #expect(receipt["items"] as? Int == 1 && receipt["png"] as? Bool == true)
    #expect(receipt["width"] as? Int == 20 && receipt["height"] as? Int == 12)
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let cache = root.appending(path: "cache")
    try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = cache.appending(path: "123-button.png")
    try png.write(to: file)
    try InspectorAICopyModel.write("Screenshot: " + file.path, png: png, to: board)
    #expect(
      try InspectorAICopyProbe.screenshotFile(board, within: cache)
        == file.resolvingSymlinksInPath())
    try Data([1, 2, 3]).write(to: file)
    #expect(throws: InspectorFailure.self) {
      _ = try InspectorAICopyProbe.screenshotFile(board, within: cache)
    }
    try FileManager.default.removeItem(at: file)
    #expect(throws: InspectorFailure.self) {
      _ = try InspectorAICopyProbe.screenshotFile(board, within: cache)
    }
    let outside = root.appending(path: "outside.png")
    try png.write(to: outside)
    let link = cache.appending(path: "link.png")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
    try InspectorAICopyModel.write("Screenshot: " + link.path, png: png, to: board)
    #expect(throws: InspectorFailure.self) {
      _ = try InspectorAICopyProbe.screenshotFile(board, within: cache)
    }
    try InspectorAICopyModel.write("Notes only", png: nil, to: board)
    #expect(throws: InspectorFailure.self) { _ = try InspectorAICopyProbe.pasteboardReceipt(board) }
    #expect(throws: InspectorFailure.self) {
      _ = try InspectorAICopyProbe.screenshotFile(board, within: cache)
    }
  }
}
