// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

struct ShaarRenderingPanel: View {
  @Bindable var model: ShaarRenderingModel

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        mediaSection
        overlaySection
        if let failure = model.failure {
          Text(failure)
            .font(.system(size: 11))
            .foregroundStyle(.primary)
            .textSelection(.enabled)
            .accessibilityIdentifier("shaar.devtools.rendering.failure")
        }
      }
      .padding(16)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .accessibilityIdentifier("shaar.devtools.rendering.panel")
    .task { await model.prepare() }
  }

  private var mediaSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      heading("Media")
      menuRow(
        "Color scheme", selection: $model.colorScheme,
        options: ShaarRenderingColorScheme.allCases,
        identifier: "shaar.devtools.rendering.colorScheme",
        label: \.title)
      menuRow(
        "Reduced motion", selection: $model.motion,
        options: ShaarRenderingMotion.allCases,
        identifier: "shaar.devtools.rendering.reducedMotion",
        label: \.title)
      menuRow(
        "CSS media", selection: $model.cssMedia,
        options: ShaarRenderingCSSMedia.allCases,
        identifier: "shaar.devtools.rendering.media",
        label: \.title)
    }
  }

  private var overlaySection: some View {
    VStack(alignment: .leading, spacing: 8) {
      heading("Overlay")
      overlayToggle(
        "Paint flashing", isOn: $model.paintRects,
        identifier: "shaar.devtools.rendering.paintRects")
      overlayToggle(
        "Layout shift regions", isOn: $model.layoutShiftRegions,
        identifier: "shaar.devtools.rendering.layoutShift")
      overlayToggle(
        "FPS meter", isOn: $model.fpsMeter,
        identifier: "shaar.devtools.rendering.fps")
      if let note = overlayNote {
        Text(ShellL10n.string(note))
          .font(.system(size: 11))
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("shaar.devtools.rendering.overlayNote")
      }
    }
  }

  private var overlayEnabled: Bool {
    model.overlayProbeFinished && model.overlayCommandsAvailable
  }

  private var overlayNote: String? {
    guard model.overlayProbeFinished else { return nil }
    guard !model.overlayCommandsAvailable else { return nil }
    return "Paint flashing, layout shifts, and the FPS meter need the next engine build."
  }

  private func heading(_ title: String) -> some View {
    Text(ShellL10n.string(title))
      .font(.system(size: 11, weight: .semibold))
      .foregroundStyle(.secondary)
  }

  private func menuRow<Option: Hashable & Identifiable>(
    _ title: String,
    selection: Binding<Option>,
    options: [Option],
    identifier: String,
    label: KeyPath<Option, String>
  ) -> some View {
    HStack(spacing: 12) {
      Text(ShellL10n.string(title))
        .font(.system(size: 12))
        .frame(width: 148, alignment: .leading)
      Picker(ShellL10n.string(title), selection: selection) {
        ForEach(options) { option in
          Text(ShellL10n.string(option[keyPath: label])).tag(option)
        }
      }
      .pickerStyle(.menu)
      .labelsHidden()
      .accessibilityIdentifier(identifier)
      Spacer(minLength: 0)
    }
  }

  private func overlayToggle(_ title: String, isOn: Binding<Bool>, identifier: String) -> some View {
    Toggle(ShellL10n.string(title), isOn: isOn)
      .font(.system(size: 12))
      .disabled(!overlayEnabled)
      .accessibilityIdentifier(identifier)
  }
}
