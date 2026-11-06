// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import SwiftUI
import XCTest

@MainActor final class ShaarReproMockVisualTests: XCTestCase {
  func testReproMockRendersOffscreen() throws {
    guard ProcessInfo.processInfo.environment["SHAAR_REPRO_MOCK_CAPTURE"] == "1" else {
      throw XCTSkip("Offscreen repro mock capture requires explicit opt-in")
    }
    _ = NSApplication.shared
    let previous = NSApp.keyWindow
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appending(path: "Evidence/issue-1158")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    for scheme in [ColorScheme.light, .dark] {
      let suffix = scheme == .dark ? "dark" : "light"
      let appearance: NSAppearance.Name = scheme == .dark ? .darkAqua : .aqua
      let image = try VisualCapture.renderOffscreen(
        ShaarReproMock().frame(width: 1040, height: 620)
          .environment(\.colorScheme, scheme),
        size: NSSize(width: 1040, height: 620), appearance: appearance,
        to: root.appending(path: "mock-repro-\(suffix).png"))
      XCTAssertEqual(image.pixelsWide, 1040)
    }
    XCTAssertTrue(NSApp.keyWindow === previous)
  }
}

private struct ShaarReproMock: View {
  var body: some View {
    VStack(spacing: 0) {
      VStack(alignment: .leading, spacing: 9) {
        Text("localhost:3000/dashboard")
          .font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
        Divider()
        Text("Dashboard").font(.system(size: 24, weight: .semibold))
        Text("Inspect the local build while you work.")
          .font(.system(size: 13)).foregroundStyle(.secondary)
        Spacer()
      }
      .padding(22).frame(maxWidth: .infinity, alignment: .topLeading)
      Divider()
      VStack(spacing: 0) {
        HStack(spacing: 4) {
          Image(systemName: "chevron.left.forwardslash.chevron.right")
            .frame(width: 28).foregroundStyle(.secondary)
          ForEach(
            ["Elements", "Console", "Network", "Application", "Performance", "Sources", "Repro"],
            id: \.self
          ) { title in
            Text(title).font(.system(size: 11, weight: title == "Repro" ? .semibold : .regular))
              .foregroundStyle(title == "Repro" ? .primary : .secondary)
              .padding(.horizontal, 11).frame(height: 29)
              .background {
                if title == "Repro" {
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
        HStack(spacing: 0) {
          VStack(alignment: .leading, spacing: 13) {
            Text("REPRO BUNDLE").font(.system(size: 10, weight: .semibold))
              .foregroundStyle(.secondary)
            Text("Capture the last 30 seconds")
              .font(.system(size: 16, weight: .semibold))
            Text("Page video, console, network, DOM and environment in one local file.")
              .font(.system(size: 12)).foregroundStyle(.secondary)
            HStack(spacing: 10) {
              Image(systemName: "record.circle").foregroundStyle(.red)
              Text("Recording this tab · 24 s buffered")
              Spacer()
              Text("30 s").foregroundStyle(.secondary)
            }
            .font(.system(size: 11)).padding(10)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
            HStack {
              Text("Create .shaarrepro")
                .font(.system(size: 11, weight: .semibold))
                .padding(.horizontal, 14).frame(height: 28)
                .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 6))
                .foregroundStyle(.white)
              Text("Open bundle…").font(.system(size: 11)).foregroundStyle(Color.accentColor)
            }
            Spacer()
            Text("Cookies, auth headers and form values are redacted. No upload.")
              .font(.system(size: 10)).foregroundStyle(.secondary)
          }
          .padding(20).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
          Divider()
          VStack(alignment: .leading, spacing: 12) {
            Text("BUNDLE CONTENTS").font(.system(size: 10, weight: .semibold))
              .foregroundStyle(.secondary)
            ForEach(
              ["Page video     30 s", "Console        18 entries", "Network        9 requests", "DOM            1 snapshot", "Environment    Shaar · macOS"],
              id: \.self
            ) { row in
              Text(row).font(.system(size: 11, design: .monospaced))
            }
            Divider()
            Text("Copy for agent").font(.system(size: 11)).foregroundStyle(Color.accentColor)
            Spacer()
          }
          .padding(20).frame(width: 270).frame(maxHeight: .infinity, alignment: .topLeading)
        }
        Divider()
        HStack {
          Text(">  Repro data is scoped to this tab")
            .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
          Spacer()
        }.padding(.horizontal, 12).frame(height: 34)
      }
      .frame(height: 420).background(Color(nsColor: .windowBackgroundColor))
    }
    .background(Color(nsColor: .textBackgroundColor))
  }
}
