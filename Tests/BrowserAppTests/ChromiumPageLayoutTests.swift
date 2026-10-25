import AppKit
import XCTest

@testable import ArcusisBrowser

@MainActor
final class ChromiumPageLayoutTests: XCTestCase {
  func testAttachedPageTracksInitialBoundsAndSubsequentResizes() throws {
    let container = ChromiumPageContainerView(frame: NSRect(x: 0, y: 0, width: 720, height: 480))
    let page = LayoutColorView(frame: .zero, color: .systemBlue)

    XCTAssertTrue(container.attach(page))
    container.layoutSubtreeIfNeeded()
    XCTAssertEqual(page.frame, container.bounds)
    try capture(container, at: "/tmp/browser-page-layout-initial.png")

    container.setFrameSize(NSSize(width: 1024, height: 640))
    container.layoutSubtreeIfNeeded()
    XCTAssertEqual(page.frame, container.bounds)
    try capture(container, at: "/tmp/browser-page-layout-resized.png")
  }

  func testUpdatingSamePageKeepsSingleAttachment() {
    let container = ChromiumPageContainerView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
    let page = NSView(frame: .zero)

    XCTAssertTrue(container.attach(page))
    XCTAssertFalse(container.attach(page))
    XCTAssertTrue(page.superview === container)
    XCTAssertEqual(container.subviews.count, 1)
  }

  func testDismantlingPreviousContainerKeepsTransferredPageAttached() {
    let first = ChromiumPageContainerView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
    let second = ChromiumPageContainerView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
    let page = NSView(frame: .zero)

    XCTAssertTrue(first.attach(page))
    XCTAssertTrue(second.attach(page))
    XCTAssertTrue(page.superview === second)
    XCTAssertEqual(first.subviews.count, 0)

    first.attach(nil)

    XCTAssertTrue(page.superview === second)
    XCTAssertTrue(second.pageView === page)
  }

  func testStaleContainerLayoutDoesNotResizeTransferredPage() {
    let first = ChromiumPageContainerView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
    let second = ChromiumPageContainerView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
    let page = NSView(frame: .zero)

    XCTAssertTrue(first.attach(page))
    XCTAssertTrue(second.attach(page))
    XCTAssertTrue(page.superview === second)
    XCTAssertEqual(page.frame, second.bounds)

    first.setFrameSize(NSSize(width: 500, height: 350))
    first.needsLayout = true
    first.layoutSubtreeIfNeeded()

    XCTAssertTrue(page.superview === second)
    XCTAssertEqual(page.frame, second.bounds)

    first.attach(nil)

    XCTAssertTrue(page.superview === second)
    XCTAssertEqual(page.frame, second.bounds)
  }

  func testSamePageReattachesAfterExternalRemovalOrReparenting() {
    let first = ChromiumPageContainerView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
    let second = ChromiumPageContainerView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
    let page = NSView(frame: .zero)

    XCTAssertTrue(first.attach(page))
    page.removeFromSuperview()
    XCTAssertTrue(first.attach(page))
    XCTAssertTrue(page.superview === first)

    XCTAssertTrue(second.attach(page))
    XCTAssertTrue(page.superview === second)
    XCTAssertTrue(first.attach(page))
    XCTAssertTrue(page.superview === first)
    XCTAssertEqual(first.subviews.count, 1)
    XCTAssertEqual(second.subviews.count, 0)
  }

  private func capture(_ view: NSView, at path: String) throws {
    let image = try XCTUnwrap(
      NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: max(1, Int(view.bounds.width)),
        pixelsHigh: max(1, Int(view.bounds.height)),
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0))
    let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: image))
    view.displayIgnoringOpacity(view.bounds, in: context)
    let data = try XCTUnwrap(image.representation(using: .png, properties: [:]))
    try data.write(to: URL(fileURLWithPath: path), options: .atomic)
  }
}

@MainActor
private final class LayoutColorView: NSView {
  private let color: NSColor

  init(frame: NSRect, color: NSColor) {
    self.color = color
    super.init(frame: frame)
  }

  required init?(coder: NSCoder) { nil }

  override func draw(_ dirtyRect: NSRect) {
    color.setFill()
    dirtyRect.fill()
  }
}
