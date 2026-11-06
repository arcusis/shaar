// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import SwiftUI
import XCTest

@testable import ArcusisBrowser

@MainActor final class ShaarDevToolsViewportsMockVisualTests: XCTestCase {
  func testViewportsMockRendersOffscreenInLightAndDark() throws {
    guard ProcessInfo.processInfo.environment["SHAAR_VIEWPORTS_MOCK_CAPTURE"] == "1" else {
      throw XCTSkip("Offscreen Viewports mock capture requires explicit opt-in")
    }
    _ = NSApplication.shared
    let previous = NSApp.keyWindow
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appending(path: "Evidence/issue-1159")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    for scheme in [ColorScheme.light, .dark] {
      let suffix = scheme == .dark ? "dark" : "light"
      let appearance: NSAppearance.Name = scheme == .dark ? .darkAqua : .aqua
      let image = try VisualCapture.renderOffscreen(
        ViewportsMock().frame(width: 1040, height: 620)
          .environment(\.colorScheme, scheme),
        size: NSSize(width: 1040, height: 620), appearance: appearance,
        to: root.appending(path: "mock-viewports-\(suffix).png"))
      XCTAssertEqual(image.pixelsWide, 1040)
      XCTAssertEqual(image.pixelsHigh, 620)
    }
    XCTAssertTrue(NSApp.keyWindow === previous)
  }
}

private struct ViewportsMock: View {
  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Text("localhost:3000/dashboard")
          .font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
        Spacer()
      }
      .padding(.horizontal, 22).frame(height: 48)
      Divider()
      HStack(spacing: 0) {
        Text("Dashboard").font(.system(size: 24, weight: .semibold))
        Spacer()
      }
      .padding(22).frame(height: 118)
      Divider()
      VStack(spacing: 0) {
        HStack(spacing: 4) {
          Image(systemName: "chevron.left.forwardslash.chevron.right")
            .foregroundStyle(.secondary).frame(width: 28)
          ForEach(
            ["Elements", "Console", "Network", "Application", "Performance", "Sources", "Viewports"],
            id: \.self
          ) { title in
            Text(title)
              .font(.system(size: 11, weight: title == "Viewports" ? .semibold : .regular))
              .foregroundStyle(title == "Viewports" ? .primary : .secondary)
              .padding(.horizontal, 11).frame(height: 29)
              .background {
                if title == "Viewports" {
                  RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.08))
                }
              }
          }
          Spacer()
          Image(systemName: "ellipsis").frame(width: 28)
          Image(systemName: "xmark").frame(width: 28)
        }
        .padding(.horizontal, 7).frame(height: 36)
        Divider()
        HStack(spacing: 8) {
          Text("SYNCED VIEWPORTS").font(.system(size: 10, weight: .semibold))
          Text("Scroll · clicks · navigation")
            .font(.system(size: 10)).foregroundStyle(.secondary)
          Spacer()
          Label("Add viewport", systemImage: "plus")
            .font(.system(size: 10)).foregroundStyle(Color.accentColor)
        }
        .padding(.horizontal, 14).frame(height: 36)
        Divider()
        HStack(spacing: 12) {
          preview("iPhone 15 Pro", size: "393 × 852", width: 205, notch: true)
          preview("Pixel 8", size: "412 × 915", width: 217, notch: false)
          preview("Desktop", size: "1280 × 800", width: 350, notch: false)
          Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.primary.opacity(0.025))
        Divider()
        HStack(spacing: 8) {
          Text(">")
          Text("Safe area: top 59 · bottom 34 · left 0 · right 0")
          Spacer()
          Text("3 viewports · same page")
        }
        .font(.system(size: 11, design: .monospaced))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12).frame(height: 34)
      }
      .background(Color(nsColor: .windowBackgroundColor))
    }
    .background(Color(nsColor: .textBackgroundColor))
  }

  private func preview(_ name: String, size: String, width: CGFloat, notch: Bool) -> some View {
    VStack(spacing: 0) {
      HStack {
        Text(name).font(.system(size: 11, weight: .semibold))
        Spacer()
        Text(size).font(.system(size: 10, design: .monospaced))
          .foregroundStyle(.secondary)
      }
      .padding(.horizontal, 9).frame(height: 30)
      Divider()
      VStack(spacing: 0) {
        if notch {
          Capsule().fill(.primary).frame(width: 49, height: 10).padding(.top, 7)
        }
        HStack {
          Text("Dashboard").font(.system(size: 14, weight: .semibold))
          Spacer()
        }
        .padding(.top, notch ? 17 : 20)
        HStack {
          Text("Revenue").font(.system(size: 10)).foregroundStyle(.secondary)
          Spacer()
        }
        .padding(.top, 17)
        HStack {
          Text("$24,680").font(.system(size: 20, weight: .semibold))
          Spacer()
        }
        RoundedRectangle(cornerRadius: 4).fill(Color.accentColor.opacity(0.18))
          .frame(height: 49).padding(.top, 16)
        Spacer()
      }
      .padding(.horizontal, 14)
      .frame(maxWidth: .infinity)
      .background(Color(nsColor: .textBackgroundColor))
    }
    .frame(width: width, height: 325)
    .background(Color(nsColor: .windowBackgroundColor))
    .clipShape(RoundedRectangle(cornerRadius: 7))
    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.primary.opacity(0.12)))
  }
}
