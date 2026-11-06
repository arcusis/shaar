// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import SwiftUI
import XCTest

@testable import ArcusisBrowser

@MainActor final class DevToolsDesignVisualTests: XCTestCase {
  func testShellConsoleAndNetworkMocksRenderOffscreen() throws {
    guard ProcessInfo.processInfo.environment["SHAAR_DEVTOOLS_MOCK_CAPTURE"] == "1" else {
      throw XCTSkip("Offscreen design capture requires explicit opt-in")
    }
    _ = NSApplication.shared
    let previous = NSApp.keyWindow
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appending(path: "Evidence/issue-1124")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    for scheme in [ColorScheme.light, .dark] {
      for mode in DevToolsMock.Mode.allCases {
        let name = "mock-\(mode.rawValue)-\(scheme == .dark ? "dark" : "light").png"
        let image = try VisualCapture.renderOffscreen(
          DevToolsMock(mode: mode).frame(width: 1040, height: 620)
            .environment(\.colorScheme, scheme),
          size: NSSize(width: 1040, height: 620),
          appearance: scheme == .dark ? .darkAqua : .aqua,
          to: root.appending(path: name))
        XCTAssertEqual(image.pixelsWide, 1040)
        XCTAssertEqual(image.pixelsHigh, 620)
      }
    }
    XCTAssertTrue(NSApp.keyWindow === previous)
  }
}

private struct DevToolsMock: View {
  enum Mode: String, CaseIterable { case shell, console, network }
  let mode: Mode

  private var selectedTab: String {
    switch mode {
    case .shell: "Elements"
    case .console: "Console"
    case .network: "Network"
    }
  }

  var body: some View {
    VStack(spacing: 0) {
      pagePreview.frame(height: 188)
      Divider()
      VStack(spacing: 0) {
        header
        Divider()
        switch mode {
        case .shell: shellContent
        case .console: consoleContent
        case .network: networkContent
        }
        Divider()
        commandLine
      }
      .background(Color(nsColor: .windowBackgroundColor))
    }
    .background(Color(nsColor: .textBackgroundColor))
  }

