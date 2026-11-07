// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

struct ShaarMemoryPanel: View {
  @Bindable var model: ShaarMemoryModel

  init(model: ShaarMemoryModel, developer: DeveloperPageModel? = nil) {
    self.model = model
    if let developer {
      model.adoptLiveTransport(developer)
    }
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 0) {
        header
        if showsEngineGate { engineGate }
        if model.recording { recordingLine }
        if let failure = model.failure { errorBanner(failure) }
        statRows
        constructorSection(
          ShellL10n.string("Largest constructors"),
          rows: model.snapshot?.constructors,
          empty: ShellL10n.string("No heap snapshot yet"))
        constructorSection(
          ShellL10n.string("Allocation timeline"),
          rows: model.allocations,
          empty: ShellL10n.string("No allocations recorded"),
          caption: ShellL10n.string("Allocated during recording"))
      }
    }
    .accessibilityIdentifier("shaar.devtools.memoryPanel")
  }

  private var showsEngineGate: Bool {
    model.support == .needsEngine && model.snapshot == nil && model.allocations == nil
  }

  private var recordTitle: String {
    if model.recording { return ShellL10n.string("Stop recording") }
    return ShellL10n.string("Record allocations")
  }

  private var header: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 8) {
        title
        Spacer(minLength: 8)
        actions
      }
      VStack(alignment: .leading, spacing: 6) {
        title
        actions
      }
    }
    .padding(.horizontal, 13)
    .padding(.vertical, 8)
  }

  private var title: some View {
    Text(ShellL10n.string("Heap snapshot"))
      .font(.system(size: 11, weight: .semibold))
  }

  private var actions: some View {
    HStack(spacing: 8) {
      if model.busy { ProgressView().controlSize(.mini) }
      Button(ShellL10n.string("Take heap snapshot")) {
        Task { await model.takeSnapshot() }
      }
      .disabled(model.busy || model.recording)
      .accessibilityIdentifier("shaar.devtools.memory.snapshot")
      Button(recordTitle) {
        Task { await model.toggleRecording() }
      }
      .disabled(model.busy)
      .accessibilityIdentifier("shaar.devtools.memory.record")
    }
    .controlSize(.small)
  }

  private var engineGate: some View {
    HStack(spacing: 8) {
      Image(systemName: "memorychip")
      Text(ShellL10n.string("Live heap snapshots need engine support"))
      Spacer()
    }
    .font(.system(size: 10))
    .padding(10)
    .accessibilityIdentifier("shaar.devtools.memory.engineGate")
  }

  private var recordingLine: some View {
    Text(ShellL10n.string("Recording allocations"))
      .font(.system(size: 10, weight: .medium))
      .padding(.horizontal, 13)
      .padding(.bottom, 6)
  }

  private func errorBanner(_ failure: String) -> some View {
    HStack(spacing: 8) {
      Image(systemName: "exclamationmark.triangle")
      Text(failure).lineLimit(2)
      Spacer()
    }
    .font(.system(size: 10))
    .padding(10)
  }

  private var statRows: some View {
    VStack(alignment: .leading, spacing: 0) {
      metricRow(
        ShellL10n.string("Total size"),
        value: model.snapshot.map { ShaarByteCount.format($0.totalBytes) })
      metricRow(
        ShellL10n.string("Node count"), value: model.snapshot.map { String($0.nodeCount) })
      metricRow(
        ShellL10n.string("Constructors"),
        value: model.snapshot.map { String($0.constructors.count) })
    }
  }

  private func constructorSection(
    _ title: String, rows: [ShaarHeapConstructor]?, empty: String, caption: String? = nil
  ) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      sectionHeader(title)
      if let caption {
        Text(caption)
          .font(.system(size: 10))
          .foregroundStyle(.primary)
          .padding(.horizontal, 13)
          .padding(.bottom, 4)
      }
      if let rows, !rows.isEmpty {
        columnHeader
        ForEach(Array(rows.prefix(8))) { item in
          constructorRow(item)
        }
      } else {
        Text(empty)
          .font(.system(size: 10))
          .foregroundStyle(.primary)
          .padding(.horizontal, 13)
          .padding(.vertical, 10)
      }
    }
  }

  private var columnHeader: some View {
    HStack {
      Spacer()
      Text(ShellL10n.string("Count")).frame(width: 48, alignment: .trailing)
      Text(ShellL10n.string("Size")).frame(width: 72, alignment: .trailing)
    }
    .font(.system(size: 9, weight: .medium))
    .foregroundStyle(.primary)
    .padding(.horizontal, 13)
    .frame(height: 18)
  }

  private func constructorRow(_ item: ShaarHeapConstructor) -> some View {
    HStack {
      Text(item.name).lineLimit(1).devToolsDataDirection()
      Spacer(minLength: 8)
      Text(String(item.count)).frame(width: 48, alignment: .trailing)
      Text(ShaarByteCount.format(item.selfBytes)).frame(width: 72, alignment: .trailing)
    }
    .font(.system(size: 10, design: .monospaced))
    .padding(.horizontal, 13)
    .frame(height: 25)
    .devToolsDataDirection()
  }

  private func sectionHeader(_ title: String) -> some View {
    Text(title)
      .font(.system(size: 10, weight: .semibold))
      .padding(.horizontal, 13)
      .padding(.top, 12)
      .padding(.bottom, 7)
  }

  private func metricRow(_ name: String, value: String?) -> some View {
    HStack {
      Text(name).lineLimit(1)
      Spacer(minLength: 4)
      Text(value ?? "—").devToolsDataDirection()
    }
    .font(.system(size: 10, design: .monospaced))
    .padding(.horizontal, 13)
    .frame(height: 25)
  }
}
