// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

struct ShaarDevToolsPanel: View {
  @Bindable var model: ShaarDevToolsModel
  let inspector: InspectorModel?
  let openChromium: () -> Void
  @FocusState private var focusedSection: ShaarDevToolsSection?

  var body: some View {
    VStack(spacing: 0) {
      toolbar
      Divider()
      content.frame(maxWidth: .infinity, maxHeight: .infinity)
      Divider()
      commandLine
    }
    .background(Color(nsColor: .windowBackgroundColor))
    .onExitCommand { model.close() }
    .onChange(of: inspector?.isOpen) { _, open in
      if open == false && model.isOpen { model.close() }
    }
    .accessibilityIdentifier("shaar.devtools.shell")
  }

  private var toolbar: some View {
    HStack(spacing: 4) {
      Image(systemName: "chevron.left.forwardslash.chevron.right")
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(.secondary)
        .frame(width: 28)
      ForEach(ShaarDevToolsSection.allCases, id: \.self) { section in
        Button {
          model.section = section
          focusedSection = section
        } label: {
          Text(ShellL10n.string(section.rawValue))
            .font(.system(size: 11, weight: model.section == section ? .semibold : .regular))
            .foregroundStyle(model.section == section ? .primary : .secondary)
            .padding(.horizontal, 11)
            .frame(height: 29)
            .background {
              if model.section == section {
                RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.08))
              }
            }
        }
        .buttonStyle(.plain)
        .focusable()
        .focused($focusedSection, equals: section)
        .accessibilityAddTraits(model.section == section ? .isSelected : [])
        .accessibilityIdentifier("shaar.devtools.\(section.rawValue.lowercased())")
      }
      Spacer(minLength: 8)
      Menu {
        ForEach(ShaarDevToolsDock.allCases, id: \.self) { dock in
          Button(ShellL10n.string(dock.rawValue)) { model.dock = dock }
        }
        Divider()
        Button(ShellL10n.string("Open Chromium DevTools"), action: openChromium)
      } label: {
        Image(systemName: "ellipsis")
          .frame(width: 28, height: 28)
      }
      .menuStyle(.borderlessButton)
      .help(ShellL10n.string("DevTools options"))
      .accessibilityLabel(ShellL10n.string("DevTools options"))
      Button {
        model.close()
      } label: {
        Image(systemName: "xmark")
          .font(.system(size: 10, weight: .semibold))
          .frame(width: 28, height: 28)
      }
      .buttonStyle(.plain)
      .help(ShellL10n.string("Close DevTools"))
      .accessibilityLabel(ShellL10n.string("Close DevTools"))
    }
    .padding(.horizontal, 7)
    .frame(height: 36)
    .onMoveCommand(perform: moveSection)
  }

  @ViewBuilder private var content: some View {
    switch model.section {
    case .elements:
      if let inspector, inspector.isOpen {
        InspectorPanel(model: inspector)
      } else {
        pendingPanel("Inspector is unavailable for this page")
      }
    case .console:
      pendingPanel("Console events will appear here when the engine stream is available")
    case .network:
      pendingPanel("Network requests will appear here when the engine stream is available")
    }
  }

  private func pendingPanel(_ message: String) -> some View {
    VStack(spacing: 9) {
      Image(systemName: "waveform.path")
        .font(.system(size: 22, weight: .ultraLight))
        .foregroundStyle(.tertiary)
      Text(ShellL10n.string(message))
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(24)
  }

  private var commandLine: some View {
    HStack(spacing: 8) {
      Text(">")
        .font(.system(size: 12, weight: .medium, design: .monospaced))
        .foregroundStyle(.secondary)
      Text(ShellL10n.string("Console command line arrives with the Console panel"))
        .font(.system(size: 11, design: .monospaced))
        .foregroundStyle(.tertiary)
      Spacer()
    }
    .padding(.horizontal, 12)
    .frame(height: 34)
  }

  private func moveSection(_ direction: MoveCommandDirection) {
    guard focusedSection != nil,
      let index = ShaarDevToolsSection.allCases.firstIndex(of: model.section)
    else { return }
    let next: Int
    switch direction {
    case .left: next = max(0, index - 1)
    case .right: next = min(ShaarDevToolsSection.allCases.count - 1, index + 1)
    default: return
    }
    model.section = ShaarDevToolsSection.allCases[next]
    focusedSection = model.section
  }
}
