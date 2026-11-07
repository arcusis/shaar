// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import SwiftUI

struct ShaarPerformancePanel: View {
  @Bindable var model: ShaarPerformanceModel
  let phase2: ShaarPhase2Model
  var developer: DeveloperPageModel? = nil
  @State private var importingProject = false
  @State private var scopedProject: URL?
  @State private var hasProjectScope = false
  @State private var projectLoaded = false
  @State private var budgetError: String?
  @State private var lcpLimit = "2500"
  @State private var inpLimit = "200"
  @State private var clsLimit = "0.1"
  @State private var javascriptLimit = "500000"
  @State private var requestLimit = "30"
  @State private var enabledPerformanceHere = false

  var body: some View {
    ScrollView {
      VStack(spacing: 0) {
        header
        if let failure = model.failure { errorBanner(failure) }
        vitalCards
        budgetSection
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
      if let developer, !developer.performanceEnabled {
        developer.setPerformanceEnabled(true)
        enabledPerformanceHere = true
      }
      while !Task.isCancelled && phase2.available {
        await model.refresh()
        if let developer {
          try? await developer.refreshPerformance()
          if let snapshot = developer.performanceSnapshot { model.updatePageSnapshot(snapshot) }
        }
        let interval: Duration = model.capture == .recording ? .seconds(1) : .seconds(5)
        try? await Task.sleep(for: interval)
      }
    }
    .onChange(of: phase2.events) { _, events in model.receive(events) }
    .onChange(of: model.path) { _, _ in loadBudgetDraft() }
    .fileImporter(isPresented: $importingProject, allowedContentTypes: [.folder]) { result in
      guard case .success(let url) = result else { return }
      if hasProjectScope { scopedProject?.stopAccessingSecurityScopedResource() }
      hasProjectScope = url.startAccessingSecurityScopedResource()
      scopedProject = url
      projectLoaded = false
      do {
        try model.loadBudgets(from: url)
        loadBudgetDraft()
        projectLoaded = true
        budgetError = nil
      } catch {
        budgetError = error.localizedDescription
      }
    }
    .onDisappear {
      if enabledPerformanceHere { developer?.setPerformanceEnabled(false) }
      if hasProjectScope { scopedProject?.stopAccessingSecurityScopedResource() }
      hasProjectScope = false
      scopedProject = nil
    }
    .accessibilityIdentifier("shaar.devtools.performancePanel")
  }

  private var budgetSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        sectionHeader("Route budgets")
        Spacer()
        Button("Open project…") { importingProject = true }
          .buttonStyle(.plain)
        Button("Export report…", action: exportReport)
          .buttonStyle(.plain)
      }
      .padding(.horizontal, 13)
      if let result = model.budgetResult {
        HStack(spacing: 6) {
          Text(result.route).font(.system(size: 10, design: .monospaced))
          Text(
            "\(result.passed) passed · \(result.failed) over · \(result.unavailable) unavailable"
          )
          .font(.system(size: 10, weight: .medium))
          .foregroundStyle(result.failed > 0 ? .red : .secondary)
        }
        .padding(.horizontal, 13)
        ForEach(result.metrics) { metric in
          HStack {
            Text(metric.name).frame(width: 95, alignment: .leading)
            Text(metric.actual.map { formatted($0, unit: metric.unit) } ?? "Unavailable")
            Spacer()
            Text(metric.limit.map { "≤ \(formatted($0, unit: metric.unit))" } ?? "—")
            Text(metric.status.rawValue.uppercased())
              .foregroundStyle(
                metric.status == .over ? .red : metric.status == .pass ? .green : .secondary
              )
              .frame(width: 90, alignment: .trailing)
          }
          .font(.system(size: 10, design: .monospaced))
          .padding(.horizontal, 13).frame(height: 22)
        }
      } else {
        emptyState("No budget is configured for this route")
      }
      if scopedProject != nil {
        HStack(spacing: 7) {
          limitField("LCP ms", text: $lcpLimit)
          limitField("INP ms", text: $inpLimit)
          limitField("CLS", text: $clsLimit)
          limitField("JS bytes", text: $javascriptLimit)
          limitField("Requests", text: $requestLimit)
          Button("Save route") { saveRouteBudget() }
            .buttonStyle(.bordered)
            .disabled(!projectLoaded)
        }
        .padding(.horizontal, 13)
      }
      if let budgetError {
        Text(budgetError).font(.system(size: 10)).foregroundStyle(.red).padding(.horizontal, 13)
      }
    }
    .padding(.vertical, 8)
  }

  private func limitField(_ title: String, text: Binding<String>) -> some View {
    TextField(title, text: text)
      .textFieldStyle(.roundedBorder)
      .frame(minWidth: 70, maxWidth: 100)
      .help(title)
  }

  private func loadBudgetDraft() {
    guard let budget = model.budgetConfiguration.routes.first(where: { $0.route == model.path })
    else {
      lcpLimit = "2500"
      inpLimit = "200"
      clsLimit = "0.1"
      javascriptLimit = "500000"
      requestLimit = "30"
      return
    }
    lcpLimit = budget.lcpMilliseconds.map { String($0) } ?? ""
    inpLimit = budget.inpMilliseconds.map { String($0) } ?? ""
    clsLimit = budget.cls.map { String($0) } ?? ""
    javascriptLimit = budget.javascriptBytes.map { String($0) } ?? ""
    requestLimit = budget.requestCount.map { String($0) } ?? ""
  }

  private func saveRouteBudget() {
    guard let scopedProject,
      let lcp = Double(lcpLimit), let inp = Double(inpLimit), let cls = Double(clsLimit),
      let javascript = Int(javascriptLimit), let requests = Int(requestLimit)
    else {
      budgetError = "Enter valid non-negative values for all five limits."
      return
    }
    var routes = model.budgetConfiguration.routes.filter { $0.route != model.path }
    routes.append(
      ShaarRouteBudget(
        route: model.path, lcpMilliseconds: lcp, inpMilliseconds: inp, cls: cls,
        javascriptBytes: javascript, requestCount: requests))
    model.budgetConfiguration.routes = routes.sorted { $0.route < $1.route }
    do {
      try model.saveBudgets(to: scopedProject)
      budgetError = nil
    } catch {
      budgetError = error.localizedDescription
    }
  }

  private func exportReport() {
    guard let result = model.budgetResult else {
      budgetError = "Load a route budget and refresh the live performance data first."
      return
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    guard let data = try? encoder.encode(ShaarPerformanceBudgetReport(result: result)) else {
      budgetError = "The performance report could not be encoded."
      return
    }
    let panel = NSSavePanel()
    panel.nameFieldStringValue =
      "shaar-performance-\(model.path.replacingOccurrences(of: "/", with: "-")).json"
    panel.allowedContentTypes = [.json]
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
      try data.write(to: url, options: .atomic)
      budgetError = nil
    } catch {
      budgetError = error.localizedDescription
    }
  }

  private var header: some View {
    HStack(spacing: 8) {
      Text(captureTitle)
        .font(.system(size: 11, weight: .semibold))
      Text(model.path).font(.system(size: 10, design: .monospaced))
        .foregroundStyle(.primary).lineLimit(1)
      Spacer()
      if model.loading { ProgressView().controlSize(.mini) }
      Button(action: toggleCapture) {
        Label(captureAction, systemImage: model.capture == .recording ? "stop.fill" : "record.circle")
          .font(.system(size: 11, weight: .medium))
      }
      .buttonStyle(.plain)
      .help(captureHelp)
      .accessibilityLabel(captureAction)
      .accessibilityIdentifier("shaar.devtools.performanceRecord")
      Button {
        Task { await model.refresh() }
      } label: {
        Image(systemName: "arrow.clockwise")
      }
      .buttonStyle(.plain)
      .help(ShellL10n.string("Refresh performance data"))
      .accessibilityLabel(ShellL10n.string("Refresh performance data"))
    }
    .padding(.horizontal, 13)
    .frame(height: 36)
  }

  private var captureTitle: String {
    switch model.capture {
    case .idle: ShellL10n.string("This page load")
    case .recording: ShellL10n.string("Recording")
    case .stopped: ShellL10n.string("Recording stopped")
    }
  }

  private var captureAction: String {
    if model.capture == .recording { return ShellL10n.string("Stop") }
    return ShellL10n.string("Record")
  }

  private var captureHelp: String {
    if model.capture == .recording {
      return ShellL10n.string("Stop recording main-thread tasks")
    }
    return ShellL10n.string("Record main-thread tasks")
  }

  private func toggleCapture() {
    if model.capture == .recording {
      model.stopRecording()
      return
    }
    model.startRecording()
    Task { await model.refresh() }
  }

  private func errorBanner(_ failure: String) -> some View {
    HStack(spacing: 8) {
      Image(systemName: "exclamationmark.triangle").foregroundStyle(.primary)
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
      Text(title).font(.system(size: 9, weight: .medium)).foregroundStyle(.primary)
      if let value {
        Text(formatted(value / divisor, unit: unit))
          .font(.system(size: 17, weight: .semibold, design: .rounded))
        Text(ShellL10n.string("Observed this load"))
          .font(.system(size: 9)).foregroundStyle(.primary)
      } else {
        Text("—").font(.system(size: 17, weight: .semibold))
        Text(ShellL10n.string("Waiting for data"))
          .font(.system(size: 9)).foregroundStyle(.primary)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(9)
    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
    .accessibilityElement(children: .combine)
  }

  private var timeline: some View {
    VStack(alignment: .leading, spacing: 0) {
      sectionHeader("Main thread")
      if model.timelineTasks.isEmpty && model.lcpMilliseconds == nil && model.fcpMilliseconds == nil {
        emptyState("No performance entries for this page yet")
      } else {
        timelineRow("FCP", start: 0, duration: model.fcpMilliseconds, color: .blue)
        timelineRow("LCP", start: 0, duration: model.lcpMilliseconds, color: .blue)
        ShaarPerformanceFlameChart(tasks: model.timelineTasks)
          .padding(.horizontal, 13)
          .padding(.vertical, 6)
          .accessibilityIdentifier("shaar.devtools.performanceFlame")
      }
      Divider().padding(.top, 8)
      sectionHeader("Long tasks")
      if model.timelineTasks.isEmpty {
        emptyState("No long tasks observed")
      } else {
        ForEach(model.timelineTasks.prefix(10)) { task in
          HStack {
            Text(task.name).lineLimit(1)
            Spacer()
            Text(formatted(task.duration, unit: "ms"))
            Text(formatted(task.start / 1_000, unit: "s"))
              .foregroundStyle(.primary)
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
      Text(value ?? "—").foregroundStyle(.primary)
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
      .font(.system(size: 10)).foregroundStyle(.primary)
      .padding(.horizontal, 13).padding(.vertical, 10)
  }

  private func formatted(_ value: Double, unit: String) -> String {
    if unit == "requests" {
      return value == 1 ? "1 request" : "\(Int(value)) requests"
    }
    let digits = ["ms", "bytes"].contains(unit) ? 0 : 2
    return String(format: "%.*f %@", digits, value, unit)
      .trimmingCharacters(in: .whitespaces)
  }
}

private struct ShaarPerformanceFlameChart: View {
  let tasks: [ShaarPerformanceTask]

  var body: some View {
    let lanes = ShaarPerformanceTimeline.lanes(for: tasks)
    let origin = tasks.map(\.start).min() ?? 0
    let end = tasks.map { $0.start + $0.duration }.max() ?? origin + 1
    let span = max(end - origin, 1)
    VStack(alignment: .leading, spacing: 4) {
      if lanes.isEmpty {
        Text(ShellL10n.string("No long tasks observed"))
          .font(.system(size: 10))
          .foregroundStyle(.primary)
      } else {
        ForEach(Array(lanes.enumerated()), id: \.offset) { _, lane in
          flameLane(lane, origin: origin, span: span)
        }
        HStack {
          Text(axisLabel(origin))
          Spacer()
          Text(axisLabel(end))
        }
        .font(.system(size: 9, design: .monospaced))
        .foregroundStyle(.primary)
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(ShellL10n.string("Main thread"))
    .accessibilityValue(tasks.map { "\($0.name) \(Int($0.duration)) ms" }.joined(separator: ", "))
  }

  private func flameLane(
    _ lane: [ShaarPerformanceTask], origin: Double, span: Double
  ) -> some View {
    GeometryReader { proxy in
      ForEach(lane) { task in
        let width = max(4, proxy.size.width * task.duration / span)
        let x = proxy.size.width * (task.start - origin) / span
        Text(task.name)
          .lineLimit(1)
          .font(.system(size: 9, design: .monospaced))
          .padding(.horizontal, 4)
          .frame(width: width, height: 16, alignment: .leading)
          .background(Color.orange.opacity(0.8), in: RoundedRectangle(cornerRadius: 3))
          .offset(x: min(max(0, x), max(0, proxy.size.width - width)))
      }
    }
    .frame(height: 16)
  }

  private func axisLabel(_ milliseconds: Double) -> String {
    String(format: "%.0f ms", milliseconds)
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
