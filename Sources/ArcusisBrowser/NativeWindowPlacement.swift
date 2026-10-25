import AppKit
import BrowserCore

enum NativeWindowPlacement {
  static func frame(
    saved: WorkspaceWindowGeometry?, source: NSRect?, screens: [NSRect]
  ) -> NSRect {
    let usable = screens.filter { $0.width > 0 && $0.height > 0 && !$0.isInfinite && !$0.isNull }
    let fallback = usable.first ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)
    let proposed =
      saved.map { NSRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height) }
      ?? source?.offsetBy(dx: 22, dy: -22)
      ?? NSRect(x: fallback.midX - 600, y: fallback.midY - 390, width: 1200, height: 780)
    let screen =
      usable.max { intersectionArea(proposed, $0) < intersectionArea(proposed, $1) } ?? fallback
    let width = min(max(proposed.width, 760), max(screen.width, 760))
    let height = min(max(proposed.height, 520), max(screen.height, 520))
    return NSRect(
      x: min(max(proposed.minX, screen.minX), max(screen.minX, screen.maxX - width)),
      y: min(max(proposed.minY, screen.minY), max(screen.minY, screen.maxY - height)),
      width: width, height: height)
  }

  private static func intersectionArea(_ first: NSRect, _ second: NSRect) -> CGFloat {
    let intersection = first.intersection(second)
    return intersection.isNull ? 0 : intersection.width * intersection.height
  }
}
