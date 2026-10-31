// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import Foundation
import SwiftUI

/// Render hosted views at a fixed 1x scale so pixel dimensions stay stable across displays.
enum VisualCapture {
  static let scale: CGFloat = 1

  @MainActor
  static func render(
    _ host: NSView, to url: URL, options: Data.WritingOptions = .atomic
  ) throws -> NSBitmapImageRep {
    let bounds = host.bounds
    guard
      let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int((bounds.width * scale).rounded()),
        pixelsHigh: Int((bounds.height * scale).rounded()),
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
      )
    else {
      throw VisualCaptureError.bitmapCreation
    }
    bitmap.size = bounds.size
    host.cacheDisplay(in: bounds, to: bitmap)
    guard let data = bitmap.representation(using: .png, properties: [:]) else {
      throw VisualCaptureError.encoding
    }
    try data.write(to: url, options: options)
    return bitmap
  }
}

enum VisualCaptureError: Error {
  case bitmapCreation
  case encoding
}
