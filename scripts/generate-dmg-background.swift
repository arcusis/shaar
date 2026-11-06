// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import Foundation

let size = NSSize(width: 660, height: 420)
let bitmap = NSBitmapImageRep(
  bitmapDataPlanes: nil, pixelsWide: 660, pixelsHigh: 420,
  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
  isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)

let bounds = NSRect(origin: .zero, size: size)
NSGradient(
  starting: NSColor(srgbRed: 0.01, green: 0.27, blue: 0.20, alpha: 1),
  ending: NSColor(srgbRed: 0.025, green: 0.10, blue: 0.075, alpha: 1))!
  .draw(in: bounds, angle: 160)

let glow = NSBezierPath(ovalIn: NSRect(x: 75, y: 83, width: 510, height: 510))
NSColor(srgbRed: 0.27, green: 0.74, blue: 0.32, alpha: 0.10).setFill()
glow.fill()

let title = "SHAAR"
let titleStyle: [NSAttributedString.Key: Any] = [
  .font: NSFont.systemFont(ofSize: 26, weight: .semibold),
  .foregroundColor: NSColor.white,
  .kern: 5,
]
(title as NSString).draw(at: NSPoint(x: 34, y: 350), withAttributes: titleStyle)

let subtitle = "Drag to Applications"
let subtitleStyle: [NSAttributedString.Key: Any] = [
  .font: NSFont.systemFont(ofSize: 16, weight: .medium),
  .foregroundColor: NSColor(srgbRed: 0.82, green: 0.94, blue: 0.85, alpha: 1),
]
let textWidth = (subtitle as NSString).size(withAttributes: subtitleStyle).width
(subtitle as NSString).draw(
  at: NSPoint(x: (size.width - textWidth) / 2, y: 47), withAttributes: subtitleStyle)

let arrow = NSBezierPath()
arrow.lineWidth = 3
arrow.move(to: NSPoint(x: 294, y: 236))
arrow.line(to: NSPoint(x: 370, y: 236))
arrow.move(to: NSPoint(x: 357, y: 247))
arrow.line(to: NSPoint(x: 370, y: 236))
arrow.line(to: NSPoint(x: 357, y: 225))
NSColor(srgbRed: 0.51, green: 0.94, blue: 0.71, alpha: 0.9).setStroke()
arrow.stroke()

NSGraphicsContext.restoreGraphicsState()
let output = URL(fileURLWithPath: CommandLine.arguments[1])
try bitmap.representation(using: .png, properties: [:])!.write(to: output, options: .atomic)
