// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

struct ShaarPerformancePanel: View {
  @Bindable var model: ShaarPerformanceModel
  let phase2: ShaarPhase2Model

  var body: some View {
    ScrollView {
      VStack(spacing: 0) {
        header
        if let failure = model.failure { errorBanner(failure) }
        vitalCards
        Divider()
        ViewThatFits(in: .horizontal) {
          HStack(alignment: .top, spacing: 0) {
            timeline.frame(maxWidth: .infinity)
            Divider()
            resourceRail.frame(width: 250)
          }
          VStack(spacing: 0) {
            timeline
            Divider()
            resourceRail
          }
        }
      }
    }
    .task {
      while !Task.isCancelled && phase2.available {
        await model.refresh()
        try? await Task.sleep(for: .seconds(5))
      }
    }
    .onChange(of: phase2.events) { _, events in model.receive(events) }
    .accessibilityIdentifier("shaar.devtools.performancePanel")
  }

  private var header: some View {
    HStack(spacing: 8) {
      Text(ShellL10n.string("This page load"))
        .font(.system(size: 11, weight: .semibold))
      Text(model.path).font(.system(size: 10, design: .monospaced))
        .foregroundStyle(.secondary).lineLimit(1)
      Spacer()
      if model.loading { ProgressView().controlSize(.mini) }
      Button {
        Task { await model.refresh() }
      } label: {
        Image(systemName: "arrow.clockwise")
      }
      .buttonStyle(.plain)
      .help(ShellL10n.string("Refresh performance data"))
    }
    .padding(.horizontal, 13)
    .frame(height: 36)
  }

  private func errorBanner(_ failure: String) -> some View {
    HStack(spacing: 8) {
      Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
      Text(failure).lineLimit(2)
      Spacer()
      Button(ShellL10n.string("Retry")) { Task { await model.refresh() } }
    }
    .font(.system(size: 10)).padding(10)
  }

  private var vitalCards: some View {
    LazyVGrid(columns: [GridItem(.adaptive(minimum: 112), spacing: 8)], spacing: 8) {
      vital("LCP", value: model.lcpMilliseconds, unit: "s", divisor: 1_000)
      vital("INP", value: model.inpMilliseconds, unit: "ms")
      vital("CLS", value: model.samples.isEmpty ? nil : model.cls, unit: "")
      vital("TTFB", value: model.ttfbMilliseconds, unit: "ms")
      vital("FCP", value: model.fcpMilliseconds, unit: "s", divisor: 1_000)
    }
    .padding(11)
  }

