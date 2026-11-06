// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import SwiftUI
import WebKit

struct ShaarWebKitComparisonPanel: View {
  @Bindable var model: ShaarWebKitComparisonModel
  let chromiumEvents: [ShaarDevToolsEvent]

  var body: some View {
    VStack(spacing: 0) {
      controls
      Divider()
      GeometryReader { geometry in
        if geometry.size.width < 700 {
          let scale = min(1, (geometry.size.width - 24) / model.viewport.width)
          ScrollView(.vertical) {
            webKitCard(scale: scale)
              .padding(12)
              .frame(maxWidth: .infinity, alignment: .top)
          }
          .background(Color.primary.opacity(0.025))
        } else {
          let scale = min(0.7, (geometry.size.width - 50) / 2 / model.viewport.width)
          ScrollView([.horizontal, .vertical]) {
            HStack(alignment: .top, spacing: 12) {
              chromiumCard(scale: scale)
              webKitCard(scale: scale)
            }
            .padding(12)
          }
          .background(Color.primary.opacity(0.025))
        }
      }
      Divider()
      errors
    }
    .accessibilityIdentifier("shaar.devtools.comparison.panel")
  }

  private var controls: some View {
    HStack(spacing: 8) {
      Text(ShellL10n.string("Chromium + WebKit"))
        .font(.system(size: 10, weight: .semibold))
      Text("\(Int(model.viewport.width)) × \(Int(model.viewport.height))")
        .font(.system(size: 10, design: .monospaced))
        .foregroundStyle(.secondary)
      Spacer(minLength: 4)
      Toggle(ShellL10n.string("Sync scroll"), isOn: $model.syncScroll)
        .toggleStyle(.checkbox)
        .font(.system(size: 10))
      Button(ShellL10n.string("Refresh comparison")) { model.refresh() }
        .controlSize(.small)
    }
    .padding(.horizontal, 12)
    .frame(height: 36)
  }

  private func chromiumCard(scale: CGFloat) -> some View {
    VStack(spacing: 0) {
      cardHeader("Chromium", systemImage: "globe")
      if let data = model.chromiumPNG, let image = NSImage(data: data) {
        Image(nsImage: image)
          .resizable()
          .frame(width: model.viewport.width * scale, height: model.viewport.height * scale)
      } else {
        placeholder("Waiting for Chromium frame", scale: scale)
      }
    }
    .background(Color(nsColor: .windowBackgroundColor))
    .clipShape(RoundedRectangle(cornerRadius: 7))
    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.primary.opacity(0.12)))
    .accessibilityIdentifier("shaar.devtools.comparison.chromium")
  }

  private func webKitCard(scale: CGFloat) -> some View {
    VStack(spacing: 0) {
      cardHeader("WebKit", systemImage: "safari")
      if let view = model.webView {
        ShaarComparisonWebView(view: view)
          .frame(width: model.viewport.width, height: model.viewport.height)
          .scaleEffect(scale, anchor: .topLeading)
          .frame(
            width: model.viewport.width * scale, height: model.viewport.height * scale,
            alignment: .topLeading
          )
          .overlay(alignment: .topLeading) {
            ForEach(Array(model.differenceTiles.enumerated()), id: \.offset) { _, tile in
              Rectangle()
                .fill(Color.orange.opacity(0.18))
                .overlay(Rectangle().strokeBorder(Color.orange.opacity(0.75), lineWidth: 1))
                .frame(width: tile.width * scale, height: tile.height * scale)
                .offset(x: tile.minX * scale, y: tile.minY * scale)
            }
            .allowsHitTesting(false)
          }
      } else {
        placeholder(model.status ?? "Waiting for WebKit", scale: scale)
      }
    }
    .background(Color(nsColor: .windowBackgroundColor))
    .clipShape(RoundedRectangle(cornerRadius: 7))
    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.primary.opacity(0.12)))
    .accessibilityIdentifier("shaar.devtools.comparison.webkit")
  }

  private func cardHeader(_ title: String, systemImage: String) -> some View {
    HStack(spacing: 5) {
      Image(systemName: systemImage)
      Text(ShellL10n.string(title)).fontWeight(.semibold)
      Spacer()
    }
    .font(.system(size: 10))
    .padding(.horizontal, 9)
    .frame(height: 28)
    .overlay(alignment: .bottom) { Divider() }
  }

  private func placeholder(_ message: String, scale: CGFloat) -> some View {
    Text(ShellL10n.string(message))
      .font(.system(size: 11))
      .foregroundStyle(.secondary)
      .frame(width: model.viewport.width * scale, height: model.viewport.height * scale)
  }

  private var errors: some View {
    let safariErrors = model.safariOnlyErrors(comparedWith: chromiumEvents)
    return VStack(alignment: .leading, spacing: 5) {
      HStack {
        Text(ShellL10n.string("WebKit-only errors"))
          .font(.system(size: 10, weight: .semibold))
        Spacer()
        Text("\(model.differenceTiles.count) \(ShellL10n.string("different regions"))")
          .font(.system(size: 10, design: .monospaced))
          .foregroundStyle(.secondary)
      }
      if let status = model.status {
        Text(status).foregroundStyle(.secondary)
      } else if safariErrors.isEmpty {
        Text(ShellL10n.string("No WebKit-only errors captured"))
          .foregroundStyle(.secondary)
      } else {
        ForEach(Array(safariErrors.suffix(3).enumerated()), id: \.offset) { _, message in
          Text(message).lineLimit(1).help(message)
        }
      }
    }
    .font(.system(size: 10))
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .frame(maxWidth: .infinity, alignment: .leading)
    .frame(minHeight: 58)
  }
}

private struct ShaarComparisonWebView: NSViewRepresentable {
  let view: WKWebView

  func makeNSView(context: Context) -> WKWebView { view }
  func updateNSView(_ nsView: WKWebView, context: Context) {}
}
