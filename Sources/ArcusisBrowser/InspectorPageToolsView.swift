// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

struct InspectorPageToolsView: View {
  let inspector: InspectorModel
  @Bindable var model: InspectorPageToolsModel

  static var titleAccessibilityTraits: AccessibilityTraits { .isHeader }

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
          }.buttonStyle(.plain).help(tool.title).accessibilityLabel(tool.title)
            .accessibilityAddTraits(model.tool == tool ? .isSelected : [])
        }
      }.padding(.horizontal, 8).padding(.vertical, 5)
      HStack {
        Text(model.tool.title).font(.system(size: 12, weight: .semibold))
          .accessibilityAddTraits(Self.titleAccessibilityTraits)
        Spacer()
        Text(inspector.target.url.host ?? InspectorToolsL10n.string("Page"))
          .font(.system(size: 11, design: .monospaced))
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
          ? InspectorToolsL10n.string("Waiting for page diagnostics")
          : InspectorToolsL10n.string("Page diagnostics · local capture"),
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
    InspectorSection(InspectorToolsL10n.string("Detected technologies"), copy: copyTechnologies) {
      if model.startedAt == nil && model.failure != nil {
        hint(InspectorToolsL10n.string("Page diagnostics are unavailable in this document."))
      } else if model.startedAt == nil {
        ProgressView(InspectorToolsL10n.string("Reading page…")).controlSize(.small)
          .font(.system(size: 11))
      } else if model.signals.isEmpty {
        hint(
          InspectorToolsL10n.string(
            "No supported runtime markers found. Detection is limited to exposed globals, DOM markers and generator metadata."
          )
        )
      }
      ForEach(model.signals) { signal in
        HStack(alignment: .top) {
          VStack(alignment: .leading, spacing: 4) {
            Text(signal.name).font(.system(size: 12, weight: .medium))
            Text(InspectorToolsL10n.string(signal.source)).font(.system(size: 11)).foregroundStyle(
              .secondary)
          }
          Spacer()
          Text(signal.version ?? InspectorToolsL10n.string("Version unavailable"))
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(.secondary).multilineTextAlignment(.trailing)
            .environment(\.layoutDirection, .leftToRight)
        }.padding(.vertical, 5)
      }
    }
  }

  private var vitals: some View {
    Group {
      InspectorSection(InspectorToolsL10n.string("Core Web Vitals")) {
        let value = model.developer.performanceSnapshot
        metric(
          "LCP", detail: InspectorToolsL10n.string("Largest contentful paint"), value: value?.lcp,
          unit: "ms",
          quality: value?.lcpQuality ?? .unavailable)
        Divider().padding(.vertical, 8)
        metric(
          "INP", detail: InspectorToolsL10n.string("Interaction to next paint"), value: value?.inp,
          unit: "ms",
          quality: value?.inpQuality ?? .unavailable)
        Divider().padding(.vertical, 8)
        metric(
          "CLS", detail: InspectorToolsL10n.string("Cumulative layout shift"), value: value?.cls,
          unit: "",
          quality: value?.clsQuality ?? .unavailable)
        hint(
          InspectorToolsL10n.string(
            "Live navigation diagnostics. INP requires a measured interaction; buffered entries can be limited. These are not field percentile scores."
          )
        )
      }
      InspectorSection(InspectorToolsL10n.string("Renderer")) {
        let value = model.developer.performanceSnapshot
        InspectorProperty(
          "CPU",
          value: model.cpu.map { String(format: "%.1f%%", $0) }
            ?? InspectorToolsL10n.string("Unavailable"),
          copy: inspector.copy)
        InspectorProperty(
          InspectorToolsL10n.string("JS heap"),
          value: value?.heapBytes.map(Self.bytes) ?? InspectorToolsL10n.string("Unavailable"),
          copy: inspector.copy)
        InspectorProperty(
          "FPS",
          value: value?.fps.map { String(format: "%.0f", $0) }
            ?? InspectorToolsL10n.string("Unavailable"),
          copy: inspector.copy)
        InspectorProperty(
          InspectorToolsL10n.string("Requests"), value: value.map { String($0.requests) } ?? "—",
          copy: inspector.copy)
        InspectorProperty(
          InspectorToolsL10n.string("Observed transfer"),
          value: value.map { Self.bytes($0.transferredBytes) } ?? "—",
          copy: inspector.copy)
        hint(
          InspectorToolsL10n.string(
            "CPU is main-thread task time between samples. FPS is unavailable in hidden documents. Cross-origin transfer sizes may be restricted."
          )
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
      InspectorSection(
        InspectorToolsL10n.plural("%d recent requests", count: model.requests.count)
      ) {
        hint(
          InspectorToolsL10n.string(
            "Resource timing plus fetch/XHR observed while page tools are open. Headers and timings can be restricted; — means unavailable."
          )
        )
        if model.requests.isEmpty { hint(InspectorToolsL10n.string("No requests observed yet.")) }
      }
      LazyVStack(spacing: 0) {
        ForEach(model.requests.reversed()) { row in
          VStack(alignment: .leading, spacing: 5) {
            HStack {
              Text(row.method == "UNKNOWN" ? "—" : row.method).foregroundStyle(.secondary)
              Text(URL(string: row.url)?.lastPathComponent.nonEmpty ?? row.url).lineLimit(1)
                .truncationMode(.middle)
                .environment(\.layoutDirection, .leftToRight)
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
            .help(row.url).contextMenu {
              Button(InspectorToolsL10n.string("Copy URL")) { inspector.copy(row.url) }
            }
            .overlay(alignment: .bottom) { Divider() }
        }
      }
    }
  }

  private var console: some View {
    Group {
      InspectorSection(
        InspectorToolsL10n.plural("%d recent messages", count: model.console.count),
        copy: copyConsole
      ) {
        hint(
          InspectorToolsL10n.string(
            "Recorded since page tools opened, up to 300 messages. Earlier console history and worker logs are unavailable."
          )
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
            Text(row.message).environment(\.layoutDirection, .leftToRight).font(
              .system(size: 11, design: .monospaced)
            ).textSelection(.enabled)
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
    InspectorSection(InspectorToolsL10n.string("Local bug report")) {
      VStack(alignment: .leading, spacing: 12) {
        Label(
          InspectorToolsL10n.string("Screenshot, console, HAR and environment"),
          systemImage: "doc.zipper"
        )
        .font(.system(size: 12, weight: .medium))
        hint(
          InspectorToolsL10n.string(
            "Creates a ZIP in this profile’s Downloads. Includes the current viewport, up to 300 console messages, recent page requests and active simulations."
          )
        )
        Toggle(
          InspectorToolsL10n.string("Include sensitive HAR headers"),
          isOn: Bindable(model.developer).includeSensitiveHeaders
        )
        .toggleStyle(.checkbox).font(.system(size: 11))
        hint(
          InspectorToolsL10n.string(
            "Sensitive header values are redacted by default. Console text redacts common credential patterns and strips URL credentials, queries and fragments. URL paths, screenshots and unrecognized secrets may still contain sensitive data. Nothing is uploaded."
          )
        )
        Button {
          Task { _ = await model.developer.createBugReport() }
        } label: {
          HStack {
            if model.developer.creatingBugReport { ProgressView().controlSize(.mini) }
            Text(
              InspectorToolsL10n.string(
                model.developer.creatingBugReport ? "Creating report…" : "Create bug report"))
            Spacer()
            Image(systemName: "arrow.down.doc")
          }.font(.system(size: 12, weight: .medium))
        }.buttonStyle(.borderedProminent).controlSize(.regular).disabled(
          model.developer.creatingBugReport || model.startedAt == nil)
        if let file = model.developer.reportURL {
          Label(InspectorToolsL10n.string("Saved to Downloads"), systemImage: "checkmark.circle")
            .font(.system(size: 11))
            .foregroundStyle(.secondary).help(file.lastPathComponent)
        }
        if let error = model.developer.reportFailure { hint(error) }
        Divider()
        hint(
          InspectorToolsL10n.string(
            "Page-level capture only. Response bodies, browser headers, worker/WebSocket traffic and other frames may be unavailable."
          )
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
    PanelsL10n.byteCount(Int64(min(max(0, value), Double(Int64.max / 2))))
  }
}

extension String {
  fileprivate var nonEmpty: String? { isEmpty ? nil : self }
}