  private var pagePreview: some View {
    VStack(spacing: 0) {
      HStack(spacing: 12) {
        Image(systemName: "chevron.left")
        Image(systemName: "chevron.right")
        Spacer()
        Text("http://localhost:3000/dashboard")
          .font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
        Spacer()
        Label("Next.js :3000", systemImage: "chevron.left.forwardslash.chevron.right")
          .font(.system(size: 11)).padding(6)
          .background(
            Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 5))
      }
      .padding(.horizontal, 18).frame(height: 40)
      Divider()
      HStack {
        VStack(alignment: .leading, spacing: 8) {
          Text("Dashboard").font(.system(size: 25, weight: .semibold))
          Text("Inspect the local build while you work.").font(.system(size: 13))
            .foregroundStyle(.secondary)
        }
        Spacer()
      }
      .padding(28)
      Spacer()
    }
  }

  private var header: some View {
    HStack(spacing: 0) {
      Label("Shaar DevTools", systemImage: "chevron.left.forwardslash.chevron.right")
        .font(.system(size: 12, weight: .semibold)).frame(width: 150, alignment: .leading)
      ForEach(
        ["Elements", "Console", "Network", "Application", "Performance", "Frameworks", "Agent"],
        id: \.self
      ) { tab in
        Text(tab).font(.system(size: 11, weight: tab == selectedTab ? .semibold : .regular))
          .foregroundStyle(tab == selectedTab ? .primary : .secondary)
          .padding(.horizontal, 10).frame(height: 36)
          .overlay(alignment: .bottom) {
            if tab == selectedTab { Rectangle().fill(Color.accentColor).frame(height: 2) }
          }
      }
      Spacer(minLength: 0)
      Image(systemName: "ellipsis").frame(width: 28)
      Image(systemName: "xmark").frame(width: 24)
    }
    .padding(.horizontal, 12).frame(height: 36)
  }

  private var shellContent: some View {
    HStack(spacing: 0) {
      VStack(alignment: .leading, spacing: 13) {
        Text("ELEMENT TREE").font(.system(size: 10, weight: .semibold))
          .foregroundStyle(.secondary)
        Text("⌄  <html lang=\"en\">")
        Text("  ⌄  <body>")
        Text("     ⌄  <main class=\"dashboard\">")
        Text("          <button class=\"save\">Save</button>")
          .padding(.horizontal, 6).padding(.vertical, 5)
          .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
        Text("     </main>")
      }
      .font(.system(size: 11, design: .monospaced))
      .padding(16).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      Divider()
      VStack(alignment: .leading, spacing: 13) {
        Text("INSPECTOR  ·  BUTTON.SAVE").font(.system(size: 10, weight: .semibold))
          .foregroundStyle(.secondary)
        Text("Design     Code     Component     A11y     Assets")
          .font(.system(size: 11)).padding(.bottom, 6)
        Text("Typography").font(.system(size: 12, weight: .semibold))
        Text("Save changes").font(.system(size: 20, weight: .semibold))
        Text("Color    #1A1A1A       Font    Satoshi       Size    16px")
          .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
      }
      .padding(16).frame(width: 390).frame(maxHeight: .infinity, alignment: .topLeading)
    }
  }

  private var consoleContent: some View {
    VStack(spacing: 0) {
      filters(["All", "Errors  1", "Warnings  1", "Info", "Logs  3", "Search console…"])
      HStack(spacing: 0) {
        VStack(spacing: 0) {
          consoleRow("Info", "Dev server connected", "localhost:3000  ·  10:42:15")
          consoleRow("Log", "Loaded 24 products", "dashboard.tsx:42  ·  10:42:16")
          consoleRow("Warn", "Image is missing width and height", "ProductCard.tsx:18  ·  10:42:16")
          consoleRow("Error", "GET /api/items failed: 503", "api.ts:31  ·  10:42:17")
          Spacer()
        }
        .frame(maxWidth: .infinity)
        Divider()
        VStack(alignment: .leading, spacing: 12) {
          Text("ERROR  ·  10:42:17").font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.red)
          Text("GET /api/items failed: 503").font(.system(size: 13, weight: .medium))
          Text("api.ts:31:12").font(.system(size: 11, design: .monospaced))
            .foregroundStyle(Color.accentColor)
          Divider()
          Text("Stack trace").font(.system(size: 11, weight: .semibold))
          Text("fetchItems  ·  api.ts:31\nDashboard  ·  dashboard.tsx:42")
            .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
          Spacer()
          Label("Copy for agent", systemImage: "terminal")
            .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .padding(16).frame(width: 390).frame(maxHeight: .infinity, alignment: .topLeading)
      }
    }
  }

  private func consoleRow(_ level: String, _ message: String, _ detail: String) -> some View {
    HStack(alignment: .top, spacing: 10) {
      Circle().fill(levelColor(level))
        .frame(width: 6, height: 6).padding(.top, 5)
      VStack(alignment: .leading, spacing: 4) {
        Text(message).font(.system(size: 12))
        Text(detail).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
      }
      Spacer()
      if level == "Log" { Text("×3").font(.system(size: 10)).foregroundStyle(.secondary) }
    }
    .padding(.horizontal, 15).padding(.vertical, 10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(level == "Error" ? Color.red.opacity(0.06) : .clear)
    .overlay(alignment: .bottom) { Divider() }
  }

  private func levelColor(_ level: String) -> Color {
    switch level {
    case "Error": .red
    case "Warn": .orange
    default: .secondary
    }
  }

  private var networkContent: some View {
    VStack(spacing: 0) {
      filters([
        "All", "Fetch/XHR", "JS", "CSS", "Img", "Doc", "WS", "Errors  1", "Search requests…",
      ])
      HStack(spacing: 0) {
        VStack(spacing: 0) {
          HStack {
            Text("Name")
            Spacer()
            Text("Status")
            Text("Method")
            Text("Time")
          }
          .font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
          .padding(.horizontal, 14).frame(height: 27)
          networkRow("dashboard", "200", "GET", "54 ms")
          networkRow("main.css", "200", "GET", "23 ms")
          networkRow("items", "503", "GET", "412 ms")
          networkRow("vendor.js", "200", "GET", "84 ms")
          Spacer()
        }
        .frame(maxWidth: .infinity)
        Divider()
        VStack(alignment: .leading, spacing: 11) {
          Text("GET  /api/items").font(.system(size: 13, weight: .semibold, design: .monospaced))
          HStack {
            Text("Headers")
            Text("Payload")
            Text("Response")
            Text("Timing")
          }
          .font(.system(size: 11)).foregroundStyle(.secondary)
          Divider()
          Text("STATUS  503 Service Unavailable").font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.red)
          Text("Request URL").font(.system(size: 10)).foregroundStyle(.secondary)
          Text("http://localhost:3000/api/items")
            .font(.system(size: 11, design: .monospaced))
          Text("Response headers").font(.system(size: 11, weight: .semibold))
          Text("content-type: application/json\ncache-control: no-store")
            .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
          Spacer()
          Text("Copy as cURL   ·   Copy as fetch   ·   Copy for agent")
            .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .padding(16).frame(width: 390).frame(maxHeight: .infinity, alignment: .topLeading)
      }
    }
  }

  private func networkRow(_ name: String, _ status: String, _ method: String, _ time: String)
    -> some View
  {
    HStack(spacing: 10) {
      Text(name).font(.system(size: 11, design: .monospaced))
      Spacer()
      Text(status).foregroundStyle(status == "503" ? .red : .secondary).frame(width: 35)
      Text(method).foregroundStyle(.secondary).frame(width: 40)
      Text(time).foregroundStyle(.secondary).frame(width: 48, alignment: .trailing)
    }
    .font(.system(size: 10, design: .monospaced))
    .padding(.horizontal, 14).frame(height: 34)
    .background(status == "503" ? Color.red.opacity(0.06) : .clear)
    .overlay(alignment: .bottom) { Divider() }
  }

  private func filters(_ names: [String]) -> some View {
    HStack(spacing: 6) {
      ForEach(names, id: \.self) { name in
        Text(name).font(.system(size: 10, weight: name == "All" ? .semibold : .regular))
          .foregroundStyle(name.hasPrefix("Search") ? .tertiary : .secondary)
          .padding(.horizontal, 9).frame(height: 22)
          .background(Color(nsColor: .controlBackgroundColor), in: Capsule())
      }
      Spacer()
    }
    .padding(.horizontal, 12).frame(height: 36)
    .overlay(alignment: .bottom) { Divider() }
  }

  private var commandLine: some View {
    HStack(spacing: 8) {
      Text(">").foregroundStyle(Color.accentColor)
      Text("Evaluate JavaScript in this tab…").foregroundStyle(.tertiary)
      Spacer()
      Text("↩ run    ↑↓ history").foregroundStyle(.tertiary)
    }
    .font(.system(size: 11, design: .monospaced))
    .padding(.horizontal, 15).frame(height: 34)
  }
}
