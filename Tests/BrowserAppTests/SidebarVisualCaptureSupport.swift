// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import CoreGraphics
import Foundation
import SwiftUI
import XCTest

/// Component-only CI evidence. No user profiles, physical input, or screen capture.
enum SidebarVisualCaptureSupport {
  static var enabled: Bool {
    ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true"
      && ProcessInfo.processInfo.environment["RUNNER_OS"] == "macOS"
      && ProcessInfo.processInfo.environment["ARCUSIS_SIDEBAR_VISUAL_CI"] == "1"
  }

  static func prepare() throws -> URL {
    guard enabled else { throw SidebarVisualCaptureError.captureDisabled }
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
      .appendingPathComponent("build/Verification/sidebar-chrome-ci", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let manifest = root.appendingPathComponent("manifest.json")
    if !FileManager.default.fileExists(atPath: manifest.path) {
      try writeManifest(root: root, captures: [])
    }
    return root
  }

  static func record(root: URL, entry: [String: Any]) throws {
    let manifest = root.appendingPathComponent("manifest.json")
    let data = try Data(contentsOf: manifest)
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      var captures = object["captures"] as? [[String: Any]]
    else { throw SidebarVisualCaptureError.invalidManifest }
    captures.append(entry)
    try writeManifest(root: root, captures: captures)
  }

  private static func writeManifest(root: URL, captures: [[String: Any]]) throws {
    let manifest: [String: Any] = [
      "sourceRevision": ProcessInfo.processInfo.environment["GITHUB_SHA"] ?? "unavailable",
      "componentOnly": true,
      "physicalInput": false,
      "visualAcceptance": false,
      "screenCapturePermission": false,
      "captures": captures,
    ]
    let data = try JSONSerialization.data(
      withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: root.appendingPathComponent("manifest.json"), options: .atomic)
  }
}

private enum SidebarVisualCaptureError: Error {
  case captureDisabled, layoutTimeout, emptyImage, pixelReadFailed
  case nonOpaqueImage, requiredTextMissing, invalidManifest, unexpectedPixelSize
}

@MainActor
final class MountedChromeSidebar {
  private let host: NSHostingView<AnyView>
  private let window: NSWindow
  private let size: NSSize

  init<V: View>(view: V, size: NSSize, appearance: NSAppearance.Name) throws {
    guard SidebarVisualCaptureSupport.enabled else {
      throw SidebarVisualCaptureError.captureDisabled
    }
    _ = NSApplication.shared
    self.size = size
    host = NSHostingView(rootView: AnyView(view))
    window = NSWindow(
      contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered,
      defer: false)
    window.isReleasedWhenClosed = false
    window.appearance = NSAppearance(named: appearance)
    window.isOpaque = true
    window.backgroundColor = .windowBackgroundColor
    host.appearance = window.appearance
    host.frame = NSRect(origin: .zero, size: size)
    host.autoresizingMask = [.width, .height]
    host.wantsLayer = true
    host.layer?.isOpaque = true
    window.effectiveAppearance.performAsCurrentDrawingAppearance {
      host.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    }
    window.contentView = host
    window.orderFrontRegardless()
  }

  func waitUntil(_ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(5)
    while ContinuousClock.now < deadline {
      window.displayIfNeeded()
      host.layoutSubtreeIfNeeded()
      if condition() { return true }
      try? await Task.sleep(for: .milliseconds(16))
    }
    return false
  }

  func capture(to url: URL, requiredText: [String] = []) async throws -> (width: Int, height: Int) {
    let root = try SidebarVisualCaptureSupport.prepare()
    var entry: [String: Any] = ["file": url.lastPathComponent, "status": "failed"]
    do {
      let deadline = ContinuousClock.now + .seconds(5)
      let minimumSettle = ContinuousClock.now + .milliseconds(250)
      var settled = 0
      while ContinuousClock.now < deadline, settled < 3 {
        window.displayIfNeeded()
        host.layoutSubtreeIfNeeded()
        if host.window === window, window.contentView === host,
          host.frame.size == size, host.bounds.size == size, ContinuousClock.now >= minimumSettle
        {
          settled += 1
        } else {
          settled = 0
        }
        try await Task.sleep(for: .milliseconds(16))
      }
      guard settled == 3 else { throw SidebarVisualCaptureError.layoutTimeout }
      let bitmap = try VisualCapture.render(host, to: url)
      guard let image = bitmap.cgImage else { throw SidebarVisualCaptureError.emptyImage }
      let expectedWidth = Int(size.width * VisualCapture.scale)
      let expectedHeight = Int(size.height * VisualCapture.scale)
      entry["backingScaleFactor"] = window.backingScaleFactor
      entry["captureScale"] = VisualCapture.scale
      entry["expectedPixelWidth"] = expectedWidth
      entry["expectedPixelHeight"] = expectedHeight
      entry["fittingWidth"] = Double(host.fittingSize.width)
      entry["fittingHeight"] = Double(host.fittingSize.height)
      guard bitmap.pixelsWide == expectedWidth, bitmap.pixelsHigh == expectedHeight else {
        throw SidebarVisualCaptureError.unexpectedPixelSize
      }
      let alpha = try alphaCounts(image)
      entry["pixelWidth"] = bitmap.pixelsWide
      entry["pixelHeight"] = bitmap.pixelsHigh
      entry["pointWidth"] = Double(size.width)
      entry["pointHeight"] = Double(size.height)
      entry["settledFrames"] = settled
      entry["alpha"] = alpha
      guard alpha["transparent"] == 0, alpha["translucent"] == 0 else {
        throw SidebarVisualCaptureError.nonOpaqueImage
      }
      let lines = try VisualTextRecognition.lines(in: url)
      entry["visibleText"] = lines
      entry["requiredText"] = requiredText
      let visible = lines.joined(separator: " ")
      guard requiredText.allSatisfy({ visible.range(of: $0, options: .caseInsensitive) != nil })
      else {
        throw SidebarVisualCaptureError.requiredTextMissing
      }
      entry["status"] = "passed"
      try SidebarVisualCaptureSupport.record(root: root, entry: entry)
      return (bitmap.pixelsWide, bitmap.pixelsHigh)
    } catch {
      entry["error"] = String(describing: error)
      try SidebarVisualCaptureSupport.record(root: root, entry: entry)
      throw error
    }
  }

  func close() { window.close() }

  private func alphaCounts(_ image: CGImage) throws -> [String: Int] {
    let width = image.width
    let height = image.height
    let bytesPerRow = width * 4
    var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)
    let rendered = pixels.withUnsafeMutableBytes { bytes -> Bool in
      guard
        let context = CGContext(
          data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8,
          bytesPerRow: bytesPerRow, space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
            | CGImageAlphaInfo.premultipliedLast.rawValue)
      else { return false }
      context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
      return true
    }
    guard rendered else { throw SidebarVisualCaptureError.pixelReadFailed }
    var counts = ["transparent": 0, "translucent": 0, "opaque": 0]
    for offset in stride(from: 3, to: pixels.count, by: 4) {
      switch pixels[offset] {
      case 0: counts["transparent", default: 0] += 1
      case 255: counts["opaque", default: 0] += 1
      default: counts["translucent", default: 0] += 1
      }
    }
    return counts
  }
}
