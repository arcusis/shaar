import AppKit
import XCTest

@testable import ArcusisBrowser

@MainActor
final class WindowDragRegionTests: XCTestCase {
  func testTitlebarDragFrameStaysInSafeAreaAndPastTrafficLights() throws {
    let bounds = NSRect(x: 0, y: 0, width: 1200, height: 800)
    let layout = NSRect(x: 0, y: 0, width: 1200, height: 772)
    let trafficLights = NSRect(x: 8, y: 778, width: 72, height: 16)

    let frame = try XCTUnwrap(
      WindowDragRegion.titlebarDragFrame(
        contentBounds: bounds, contentLayoutRect: layout, trafficLightsFrame: trafficLights))

    XCTAssertEqual(frame, NSRect(x: 88, y: 772, width: 1112, height: 28))
    XCTAssertFalse(frame.intersects(trafficLights))
    try capture(bounds: bounds, trafficLights: trafficLights, dragFrame: frame)
  }

  func testNoTitlebarStripMeansNoDragView() {
    let bounds = NSRect(x: 0, y: 0, width: 900, height: 600)
    XCTAssertNil(
      WindowDragRegion.titlebarDragFrame(
        contentBounds: bounds, contentLayoutRect: bounds, trafficLightsFrame: nil))
  }

  func testMissingTrafficLightGeometryFailsClosed() {
    let bounds = NSRect(x: 0, y: 0, width: 900, height: 600)
    let layout = NSRect(x: 0, y: 0, width: 900, height: 572)
    XCTAssertNil(
      WindowDragRegion.titlebarDragFrame(
        contentBounds: bounds, contentLayoutRect: layout, trafficLightsFrame: nil))
  }

  func testFlippedContentViewPlacesStripAtTopEdge() throws {
    let bounds = NSRect(x: 0, y: 0, width: 900, height: 600)
    let layout = NSRect(x: 0, y: 28, width: 900, height: 572)
    let trafficLights = NSRect(x: 8, y: 4, width: 72, height: 16)
    let frame = try XCTUnwrap(
      WindowDragRegion.titlebarDragFrame(
        contentBounds: bounds, contentLayoutRect: layout, trafficLightsFrame: trafficLights,
        isFlipped: true))
    XCTAssertEqual(frame, NSRect(x: 88, y: 0, width: 812, height: 28))
  }

  private func capture(bounds: NSRect, trafficLights: NSRect, dragFrame: NSRect) throws {
    let view = DragGeometryCaptureView(
      frame: bounds, trafficLights: trafficLights, dragFrame: dragFrame)
    let image = try XCTUnwrap(
      NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(bounds.width),
        pixelsHigh: Int(bounds.height),
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0))
    let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: image))
    view.displayIgnoringOpacity(bounds, in: context)
    let data = try XCTUnwrap(image.representation(using: .png, properties: [:]))
    try data.write(
      to: URL(fileURLWithPath: "/tmp/browser-titlebar-drag-region.png"), options: .atomic)
  }
}

@MainActor
private final class DragGeometryCaptureView: NSView {
  private let trafficLights: NSRect
  private let dragFrame: NSRect

  init(frame: NSRect, trafficLights: NSRect, dragFrame: NSRect) {
    self.trafficLights = trafficLights
    self.dragFrame = dragFrame
    super.init(frame: frame)
  }

  required init?(coder: NSCoder) { nil }

  override func draw(_ dirtyRect: NSRect) {
    NSColor.windowBackgroundColor.setFill()
    dirtyRect.fill()
    NSColor.systemRed.setFill()
    NSBezierPath(rect: trafficLights).fill()
    NSColor.systemGreen.setFill()
    NSBezierPath(rect: dragFrame).fill()
  }
}
