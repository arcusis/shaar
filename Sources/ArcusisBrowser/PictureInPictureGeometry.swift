// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import CoreGraphics

/// Frame math for moving, resizing and tucking the picture-in-picture window. Frames use
/// AppKit screen coordinates, origin at the bottom left.
enum PictureInPictureGeometry {
  /// Width of the strip that stays on screen while the window is tucked away.
  static let tuckedWidth: CGFloat = 28
  /// Pointer distance from the window's border that resizes instead of moving.
  static let resizeBorder: CGFloat = 6

  /// Window edges a resize drag moves.
  struct Edges: OptionSet, Hashable {
    let rawValue: Int
    static let left = Edges(rawValue: 1 << 0)
    static let right = Edges(rawValue: 1 << 1)
    static let bottom = Edges(rawValue: 1 << 2)
    static let top = Edges(rawValue: 1 << 3)
  }

  /// The edges under a point in window coordinates; empty in the window's interior.
  static func edges(at point: CGPoint, in size: CGSize) -> Edges {
    var edges: Edges = []
    if point.x <= resizeBorder { edges.insert(.left) }
    if point.x >= size.width - resizeBorder { edges.insert(.right) }
    if point.y <= resizeBorder { edges.insert(.bottom) }
    if point.y >= size.height - resizeBorder { edges.insert(.top) }
    return edges
  }

  /// Resizes `frame` by dragging `edges` by `delta`, keeping its aspect ratio and the
  /// opposite edges in place. The result stays within the window's minimum and maximum size.
  static func resized(
    _ frame: CGRect, edges: Edges, by delta: CGSize, minimum: CGSize, maximum: CGSize
  ) -> CGRect {
    guard frame.width > 0, frame.height > 0, !edges.isEmpty else { return frame }
    let aspect = frame.width / frame.height
    let lower = max(minimum.width, minimum.height * aspect)
    let upper = max(lower, min(maximum.width, maximum.height * aspect))
    let width = min(
      max(proposedWidth(frame, edges: edges, by: delta, aspect: aspect), lower), upper)
    let height = width / aspect
    let x = edges.contains(.left) ? frame.maxX - width : frame.minX
    let y = edges.contains(.bottom) ? frame.maxY - height : frame.minY
    return CGRect(x: x, y: y, width: width, height: height)
  }

  /// The frame that leaves only a strip of the window at the nearer side of `screen`.
  static func tucked(_ frame: CGRect, in screen: CGRect) -> CGRect {
    var tucked = frame
    if tucksLeft(frame, in: screen) {
      tucked.origin.x = screen.minX - frame.width + tuckedWidth
    } else {
      tucked.origin.x = screen.maxX - tuckedWidth
    }
    return tucked
  }

  /// Whether a window at `frame` tucks away at the left side of `screen`.
  static func tucksLeft(_ frame: CGRect, in screen: CGRect) -> Bool {
    frame.midX < screen.midX
  }

  /// A corner drag follows whichever direction grows the window more.
  private static func proposedWidth(
    _ frame: CGRect, edges: Edges, by delta: CGSize, aspect: CGFloat
  ) -> CGFloat {
    let horizontal = horizontalGrowth(edges, delta.width)
    let vertical = verticalGrowth(edges, delta.height) * aspect
    let sideways = !edges.isDisjoint(with: [.left, .right])
    let upright = !edges.isDisjoint(with: [.top, .bottom])
    if sideways && upright { return frame.width + max(horizontal, vertical) }
    return frame.width + (sideways ? horizontal : vertical)
  }

  private static func horizontalGrowth(_ edges: Edges, _ dx: CGFloat) -> CGFloat {
    if edges.contains(.right) { return dx }
    if edges.contains(.left) { return -dx }
    return 0
  }

  private static func verticalGrowth(_ edges: Edges, _ dy: CGFloat) -> CGFloat {
    if edges.contains(.top) { return dy }
    if edges.contains(.bottom) { return -dy }
    return 0
  }
}
