// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import SwiftUI
import XCTest

@MainActor final class ShaarNetworkRulesMockVisualTests: XCTestCase {
  func testRuleEditorMockRendersOffscreen() throws {
    guard ProcessInfo.processInfo.environment["SHAAR_NETWORK_RULES_CAPTURE"] == "1" else {
      throw XCTSkip("Offscreen rules mock capture requires explicit opt-in")
    }
    _ = NSApplication.shared
    let previous = NSApp.keyWindow
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appending(path: "Evidence/issue-1157")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    for scheme in [ColorScheme.light, .dark] {
      let suffix = scheme == .dark ? "dark" : "light"
      let appearance: NSAppearance.Name = scheme == .dark ? .darkAqua : .aqua
      let view = ShaarNetworkRulesMock()
        .frame(width: 1040, height: 620)
        .environment(\.colorScheme, scheme)
      let image = try VisualCapture.renderOffscreen(
        view, size: NSSize(width: 1040, height: 620), appearance: appearance,
        to: root.appending(path: "mock-network-rules-\(suffix).png"))
      XCTAssertEqual(image.pixelsWide, 1040)
      XCTAssertEqual(image.pixelsHigh, 620)
    }
    XCTAssertTrue(NSApp.keyWindow === previous)
  }
}

private struct ShaarNetworkRulesMock: View {
  var body: some View {
    VStack(spacing: 0) {
      VStack(alignment: .leading, spacing: 8) {
        Text("localhost:3000/dashboard")
          .font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
        Divider()
        Text("Dashboard").font(.system(size: 24, weight: .semibold))
        Text("Inspect the local build while you work.")
          .font(.system(size: 13)).foregroundStyle(.secondary)
        Spacer()
      }
      .padding(22).frame(height: 180)
      Divider()
      VStack(spacing: 0) {
        HStack(spacing: 0) {
          Image(systemName: "chevron.left.forwardslash.chevron.right")
            .frame(width: 30).foregroundStyle(.secondary)
          ForEach(["Elements", "Console", "Network", "Application", "Performance", "Sources"], id: \.self) { title in
            Text(title)
              .font(.system(size: 11, weight: title == "Network" ? .semibold : .regular))
              .padding(.horizontal, 11).frame(height: 29)
              .background(title == "Network" ? Color.primary.opacity(0.08) : .clear,
                          in: RoundedRectangle(cornerRadius: 6))
          }
          Spacer()
          Image(systemName: "ellipsis").frame(width: 28)
          Image(systemName: "xmark").font(.system(size: 10)).frame(width: 28)
        }
        .padding(.horizontal, 7).frame(height: 36)
        Divider()
        HStack(spacing: 8) {
          Text("All").fontWeight(.semibold)
          Text("Fetch/XHR")
          Text("JS")
          Text("CSS")
          Text("Img")
          Text("Doc")
          Text("WS")
          Text("Errors")
          Spacer()
          Text("Rules active · 2")
            .foregroundStyle(.orange)
            .padding(.horizontal, 8).frame(height: 22)
            .background(Color.orange.opacity(0.11), in: Capsule())
          Text("Rules  2").fontWeight(.semibold)
          Text("Search requests").foregroundStyle(.tertiary)
            .padding(.horizontal, 8).frame(width: 126, height: 22)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 5))
        }
        .font(.system(size: 10)).padding(.horizontal, 12).frame(height: 38)
        Divider()
        HStack(spacing: 0) {
          VStack(spacing: 0) {
            HStack {
              Text("Status").frame(width: 45, alignment: .leading)
              Text("Method").frame(width: 48, alignment: .leading)
              Text("Name").frame(maxWidth: .infinity, alignment: .leading)
              Text("Type").frame(width: 52, alignment: .leading)
              Text("Time").frame(width: 42, alignment: .leading)
            }
            .font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
            .padding(.horizontal, 12).frame(height: 29)
            .background(Color.primary.opacity(0.035))
            request("200", "GET", "dashboard", "Doc", "182 ms", selected: false)
            request("200", "GET", "app.js", "JS", "61 ms", selected: false)
            request("503", "POST", "api/orders", "XHR", "211 ms", selected: true)
            request("200", "GET", "logo.svg", "Img", "20 ms", selected: false)
            Spacer()
            Divider()
            Text("Create rule from selected request")
              .font(.system(size: 10, weight: .medium))
              .foregroundStyle(Color.accentColor)
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding(.horizontal, 12).frame(height: 34)
          }
          Divider()
          VStack(alignment: .leading, spacing: 0) {
            HStack {
              Text("Response rule").font(.system(size: 12, weight: .semibold))
              Spacer()
              Text("Saved to project").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12).frame(height: 34)
            Divider()
            VStack(alignment: .leading, spacing: 10) {
              field("Match", "POST  http://localhost:3000/api/orders")
              HStack {
                Text("Action").frame(width: 62, alignment: .leading)
                Text("Mock response ▾").fontWeight(.medium)
                Spacer()
                Text("Enabled").foregroundStyle(.orange)
              }
              field("Status", "200")
              field("Headers", "Content-Type: application/json")
              Text("Body").foregroundStyle(.secondary)
              Text("{\n  \"orders\": [],\n  \"source\": \"local fixture\"\n}")
                .font(.system(size: 10, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8).background(Color.primary.opacity(0.04),
                                        in: RoundedRectangle(cornerRadius: 5))
              Spacer()
              HStack {
                Text("Runs only for this tab while enabled")
                  .foregroundStyle(.secondary)
                Spacer()
                Text("Save rule").fontWeight(.semibold).foregroundStyle(Color.accentColor)
              }
            }
            .font(.system(size: 10)).padding(12)
          }
          .frame(width: 354)
        }
        Divider()
        Text("›  Console command line")
          .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, 12).frame(height: 34)
      }
      .frame(height: 439)
      .background(Color(nsColor: .windowBackgroundColor))
    }
    .background(Color(nsColor: .textBackgroundColor))
  }

  private func request(
    _ status: String, _ method: String, _ name: String, _ type: String,
    _ time: String, selected: Bool
  ) -> some View {
    HStack {
      Text(status).frame(width: 45, alignment: .leading)
      Text(method).frame(width: 48, alignment: .leading)
      Text(name).frame(maxWidth: .infinity, alignment: .leading)
      Text(type).frame(width: 52, alignment: .leading)
      Text(time).frame(width: 42, alignment: .leading)
    }
    .font(.system(size: 10, design: .monospaced))
    .padding(.horizontal, 12).frame(height: 35)
    .background(selected ? Color.accentColor.opacity(0.1) : .clear)
    .overlay(alignment: .bottom) { Divider() }
  }

  private func field(_ label: String, _ value: String) -> some View {
    HStack(alignment: .top) {
      Text(label).foregroundStyle(.secondary).frame(width: 62, alignment: .leading)
      Text(value).font(.system(size: 10, design: .monospaced))
        .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}
