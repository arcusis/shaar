// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

struct InspectorPageToolsView: View {
  let inspector: InspectorModel
  @Bindable var model: InspectorPageToolsModel

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 0) {
        ForEach(InspectorPageToolsModel.Tool.allCases, id: \.self) { tool in
          Button {
            model.tool = tool
          } label: {
            Image(systemName: tool.symbol).font(.system(size: 13))
              .frame(maxWidth: .infinity).frame(height: 32)
              .background(
                model.tool == tool ? Color.accentColor.opacity(0.12) : .clear,
                in: RoundedRectangle(cornerRadius: 5)
              )
              .foregroundStyle(model.tool == tool ? Color.accentColor : .secondary)
              .contentShape(Rectangle())
          }.buttonStyle(.plain).help(tool.rawValue).accessibilityLabel(tool.rawValue)
            .accessibilityAddTraits(model.tool == tool ? .isSelected : [])
        }
      }.padding(.horizontal, 8).padding(.vertical, 5)
      HStack {
        Text(model.tool.rawValue).font(.system(size: 12, weight: .semibold))
        Spacer()
        Text(inspector.target.url.host ?? "Page").font(.system(size: 11, design: .monospaced))
          .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
      }.padding(12)
      Divider()
      if model.tool == .storage {
        InspectorStorageView(model: model)
      } else {
        ScrollView {
          VStack(spacing: 0) {
            switch model.tool {
            case .overview: stack
            case .vitals: vitals
            case .network: network
            case .console: console
            case .simulations: InspectorSimulationsView(model: model.developer)
            case .report: report
            case .storage: EmptyView()
            }
          }
        }.scrollBounceBehavior(.basedOnSize)
      }
      if let failure = model.failure {
        Divider()
        Text(failure).font(.system(size: 11)).foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading).padding(12)
      }
      Divider()
      Label(
        model.startedAt == nil
          ? "Waiting for page diagnostics" : "Page diagnostics · local capture",
        systemImage: "record.circle"
      )
      .font(.system(size: 10)).foregroundStyle(.secondary)
      .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).frame(height: 28)
    }
    .onChange(of: model.tool) { _, tool in
      if tool == .storage { Task { try? await model.loadStorage() } }
      Task { await model.refresh() }
    }
  }

  private var stack: some View {
    InspectorSection("Detected technologies", copy: copyTechnologies) {
      if model.startedAt == nil && model.failure != nil {
        hint("Page diagnostics are unavailable in this document.")
      } else if model.startedAt == nil {
        ProgressView("Reading page…").controlSize(.small).font(.system(size: 11))
      } else if model.signals.isEmpty {
        hint(
          "No supported runtime markers found. Detection is limited to exposed globals, DOM markers and generator metadata."
        )
      }
      ForEach(model.signals) { signal in
        HStack(alignment: .top) {
          VStack(alignment: .leading, spacing: 4) {
            Text(signal.name).font(.system(size: 12, weight: .medium))
            Text(signal.source).font(.system(size: 11)).foregroundStyle(.secondary)
          }
          Spacer()
          Text(signal.version ?? "Version unavailable").font(.system(size: 11, design: .monospaced))
            .foregroundStyle(.secondary).multilineTextAlignment(.trailing)
        }.padding(.vertical, 5)
      }
    }
  }

  private var vitals: some View {
    Group {
      InspectorSection("Core Web Vitals") {
        let value = model.developer.performanceSnapshot
        metric(
          "LCP", detail: "Largest contentful paint", value: value?.lcp, unit: "ms",
          quality: value?.lcpQuality ?? .unavailable)
        Divider().padding(.vertical, 8)
        metric(
          "INP", detail: "Interaction to next paint", value: value?.inp, unit: "ms",
          quality: value?.inpQuality ?? .unavailable)
        Divider().padding(.vertical, 8)
        metric(
          "CLS", detail: "Cumulative layout shift", value: value?.cls, unit: "",
          quality: value?.clsQuality ?? .unavailable)
        hint(
          "Live navigation diagnostics. INP requires a measured interaction; buffered entries can be limited. These are not field percentile scores."
        )
      }
      InspectorSection("Renderer") {
        let value = model.developer.performanceSnapshot
        InspectorProperty(
          "CPU", value: model.cpu.map { String(format: "%.1f%%", $0) } ?? "Unavailable",
          copy: inspector.copy)
        InspectorProperty(
          "JS heap", value: value?.heapBytes.map(Self.bytes) ?? "Unavailable", copy: inspector.copy)
        InspectorProperty(
          "FPS", value: value?.fps.map { String(format: "%.0f", $0) } ?? "Unavailable",
          copy: inspector.copy)
        InspectorProperty(
          "Requests", value: value.map { String($0.requests) } ?? "—", copy: inspector.copy)
        InspectorProperty(
          "Observed transfer", value: value.map { Self.bytes($0.transferredBytes) } ?? "—",
          copy: inspector.copy)
        hint(
          "CPU is main-thread task time between samples. FPS is unavailable in hidden documents. Cross-origin transfer sizes may be restricted."
        )
      }
    }
  }

  private func metric(
    _ title: String, detail: String, value: Double?, unit: String, quality: PerformanceQuality
  ) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      HStack {
        Text(title).font(.system(size: 11, weight: .semibold))
        Spacer()
        Text(quality.title).font(.system(size: 10, weight: .medium))
          .foregroundStyle(
            quality == .good
              ? Color.green
              : quality == .poor ? .red : quality == .needsImprovement ? .orange : .secondary)
      }
      HStack(alignment: .firstTextBaseline) {
        Text(
          value.map {
            String(format: unit.isEmpty ? "%.3f" : "%.0f", $0) + (unit.isEmpty ? "" : " " + unit)
          } ?? "—"
        )
        .font(.system(size: 13, weight: .semibold, design: .monospaced))
        Spacer()
        Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
      }
    }
  }

  private var network: some View {
    Group {
      InspectorSection("\(model.requests.count) recent requests") {
        hint(
          "Resource timing plus fetch/XHR observed while page tools are open. Headers and timings can be restricted; — means unavailable."
        )
        if model.requests.isEmpty { hint("No requests observed yet.") }
      }
      LazyVStack(spacing: 0) {
        ForEach(model.requests.reversed()) { row in
          VStack(alignment: .leading, spacing: 5) {
            HStack {
              Text(row.method == "UNKNOWN" ? "—" : row.method).foregroundStyle(.secondary)
              Text(URL(string: row.url)?.lastPathComponent.nonEmpty ?? row.url).lineLimit(1)
                .truncationMode(.middle)
              Spacer(minLength: 0)
              Text(row.status > 0 ? String(row.status) : "—").foregroundStyle(
                row.status >= 400 ? Color.red : .secondary)
            }.font(.system(size: 11, design: .monospaced))
            HStack {
              Text(row.kind).lineLimit(1)
              Spacer()
              Text(row.duration.map { String(format: "%.0f ms", $0) } ?? "—")
              Text(row.bytes.map(Self.bytes) ?? "—").frame(minWidth: 48, alignment: .trailing)
            }.font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
          }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .help(row.url).contextMenu { Button("Copy URL") { inspector.copy(row.url) } }
            .overlay(alignment: .bottom) { Divider() }
        }
      }
    }
  }

  private var console: some View {
    Group {
      InspectorSection("\(model.console.count) recent messages", copy: copyConsole) {
        hint(
          "Recorded since page tools opened, up to 300 messages. Earlier console history and worker logs are unavailable."
        )
      }
      LazyVStack(spacing: 0) {
        ForEach(Array(model.console.enumerated().reversed()), id: \.offset) { _, row in
          VStack(alignment: .leading, spacing: 5) {
            HStack {
              Text(row.level.uppercased()).font(.system(size: 10, weight: .semibold))
              Spacer()
              Text(Date(timeIntervalSince1970: row.time / 1000), style: .time).font(
                .system(size: 10, design: .monospaced)
              ).foregroundStyle(.secondary)
            }
            Text(row.message).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
              .frame(maxWidth: .infinity, alignment: .leading)
          }.foregroundStyle(
            ["error", "unhandledrejection"].contains(row.level)
              ? Color.red : row.level == "warn" ? .orange : .primary
          )
          .padding(12).overlay(alignment: .bottom) { Divider() }
        }
      }
    }
  }

  private var report: some View {
    InspectorSection("Local bug report") {
      VStack(alignment: .leading, spacing: 12) {
        Label("Screenshot, console, HAR and environment", systemImage: "doc.zipper")
          .font(.system(size: 12, weight: .medium))
        hint(
          "Creates a ZIP in this profile’s Downloads. Includes the current viewport, up to 300 console messages, recent page requests and active simulations."
        )
        Toggle(
          "Include sensitive HAR headers", isOn: Bindable(model.developer).includeSensitiveHeaders
        )
        .toggleStyle(.checkbox).font(.system(size: 11))
        hint(
          "Cookie and authorization headers are redacted by default. URLs, console messages and screenshot content are not redacted. Nothing is uploaded."
        )
        Button {
          Task { _ = await model.developer.createBugReport() }
        } label: {
          HStack {
            if model.developer.creatingBugReport { ProgressView().controlSize(.mini) }
            Text(model.developer.creatingBugReport ? "Creating report…" : "Create bug report")
            Spacer()
            Image(systemName: "arrow.down.doc")
          }.font(.system(size: 12, weight: .medium))
        }.buttonStyle(.borderedProminent).controlSize(.regular).disabled(
          model.developer.creatingBugReport || model.startedAt == nil)
        if let file = model.developer.reportURL {
          Label("Saved to Downloads", systemImage: "checkmark.circle").font(.system(size: 11))
            .foregroundStyle(.secondary).help(file.lastPathComponent)
        }
        if let error = model.developer.reportFailure { hint(error) }
        Divider()
        hint(
          "Page-level capture only. Response bodies, browser headers, worker/WebSocket traffic and other frames may be unavailable."
        )
      }
    }
  }

  private func copyTechnologies() {
    inspector.copy(
      model.signals.map { "\($0.name) \($0.version ?? "") — \($0.source)" }.joined(separator: "\n"))
  }
  private func copyConsole() {
    inspector.copy(model.console.map { "[\($0.level)] \($0.message)" }.joined(separator: "\n"))
  }

  private func hint(_ text: String) -> some View {
    Text(text).font(.system(size: 11)).foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
  }

  static func bytes(_ value: Double) -> String {
    ByteCountFormatter.string(
      fromByteCount: Int64(min(max(0, value), Double(Int64.max / 2))), countStyle: .file)
  }
}

extension String {
  fileprivate var nonEmpty: String? { isEmpty ? nil : self }
}
