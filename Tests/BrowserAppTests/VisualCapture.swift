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

  /// Lays the view out in a window that is never ordered on screen, then renders it.
  @MainActor
  @discardableResult
  static func renderOffscreen<V: View>(
    _ view: V, size: NSSize, appearance: NSAppearance.Name, to url: URL
  ) throws -> NSBitmapImageRep {
    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: size), styleMask: [], backing: .buffered,
      defer: false)
    window.isReleasedWhenClosed = false
    window.appearance = NSAppearance(named: appearance)
    defer { window.close() }
    let host = NSHostingView(rootView: view)
    window.contentView = host
    host.frame = NSRect(origin: .zero, size: size)
    host.layoutSubtreeIfNeeded()
    window.displayIfNeeded()
    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    host.layoutSubtreeIfNeeded()
    return try render(host, to: url)
  }
}

enum VisualCaptureError: Error {
  case bitmapCreation
  case encoding
}
