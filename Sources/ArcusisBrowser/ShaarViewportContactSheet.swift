// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import Foundation

enum ShaarViewportContactSheet {
  static let gap: CGFloat = 12
  static let pad: CGFloat = 16
  static let caption: CGFloat = 22
  static let maximumHeight: CGFloat = 720
  static let maximumWidth: CGFloat = 2400

  static func displayScale(imageSizes: [CGSize]) -> CGFloat {
    guard let tallest = imageSizes.map(\.height).max(), tallest > 0 else { return 1 }
    let widthSum = imageSizes.reduce(CGFloat(0)) { partial, size in partial + size.width }
    let gaps = gap * CGFloat(max(imageSizes.count - 1, 0))
    let rawWidth = pad * 2 + widthSum + gaps
    let heightScale = min(1, maximumHeight / tallest)
    let widthScale = min(1, maximumWidth / max(rawWidth, 1))
    return min(heightScale, widthScale)
  }

  static func canvasSize(imageSizes: [CGSize]) -> CGSize {
    let scale = displayScale(imageSizes: imageSizes)
    let scaled = imageSizes.map { size in
      CGSize(
        width: max(1, (size.width * scale).rounded()),
        height: max(1, (size.height * scale).rounded()))
    }
    let width =
      pad * 2 + scaled.reduce(CGFloat(0)) { partial, size in partial + size.width }
      + gap * CGFloat(max(scaled.count - 1, 0))
    let height = pad * 2 + caption + (scaled.map(\.height).max() ?? 0)
    return CGSize(width: width.rounded(.up), height: height.rounded(.up))
  }

  static func png(frames: [ShaarViewportFrame]) -> Data? {
    let loaded = frames.compactMap { frame -> (ShaarViewportFrame, NSImage)? in
      guard let image = NSImage(data: frame.pngData), image.size.width > 0,
        image.size.height > 0
      else { return nil }
      return (frame, image)
    }
    guard !loaded.isEmpty else { return nil }
    let sizes = loaded.map { _, image in image.size }
    let canvas = canvasSize(imageSizes: sizes)
    let scale = displayScale(imageSizes: sizes)
    guard canvas.width >= 1, canvas.height >= 1,
      let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(canvas.width), pixelsHigh: Int(canvas.height),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
    else { return nil }
    rep.size = canvas
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
    NSGraphicsContext.current = context
    NSColor.white.setFill()
    NSRect(origin: .zero, size: canvas).fill()
    var x = pad
    let tallest =
      loaded.map { _, image in scaledHeight(image.size.height, scale: scale) }.max() ?? 1
    for (frame, image) in loaded {
      let width = scaledWidth(image.size.width, scale: scale)
      let height = scaledHeight(image.size.height, scale: scale)
      let imageRect = NSRect(
        x: x, y: pad + caption + (tallest - height), width: width, height: height)
      image.draw(in: imageRect)
      let label = label(for: frame)
      let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 11),
        .foregroundColor: NSColor.black,
      ]
      NSString(string: label).draw(at: NSPoint(x: x, y: pad), withAttributes: attributes)
      x += width + gap
    }
    return rep.representation(using: .png, properties: [:])
  }

  private static func scaledWidth(_ value: CGFloat, scale: CGFloat) -> CGFloat {
    max(1, (value * scale).rounded())
  }

  private static func scaledHeight(_ value: CGFloat, scale: CGFloat) -> CGFloat {
    max(1, (value * scale).rounded())
  }

  private static func label(for frame: ShaarViewportFrame) -> String {
    let name = ShellL10n.string(frame.preset.title)
    let scheme = ShellL10n.string(frame.colorScheme.title)
    return "\(name) \(frame.contentWidth)x\(frame.contentHeight) \(scheme)"
  }
}
