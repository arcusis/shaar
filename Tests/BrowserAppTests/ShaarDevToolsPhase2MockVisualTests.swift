// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import SwiftUI
import XCTest

@testable import ArcusisBrowser

@MainActor final class ShaarDevToolsPhase2MockVisualTests: XCTestCase {
  func testPhase2LayoutsRenderOffscreenInLightAndDark() throws {
    guard ProcessInfo.processInfo.environment["SHAAR_PHASE2_MOCK_CAPTURE"] == "1" else {
      throw XCTSkip("Offscreen phase 2 mock capture requires explicit opt-in")
    }
    _ = NSApplication.shared
    let previous = NSApp.keyWindow
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appending(path: "Evidence/issue-1134")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    for scheme in [ColorScheme.light, .dark] {
      let appearance: NSAppearance.Name = scheme == .dark ? .darkAqua : .aqua
      let suffix = scheme == .dark ? "dark" : "light"
      for mode in Phase2Mock.Mode.allCases {
        let image = try VisualCapture.renderOffscreen(
          Phase2Mock(mode: mode).frame(width: 1040, height: 620)
            .environment(\.colorScheme, scheme),
          size: NSSize(width: 1040, height: 620), appearance: appearance,
          to: root.appending(path: "mock-\(mode.rawValue)-\(suffix).png"))
        XCTAssertEqual(image.pixelsWide, 1040)
        XCTAssertEqual(image.pixelsHigh, 620)
      }
    }
    XCTAssertTrue(NSApp.keyWindow === previous)
  }
}

private struct Phase2Mock: View {
  enum Mode: String, CaseIterable { case application, performance, sources }
  let mode: Mode

  private var selectedTab: String {
    switch mode {
    case .application: "Application"
    case .performance: "Performance"
    case .sources: "Sources"
    }
  }

  var body: some View {
    VStack(spacing: 0) {
      pagePreview.frame(height: 180)
      Divider()
      VStack(spacing: 0) {
        toolbar
        Divider()
        content.frame(maxWidth: .infinity).frame(height: 366)
        Divider()
        footer
      }
      .background(Color(nsColor: .windowBackgroundColor))
    }
    .background(Color(nsColor: .textBackgroundColor))
  }

