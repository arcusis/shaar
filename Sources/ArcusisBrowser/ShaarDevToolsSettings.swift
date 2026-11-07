// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

enum ShaarDevToolsMetrics {
  static let bottomHeight: CGFloat = 380
  static let sideWidth: CGFloat = 420
}

enum ShaarDevToolsOpening: Equatable {
  case last
  case panel(ShaarDevToolsSection)

  static let key = "shaar.devtools.openingPanel"
  static let lastSectionKey = "shaar.devtools.lastSection"

  var storageValue: String {
    switch self {
    case .last: "Last panel"
    case .panel(let section): section.rawValue
    }
  }

  var title: String {
    switch self {
    case .last: "Last panel"
    case .panel(let section): section.rawValue
    }
  }

  static func load(_ defaults: UserDefaults) -> Self {
    guard let raw = defaults.string(forKey: key) else { return .panel(.elements) }
    if raw == "Last panel" { return .last }
    if let section = ShaarDevToolsSection(rawValue: raw) { return .panel(section) }
    return .panel(.elements)
  }
}

struct ShaarDevToolsSettings: View {
  @Bindable var model: ShaarDevToolsModel

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      header
      settingRow("Dock position") { dockMenu }
      Button(ShellL10n.string("Restore default sizes"), action: model.restoreDefaultDockSizes)
        .buttonStyle(.borderless)
        .font(.system(size: 12))
        .accessibilityIdentifier("shaar.devtools.restoreSizes")
      settingRow("Opening panel") { openingMenu }
      shortcuts
    }
    .padding(16)
    .frame(width: 440)
    .background(Color(nsColor: .windowBackgroundColor))
    .overlay {
      RoundedRectangle(cornerRadius: 8)
        .strokeBorder(Color.primary.opacity(0.16), lineWidth: 1)
    }
    .clipShape(RoundedRectangle(cornerRadius: 8))
    .accessibilityIdentifier("shaar.devtools.settings")
  }

  private var header: some View {
    HStack {
      Text(ShellL10n.string("DevTools settings"))
        .font(.system(size: 13, weight: .semibold))
      Spacer()
      Button(action: model.closeSettings) {
        Image(systemName: "xmark")
          .font(.system(size: 10, weight: .semibold))
          .frame(width: 22, height: 22)
      }
      .buttonStyle(.plain)
      .accessibilityLabel(ShellL10n.string("Close"))
    }
  }

  private var dockMenu: some View {
    Menu {
      ForEach(ShaarDevToolsDock.allCases, id: \.self) { dock in
        Button(ShellL10n.string(dock.rawValue)) { model.dock = dock }
      }
    } label: {
      menuValue(ShellL10n.string(model.dock.rawValue))
    }
    .menuStyle(.borderlessButton)
    .accessibilityIdentifier("shaar.devtools.dockSetting")
  }

  private var openingMenu: some View {
    Menu {
      Button(ShellL10n.string("Last panel")) { model.chooseOpening(.last) }
      Divider()
      ForEach(model.sections, id: \.self) { section in
        Button(ShellL10n.string(section.rawValue)) { model.chooseOpening(.panel(section)) }
      }
    } label: {
      menuValue(ShellL10n.string(model.opening.title))
    }
    .menuStyle(.borderlessButton)
    .accessibilityIdentifier("shaar.devtools.openingPanel")
  }

  private var shortcuts: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(ShellL10n.string("Shortcuts"))
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.secondary)
      shortcut("Toggle DevTools", keys: "F12")
      shortcut("Toggle DevTools", keys: "⌥⌘I")
      shortcut("Command menu", keys: "⇧⌘P")
      shortcut("Clear the search or close DevTools", keys: "Escape")
    }
  }

  private func settingRow<Control: View>(_ title: String, @ViewBuilder control: () -> Control)
    -> some View
  {
    HStack {
      Text(ShellL10n.string(title))
        .font(.system(size: 12))
      Spacer(minLength: 12)
      control()
    }
  }

  private func menuValue(_ title: String) -> some View {
    HStack(spacing: 4) {
      Text(title)
        .font(.system(size: 12))
      Image(systemName: "chevron.up.chevron.down")
        .font(.system(size: 8, weight: .semibold))
        .foregroundStyle(.secondary)
    }
  }

  private func shortcut(_ action: String, keys: String) -> some View {
    HStack {
      Text(ShellL10n.string(action))
        .font(.system(size: 12))
      Spacer(minLength: 12)
      Text(verbatim: keys)
        .font(.system(size: 11, design: .monospaced))
        .foregroundStyle(.secondary)
    }
  }
}
