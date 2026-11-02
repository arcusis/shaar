// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import XCTest

@testable import ArcusisBrowser

/// Geometry, presentation and commands of Shaar's picture-in-picture controls. Windows stay
/// transparent and are never ordered on screen by the tests.
@MainActor
final class PictureInPictureControlsTests: XCTestCase {
  private typealias Geometry = PictureInPictureGeometry
  private let root = URL(fileURLWithPath: "/tmp/shaar-pip-controls", isDirectory: true)

  func testEdgesNearTheBorderResizeAndTheInteriorMoves() {
    let size = CGSize(width: 320, height: 180)
    XCTAssertEqual(Geometry.edges(at: CGPoint(x: 160, y: 90), in: size), [])
    XCTAssertEqual(Geometry.edges(at: CGPoint(x: 2, y: 90), in: size), .left)
    XCTAssertEqual(Geometry.edges(at: CGPoint(x: 318, y: 2), in: size), [.right, .bottom])
    XCTAssertEqual(Geometry.edges(at: CGPoint(x: 3, y: 178), in: size), [.left, .top])
  }

  func testCornerResizeKeepsShapeAndOppositeCorner() {
    let frame = CGRect(x: 100, y: 100, width: 320, height: 180)
    let resized = Geometry.resized(
      frame, edges: [.right, .bottom], by: CGSize(width: 64, height: -10),
      minimum: CGSize(width: 284, height: 160), maximum: CGSize(width: 1536, height: 803))
    XCTAssertEqual(resized.width, 384, accuracy: 0.001)
    XCTAssertEqual(resized.width / resized.height, frame.width / frame.height, accuracy: 0.001)
    XCTAssertEqual(resized.minX, frame.minX)
    XCTAssertEqual(resized.maxY, frame.maxY, accuracy: 0.001)
  }

  func testLeftEdgeResizeAnchorsTheRightEdgeWithinLimits() {
    let frame = CGRect(x: 400, y: 100, width: 320, height: 180)
    let minimum = CGSize(width: 284, height: 160)
    let shrunk = Geometry.resized(
      frame, edges: .left, by: CGSize(width: 200, height: 0), minimum: minimum,
      maximum: CGSize(width: 1536, height: 803))
    XCTAssertEqual(shrunk.width, 284.4444, accuracy: 0.01, "clamped by the minimum height")
    XCTAssertEqual(shrunk.maxX, frame.maxX, accuracy: 0.001)
    let grown = Geometry.resized(
      frame, edges: .left, by: CGSize(width: -2000, height: 0), minimum: minimum,
      maximum: CGSize(width: 1536, height: 803))
    XCTAssertEqual(grown.width, 1427.5556, accuracy: 0.01, "clamped by the maximum height")
  }

  func testTuckLeavesAStripAtTheNearerSide() {
    let screen = CGRect(x: 0, y: 46, width: 1920, height: 1004)
    let right = Geometry.tucked(CGRect(x: 1500, y: 80, width: 356, height: 200), in: screen)
    XCTAssertEqual(right.intersection(screen).width, Geometry.tuckedWidth)
    XCTAssertEqual(right.minX, screen.maxX - Geometry.tuckedWidth)
    let left = Geometry.tucked(CGRect(x: 40, y: 80, width: 356, height: 200), in: screen)
    XCTAssertEqual(left.intersection(screen).width, Geometry.tuckedWidth)
    XCTAssertEqual(left.maxX, screen.minX + Geometry.tuckedWidth)
  }

  func testPresentationOffersSkippingOnlyWithADuration() {
    let view = PictureInPictureControlsView(frame: NSRect(x: 0, y: 0, width: 356, height: 200))
    view.presentation = .init(isPlaying: true, isLive: false)
    XCTAssertEqual(
      view.availableControls,
      [.backToTab, .minimize, .close, .skipBack, .playPause, .skipForward])
    XCTAssertEqual(view.button(.playPause)?.accessibilityLabel(), "Pause")
    view.presentation = .init(isPlaying: false, isLive: true)
    XCTAssertEqual(view.availableControls, [.backToTab, .minimize, .close, .playPause])
    XCTAssertEqual(view.button(.playPause)?.accessibilityLabel(), "Play")
    view.presentation.isTucked = true
    XCTAssertEqual(view.availableControls, [.restore])
  }

