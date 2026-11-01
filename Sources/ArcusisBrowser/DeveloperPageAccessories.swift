// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

/// Native accessories stay outside the page DOM and move within the owning page card.
struct DeveloperPageAccessories: View {
  let model: SiteControlsDeveloperModel

  var body: some View {
    if model.performanceEnabled {
      PerformanceOverlay(model: model)
        .task(id: model.documentGeneration) { await model.pollPerformance() }
    }
  }
}

private struct PerformanceOverlay: View {
  let model: SiteControlsDeveloperModel
  @State private var position = CGSize.zero
  @GestureState private var drag = CGSize.zero

  var body: some View {
    GeometryReader { geometry in
      let offset = clamped(position + drag, in: geometry.size)
      PerformanceOverlayPanel(
        snapshot: model.performanceSnapshot, failure: model.performanceFailure,
        close: { model.setPerformanceEnabled(false) }
      )
      .frame(width: max(0, min(268, geometry.size.width - 24)))
      .gesture(
        DragGesture().updating($drag) { value, state, _ in state = value.translation }
          .onEnded { value in position = clamped(position + value.translation, in: geometry.size) }
      )
      .padding(12)
      .offset(offset)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
    }
  }

  private func clamped(_ value: CGSize, in size: CGSize) -> CGSize {
    CGSize(
      width: min(0, max(-max(0, size.width - 292), value.width)),
      height: min(max(0, size.height - 240), max(0, value.height)))
  }
}

struct PerformanceOverlayPanel: View {
  let snapshot: PagePerformanceSnapshot?
  var failure: String? = nil
  let close: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Label("Performance", systemImage: "waveform.path.ecg").font(.callout.weight(.semibold))
        Spacer()
        Button(action: close) { Image(systemName: "xmark") }.buttonStyle(.plain).help(
          "Hide performance overlay"
        )
        .accessibilityLabel("Hide performance overlay")
      }
      .help("Drag to move within this page")
      HStack(spacing: 10) {
        vital(
          "LCP", value: snapshot?.lcp.map { String(format: "%.2f s", $0 / 1000) },
          quality: snapshot?.lcpQuality ?? .unavailable)
        vital(
          "INP", value: snapshot?.inp.map { String(format: "%.0f ms", $0) },
          quality: snapshot?.inpQuality ?? .unavailable)
        vital(
          "CLS", value: snapshot?.cls.map { String(format: "%.3f", $0) },
          quality: snapshot?.clsQuality ?? .unavailable)
      }
      Divider()
      HStack {
        Text(snapshot?.fps.map { String(format: "%.0f FPS", $0) } ?? "FPS —")
        Spacer()
        Text(snapshot?.heapBytes.map { String(format: "%.1f MB heap", $0 / 1_000_000) } ?? "Heap —")
      }
      Text(
        "\(snapshot?.requests ?? 0) requests · \(ByteCountFormatter.string(fromByteCount: Int64(min(snapshot?.transferredBytes ?? 0, Double(Int64.max / 2))), countStyle: .file)) transferred"
      )
      Text("Current navigation · Cross-origin bytes may be unavailable.")
        .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      if let failure {
        Text(failure).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
      }
    }
    .font(.caption).monospacedDigit()
    .padding(12)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(.primary.opacity(0.12)) }
    .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
    .accessibilityElement(children: .contain)
  }

  private func vital(_ name: String, value: String?, quality: PerformanceQuality) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(name).foregroundStyle(.secondary)
      Text(value ?? "—").font(.callout.weight(.medium)).foregroundStyle(color(quality))
      Text(quality.title).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityLabel("\(name), \(value ?? "unavailable"), \(quality.title)")
  }

  private func color(_ quality: PerformanceQuality) -> Color {
    switch quality {
    case .unavailable: .secondary
    case .good: .green
    case .needsImprovement: .orange
    case .poor: .red
    }
  }
}

private func + (lhs: CGSize, rhs: CGSize) -> CGSize {
  CGSize(width: lhs.width + rhs.width, height: lhs.height + rhs.height)
}
