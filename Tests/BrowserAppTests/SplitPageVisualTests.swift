import AppKit
import BrowserCore
import SwiftUI
import XCTest

@testable import ArcusisBrowser

@MainActor
final class SplitPageVisualTests: XCTestCase {
  func testTwoPaneCapture() async throws {
    try XCTSkipUnless(SidebarVisualCaptureSupport.enabled, "Visual capture requires explicit opt-in")
    let first = UUID()
    let second = UUID()
    let view = SplitPageView(
      split: BrowserSplit(tabIDs: [first, second]), focusedID: first,
      onFocus: { _ in }, onUnsplit: { _ in }, onRatioChange: { _ in }
    ) { id in
      ZStack {
        id == first ? Color(red: 0.90, green: 0.94, blue: 0.99) : Color(red: 0.96, green: 0.92, blue: 0.86)
        Text(id == first ? "First page" : "Second page").foregroundStyle(.black)
      }
    }
    let mounted = try MountedChromeSidebar(view: view, size: NSSize(width: 800, height: 500), appearance: .aqua)
    defer { mounted.close() }
    _ = try await mounted.capture(to: URL(fileURLWithPath: "/tmp/split-page-view.png"), requiredText: ["First page", "Second page"])
  }
}