  func testButtonsSendCommandsAndMinimizeTucksTheVideoWindow() throws {
    let video = transparentWindow()
    defer { video.close() }
    let controls = PictureInPictureControls()
    var commands: [PictureInPictureControls.Command] = []
    controls.onCommand = { _, command in commands.append(command) }
    let tab = UUID()
    controls.attach(
      to: video, tabID: tab, video: PictureInPictureVideo(isPlaying: true, isLive: false))
    defer { controls.detach() }
    let panel = try XCTUnwrap(controls.panel)
    XCTAssertTrue(panel.parent === video)
    XCTAssertEqual(panel.alphaValue, 0, "controls follow the video window's transparency")

    for control: PictureInPictureControlsView.Control in [.playPause, .skipBack, .skipForward] {
      controls.view.button(control)?.performClick(nil)
    }
    XCTAssertEqual(commands, [.pause, .skip(-10), .skip(10)])

    let original = video.frame
    controls.view.button(.minimize)?.performClick(nil)
    XCTAssertNotEqual(video.frame, original)
    XCTAssertEqual(controls.view.availableControls, [.restore])
    controls.view.button(.restore)?.performClick(nil)
    XCTAssertEqual(video.frame, original)

    controls.view.button(.minimize)?.performClick(nil)
    controls.view.button(.close)?.performClick(nil)
    XCTAssertEqual(video.frame, original, "closing first returns a tucked window")
    XCTAssertEqual(commands.last, .close)
  }

  func testCaptureControlsOverVideo() throws {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let cases: [(String, PictureInPictureControlsView.Presentation, Int)] = [
      ("pip-controls", .init(isPlaying: true, isLive: false), 200),
      ("pip-controls-paused", .init(isPlaying: false, isLive: false), 200),
      ("pip-controls-live", .init(isPlaying: true, isLive: true), 100),
      ("pip-controls-tucked", .init(isPlaying: true, isLive: false, isTucked: true), 5),
    ]
    for (name, presentation, minimum) in cases {
      let bitmap = try capture(presentation, to: root.appending(path: "\(name).png"))
      XCTAssertGreaterThan(whitePixels(in: bitmap), minimum, "\(name) shows no controls")
    }
  }

  private func transparentWindow() -> NSWindow {
    let window = NSWindow(
      contentRect: NSRect(x: 1400, y: 120, width: 356, height: 200), styleMask: .borderless,
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.alphaValue = 0
    window.ignoresMouseEvents = true
    return window
  }

  private func capture(
    _ presentation: PictureInPictureControlsView.Presentation, to url: URL
  ) throws -> NSBitmapImageRep {
    let size = NSSize(width: 356, height: 200)
    let container = NSView(frame: NSRect(origin: .zero, size: size))
    let video = NSImageView(frame: container.bounds)
    video.image = Self.videoFrame(size)
    video.imageScaling = .scaleAxesIndependently
    container.addSubview(video)
    let controls = PictureInPictureControlsView(frame: container.bounds)
    controls.presentation = presentation
    controls.setControlsShown(true, animated: false)
    container.addSubview(controls)
    let window = NSWindow(
      contentRect: container.frame, styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = container
    defer { window.close() }
    container.layoutSubtreeIfNeeded()
    let bitmap = try XCTUnwrap(container.bitmapImageRepForCachingDisplay(in: container.bounds))
    container.cacheDisplay(in: container.bounds, to: bitmap)
    try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
    return bitmap
  }

  /// A stand-in video frame: a dusk gradient with a horizon.
  private static func videoFrame(_ size: NSSize) -> NSImage {
    NSImage(size: size, flipped: false) { rect in
      NSGradient(
        starting: NSColor(srgbRed: 0.95, green: 0.55, blue: 0.3, alpha: 1),
        ending: NSColor(srgbRed: 0.2, green: 0.25, blue: 0.5, alpha: 1))?
        .draw(in: rect, angle: 90)
      NSColor(srgbRed: 0.1, green: 0.14, blue: 0.2, alpha: 1).setFill()
      NSRect(x: 0, y: 0, width: rect.width, height: rect.height * 0.3).fill()
      return true
    }
  }

  private func whitePixels(in bitmap: NSBitmapImageRep) -> Int {
    var count = 0
    for x in 0..<bitmap.pixelsWide {
      for y in 0..<bitmap.pixelsHigh {
        guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
        if color.redComponent > 0.95 && color.greenComponent > 0.95 && color.blueComponent > 0.95 {
          count += 1
        }
      }
    }
    return count
  }
}