  private var pagePreview: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("localhost:3000/dashboard")
        .font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
      Divider()
      Text("Dashboard").font(.system(size: 24, weight: .semibold))
      Text("Inspect the local build while you work.")
        .font(.system(size: 13)).foregroundStyle(.secondary)
      Spacer()
    }
    .padding(22)
    .frame(maxWidth: .infinity, alignment: .topLeading)
  }

  private var toolbar: some View {
    HStack(spacing: 4) {
      Image(systemName: "chevron.left.forwardslash.chevron.right")
        .font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
        .frame(width: 28)
      ForEach(
        ["Elements", "Console", "Network", "Application", "Performance", "Sources"],
        id: \.self
      ) { title in
        Text(title)
          .font(.system(size: 11, weight: title == selectedTab ? .semibold : .regular))
          .foregroundStyle(title == selectedTab ? .primary : .secondary)
          .padding(.horizontal, 11)
          .frame(height: 29)
          .background {
            if title == selectedTab {
              RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.08))
            }
          }
      }
      Spacer()
      Image(systemName: "ellipsis").frame(width: 28)
      Image(systemName: "xmark").font(.system(size: 10)).frame(width: 28)
    }
    .padding(.horizontal, 7)
    .frame(height: 36)
  }

  @ViewBuilder private var content: some View {
    switch mode {
    case .application: application
    case .performance: performance
    case .sources: sources
    }
  }

  private var application: some View {
    HStack(spacing: 0) {
      VStack(alignment: .leading, spacing: 0) {
        groupLabel("STORAGE")
        navRow("Cookies", symbol: "circle.grid.2x2", selected: true)
        navRow("Local Storage", symbol: "externaldrive", selected: false)
        navRow("Session Storage", symbol: "rectangle.stack", selected: false)
        navRow("IndexedDB", symbol: "cylinder.split.1x2", selected: false)
        navRow("Cache Storage", symbol: "archivebox", selected: false)
        groupLabel("BACKGROUND")
        navRow("Service Workers", symbol: "gearshape.2", selected: false)
        Spacer()
        Text("Clear site data…")
          .font(.system(size: 10)).foregroundStyle(.secondary)
          .padding(12)
      }
      .frame(width: 190).frame(maxHeight: .infinity, alignment: .topLeading)
      .background(Color.primary.opacity(0.025))
      Divider()
      VStack(spacing: 0) {
        HStack {
          Text("Cookies").font(.system(size: 11, weight: .semibold))
          Text("localhost").font(.system(size: 10)).foregroundStyle(.secondary)
          Spacer()
          Text("Filter by domain").font(.system(size: 10)).foregroundStyle(.tertiary)
            .padding(.horizontal, 9).frame(height: 22)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 5))
        }
        .padding(.horizontal, 12).frame(height: 36)
        Divider()
        HStack {
          column("Name", width: 140)
          column("Value", width: 195)
          column("Domain", width: 130)
          column("Flags", width: 110)
          Spacer()
        }
        .padding(.horizontal, 12).frame(height: 29)
        .background(Color.primary.opacity(0.035))
        cookieRow("session", "••••••••", "localhost", "HttpOnly · Secure", selected: true)
        cookieRow("theme", "dark", "localhost", "SameSite=Lax", selected: false)
        cookieRow("locale", "en-US", "localhost", "Session", selected: false)
        Spacer()
        Divider()
        HStack {
          Text("3 cookies for this site").foregroundStyle(.secondary)
          Spacer()
          Text("+  Add").foregroundStyle(Color.accentColor)
          Text("Delete").foregroundStyle(.secondary)
        }
        .font(.system(size: 10)).padding(.horizontal, 12).frame(height: 31)
      }
    }
  }

  private func cookieRow(
    _ name: String, _ value: String, _ domain: String, _ flags: String, selected: Bool
  ) -> some View {
    HStack {
      column(name, width: 140)
      column(value, width: 195)
      column(domain, width: 130)
      column(flags, width: 110)
      Spacer()
    }
    .font(.system(size: 10, design: .monospaced))
    .padding(.horizontal, 12).frame(height: 36)
    .background(selected ? Color.accentColor.opacity(0.10) : .clear)
    .overlay(alignment: .bottom) { Divider() }
  }

  private var performance: some View {
    ScrollView(.vertical) {
      VStack(spacing: 0) {
        HStack(spacing: 8) {
          metric("LCP", "1.8 s", "Good", color: .green)
          metric("INP", "84 ms", "Good", color: .green)
          metric("CLS", "0.02", "Good", color: .green)
          metric("TTFB", "140 ms", "Good", color: .green)
          metric("FCP", "0.8 s", "Good", color: .green)
        }
        .padding(12)
        Divider()
        HStack(spacing: 0) {
          VStack(alignment: .leading, spacing: 10) {
            HStack {
              Text("This page load").font(.system(size: 11, weight: .semibold))
              Spacer()
              Text("/dashboard  ·  10:42:15")
                .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
            }
            ForEach(0..<5) { index in
              HStack(spacing: 8) {
                Text(["Navigation", "FCP", "LCP", "Long task", "Interaction"][index])
                  .font(.system(size: 10)).frame(width: 75, alignment: .leading)
                GeometryReader { geometry in
                  Capsule()
                    .fill(index == 3 ? Color.orange.opacity(0.7) : Color.accentColor.opacity(0.6))
                    .frame(
                      width: [0.90, 0.28, 0.46, 0.15, 0.10][index] * geometry.size.width,
                      height: 7
                    )
                    .offset(x: [0.0, 0.15, 0.43, 0.55, 0.75][index] * geometry.size.width)
                }
                .frame(height: 8)
              }
            }
            Text("0 ms                         1,000 ms                       2,000 ms")
              .font(.system(size: 9, design: .monospaced)).foregroundStyle(.tertiary)
            Divider()
            HStack {
              Text("Long tasks").font(.system(size: 11, weight: .semibold))
              Spacer()
              Text("2 tasks  ·  86 ms total")
                .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Text("script evaluation      42 ms      1.13 s")
            Text("event dispatch         44 ms      1.57 s")
          }
          .font(.system(size: 10, design: .monospaced))
          .padding(14)
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
          Divider()
          VStack(alignment: .leading, spacing: 10) {
            Text("Page resources").font(.system(size: 11, weight: .semibold))
            Text("JS heap          18.4 MB")
            Text("DOM nodes             842")
            Text("Event listeners       126")
            Divider()
            Text("Resource summary").font(.system(size: 11, weight: .semibold))
            Text("28 requests       1.4 MB")
            Text("3 failed requests")
            Divider()
            Text("Route history").font(.system(size: 11, weight: .semibold))
            Text("/dashboard       1.8 s LCP")
            Text("/products        1.2 s LCP")
          }
          .font(.system(size: 10, design: .monospaced))
          .padding(14).frame(width: 270).frame(maxHeight: .infinity, alignment: .topLeading)
        }
      }
    }
  }

  private func metric(_ label: String, _ value: String, _ state: String, color: Color) -> some View
  {
    VStack(alignment: .leading, spacing: 5) {
      Text(label).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
      Text(value).font(.system(size: 17, weight: .medium, design: .rounded))
      Text(state).font(.system(size: 10)).foregroundStyle(color)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(10)
    .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 6))
  }

  private var sources: some View {
    HStack(spacing: 0) {
      VStack(alignment: .leading, spacing: 0) {
        groupLabel("RESOURCES")
        navRow("localhost:3000", symbol: "globe", selected: false)
        navRow("▾  app", symbol: "folder", selected: false)
        navRow("     dashboard.tsx", symbol: "doc.text", selected: true)
        navRow("     api.ts", symbol: "doc.text", selected: false)
        navRow("▸  styles", symbol: "folder", selected: false)
        navRow("▸  images", symbol: "folder", selected: false)
        Spacer()
        Text("4 resources loaded").font(.system(size: 10)).foregroundStyle(.secondary)
          .padding(12)
      }
      .frame(width: 220).frame(maxHeight: .infinity, alignment: .topLeading)
      .background(Color.primary.opacity(0.025))
      Divider()
      VStack(spacing: 0) {
        HStack {
          Image(systemName: "doc.text").foregroundStyle(.secondary)
          Text("dashboard.tsx").font(.system(size: 11, weight: .semibold))
          Spacer()
          Text("Pretty print").foregroundStyle(.secondary)
          Text("Open in editor ↗").foregroundStyle(Color.accentColor)
        }
        .font(.system(size: 10)).padding(.horizontal, 13).frame(height: 35)
        Divider()
        HStack(alignment: .top, spacing: 11) {
          Text((1...12).map(String.init).joined(separator: "\n"))
            .foregroundStyle(.tertiary)
          VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 0) {
              Text("import ").foregroundStyle(.purple)
              Text("{ fetchOrders } ")
              Text("from ").foregroundStyle(.purple)
              Text("'./api'").foregroundStyle(.green)
            }
            Text(" ")
            HStack(spacing: 0) {
              Text("export default function ").foregroundStyle(.purple)
              Text("Dashboard() {")
            }
            Text("  const orders = fetchOrders()")
            Text(" ")
            Text("  return (")
            Text("    <main className=\"dashboard\">")
            Text("      <h1>Dashboard</h1>")
            Text("      <OrderList items={orders} />")
            Text("    </main>")
            Text("  )")
            Text("}")
          }
        }
        .font(.system(size: 11, design: .monospaced))
        .lineSpacing(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(15)
      }
    }
  }

  private var footer: some View {
    HStack {
      Text("›")
      Text("Scoped to this tab · Open Chromium DevTools for full debugging")
      Spacer()
    }
    .font(.system(size: 11, design: .monospaced))
    .foregroundStyle(.tertiary)
    .padding(.horizontal, 12)
    .frame(height: 34)
  }

  private func navRow(_ title: String, symbol: String, selected: Bool) -> some View {
    Label(title, systemImage: symbol)
      .font(.system(size: 10, weight: selected ? .semibold : .regular))
      .foregroundStyle(selected ? .primary : .secondary)
      .padding(.horizontal, 12).frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
      .background(selected ? Color.accentColor.opacity(0.10) : .clear)
  }

  private func groupLabel(_ title: String) -> some View {
    Text(title).font(.system(size: 9, weight: .semibold))
      .foregroundStyle(.tertiary).padding(.horizontal, 12).padding(.top, 13).padding(.bottom, 6)
  }

  private func column(_ text: String, width: CGFloat) -> some View {
    Text(text).lineLimit(1).frame(width: width, alignment: .leading)
  }
}
