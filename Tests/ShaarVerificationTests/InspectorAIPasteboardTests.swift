// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import Testing

@testable import ArcusisBrowser
@testable import ShaarVerification

@Suite @MainActor struct InspectorAIPasteboardTests {
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
    try InspectorAICopyModel.write("Notes only", png: nil, to: board)
    #expect(throws: InspectorFailure.self) { _ = try InspectorAICopyProbe.pasteboardReceipt(board) }
  }
}