  private func vital(
    _ title: String, value: Double?, unit: String, divisor: Double = 1
  ) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(title).font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary)
      if let value {
        Text(formatted(value / divisor, unit: unit))
          .font(.system(size: 17, weight: .semibold, design: .rounded))
        Text(ShellL10n.string("Observed this load"))
          .font(.system(size: 9)).foregroundStyle(.secondary)
      } else {
        Text("—").font(.system(size: 17, weight: .semibold))
        Text(ShellL10n.string("Waiting for data"))
          .font(.system(size: 9)).foregroundStyle(.tertiary)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(9)
    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
    .accessibilityElement(children: .combine)
  }

  private var timeline: some View {
    VStack(alignment: .leading, spacing: 0) {
      sectionHeader("Timeline")
      if model.lcpMilliseconds == nil && model.fcpMilliseconds == nil && model.tasks.isEmpty {
        emptyState("No performance entries for this page yet")
      } else {
        timelineRow("FCP", start: 0, duration: model.fcpMilliseconds, color: .blue)
        timelineRow("LCP", start: 0, duration: model.lcpMilliseconds, color: .blue)
        ForEach(model.tasks.prefix(8)) { task in
          timelineRow(task.name, start: task.start, duration: task.duration, color: .orange)
        }
      }
      Divider().padding(.top, 8)
      sectionHeader("Long tasks")
      if model.tasks.isEmpty {
        emptyState("No long tasks observed")
      } else {
        ForEach(model.tasks.prefix(10)) { task in
          HStack {
            Text(task.name).lineLimit(1)
            Spacer()
            Text(formatted(task.duration, unit: "ms"))
            Text(formatted(task.start / 1_000, unit: "s"))
              .foregroundStyle(.secondary)
          }
          .font(.system(size: 10, design: .monospaced))
          .padding(.horizontal, 13).frame(height: 25)
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .topLeading)
  }

  private func timelineRow(
    _ label: String, start: Double, duration: Double?, color: Color
  ) -> some View {
    HStack(spacing: 8) {
      Text(label).lineLimit(1).frame(width: 82, alignment: .leading)
      GeometryReader { proxy in
        if let duration, duration > 0 {
          let scale = max(3_000, (model.lcpMilliseconds ?? 0) + 500)
          RoundedRectangle(cornerRadius: 3).fill(color.opacity(0.8))
            .frame(width: max(3, proxy.size.width * min(duration / scale, 1)), height: 7)
            .offset(x: proxy.size.width * min(start / scale, 1))
            .frame(maxHeight: .infinity)
        }
      }
    }
    .font(.system(size: 9, design: .monospaced))
    .padding(.horizontal, 13).frame(height: 25)
  }

  private var resourceRail: some View {
    VStack(alignment: .leading, spacing: 0) {
      sectionHeader("Page resources")
      metricRow(
        "JS heap",
        value: model.metrics["JSHeapUsedSize"].map {
          formatted($0 / 1_048_576, unit: "MB")
        })
      metricRow("DOM nodes", value: model.counters["nodes"].map(String.init))
      metricRow("Event listeners", value: model.counters["jsEventListeners"].map(String.init))
      metricRow(
        "Main-thread busy",
        value: model.metrics["TaskDuration"].map {
          formatted($0, unit: "s")
        })
      sectionHeader("Over time")
      trendRow("JS heap", values: model.samples.compactMap(\.heapBytes))
      trendRow("DOM nodes", values: model.samples.compactMap { $0.nodes.map(Double.init) })
      trendRow("Main-thread busy", values: model.samples.compactMap(\.busySeconds))
      Divider().padding(.vertical, 7)
      sectionHeader("Resource summary")
      if model.resourceTypes.isEmpty {
        emptyState("No resources reported")
      } else {
        metricRow("Listed resources", value: String(model.resourceCount))
        if model.resourcesTruncated { emptyState("Resource list is limited") }
        ForEach(model.resourceTypes.keys.sorted(), id: \.self) { type in
          metricRow(type, value: String(model.resourceTypes[type] ?? 0))
        }
      }
      Divider().padding(.vertical, 7)
      sectionHeader("Route history")
      if model.routes.isEmpty {
        emptyState("No earlier route in this session")
      } else {
        ForEach(model.routes.prefix(5)) { route in
          metricRow(
            route.path,
            value: route.lcpMilliseconds.map {
              formatted($0 / 1_000, unit: "s LCP")
            })
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .topLeading)
  }

  private func sectionHeader(_ title: String) -> some View {
    Text(ShellL10n.string(title))
      .font(.system(size: 10, weight: .semibold))
      .padding(.horizontal, 13).padding(.top, 12).padding(.bottom, 7)
  }

  private func metricRow(_ name: String, value: String?) -> some View {
    HStack {
      Text(ShellL10n.string(name)).lineLimit(1)
      Spacer(minLength: 4)
      Text(value ?? "—").foregroundStyle(value == nil ? .tertiary : .primary)
    }
    .font(.system(size: 10, design: .monospaced))
    .padding(.horizontal, 13).frame(height: 25)
  }

  private func trendRow(_ title: String, values: [Double]) -> some View {
    HStack(spacing: 8) {
      Text(ShellL10n.string(title)).lineLimit(1)
      Spacer(minLength: 4)
      ShaarPerformanceSparkline(values: values)
        .frame(width: 80, height: 20)
    }
    .font(.system(size: 9))
    .padding(.horizontal, 13).frame(height: 25)
  }

  private func emptyState(_ message: String) -> some View {
    Text(ShellL10n.string(message))
      .font(.system(size: 10)).foregroundStyle(.secondary)
      .padding(.horizontal, 13).padding(.vertical, 10)
  }

  private func formatted(_ value: Double, unit: String) -> String {
    let digits = unit == "ms" ? 0 : 2
    return String(format: "%.*f %@", digits, value, unit)
      .trimmingCharacters(in: .whitespaces)
  }
}

private struct ShaarPerformanceSparkline: View {
  let values: [Double]

  var body: some View {
    GeometryReader { proxy in
      if values.count > 1 {
        Path { path in
          let minimum = values.min() ?? 0
          let span = max(0.001, (values.max() ?? 0) - minimum)
          for (index, value) in values.enumerated() {
            let x = proxy.size.width * Double(index) / Double(values.count - 1)
            let y = proxy.size.height * (1 - (value - minimum) / span)
            let point = CGPoint(x: x, y: y)
            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
          }
        }
        .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
      } else {
        Rectangle().fill(Color.secondary.opacity(0.2)).frame(height: 1)
          .frame(maxHeight: .infinity)
      }
    }
    .accessibilityHidden(true)
  }
}
