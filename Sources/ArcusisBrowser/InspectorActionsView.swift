// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

struct InspectorActionsView: View {
  @Bindable var model: InspectorModel
  @Binding var copyButtonFrame: CGRect
  var body: some View {
    HStack(spacing: 8) {
      HStack(spacing: 0) {
        Button {
          Task { await model.aiCopy.copy(.element) }
        } label: {
          HStack(spacing: 5) {
            Image(systemName: "doc.on.clipboard").font(.system(size: 10))
            Text(InspectorL10n.string(model.aiCopy.busy ? "Copying…" : "Copy for AI"))
              .font(.system(size: 11, weight: .medium))
          }.padding(.horizontal, 8).frame(height: 27)
        }.buttonStyle(.plain).disabled(!model.aiCopy.canCopy)
          .help(InspectorL10n.string("Copy context and screenshot (Command-Shift-C)"))
        Rectangle().fill(.primary.opacity(0.12)).frame(width: 0.5, height: 15)
        Button {
          model.presentation.copyMenuOpen.toggle()
        } label: {
          Image(systemName: "chevron.down").font(.system(size: 8, weight: .medium))
            .frame(width: 25, height: 27).contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(model.aiCopy.busy).help(InspectorL10n.string("Copy options"))
          .accessibilityLabel(InspectorL10n.string("Copy options"))
      }
      .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 5))
      .overlay(
        RoundedRectangle(cornerRadius: 5).strokeBorder(.primary.opacity(0.14), lineWidth: 0.5)
      )
      .onGeometryChange(for: CGRect.self) {
        $0.frame(in: .named("InspectorPanel"))
      } action: {
        copyButtonFrame = $0
      }
      Spacer(minLength: 0)
      Menu {
        if let selection = model.selection {
          Button(InspectorL10n.string("CSS selector")) {
            model.copy(selection.css, label: "CSS selector")
          }
          Button(InspectorL10n.string("Playwright locator")) {
            model.copy(selection.playwright, label: "Playwright locator")
          }
          Button(InspectorL10n.string("XPath")) { model.copy(selection.xpath, label: "XPath") }
          Button(InspectorL10n.string("JS path")) { model.copy(selection.jsPath, label: "JS path") }
        }
      } label: {
        Image(systemName: "curlybraces").font(.system(size: 11)).foregroundStyle(.secondary)
          .frame(width: 22, height: 24).contentShape(Rectangle())
      }.menuStyle(.borderlessButton).menuIndicator(.visible).fixedSize()
        .disabled(model.selection == nil || model.aiCopy.busy).help(
          InspectorL10n.string("Copy selector")
        )
        .accessibilityLabel(InspectorL10n.string("Copy selector"))
      InspectorIconButton(
        actionHelp("Open source", command: .inspectorSource),
        symbol: "arrow.up.right.square"
      ) {
        Task { await model.sourceActions.open() }
      }.disabled(!model.aiCopy.canCopy || model.sourceActions.busy)
      InspectorIconButton(
        actionHelp("Copy for agent", command: .inspectorAgentCopy),
        symbol: "terminal"
      ) {
        Task { await model.sourceActions.copyForAgent() }
      }.disabled(!model.aiCopy.canCopy || model.sourceActions.busy)
      InspectorIconButton(InspectorL10n.string("Save element at 2×"), symbol: "camera") {
        Task { await model.styles.saveScreenshot() }
      }.disabled(model.selection?.locked != true || model.aiCopy.busy)
    }
  }

  private func actionHelp(_ title: String, command: BrowserMenuCommand) -> String {
    let label = InspectorL10n.string(title)
    guard let keys = ShortcutCatalog.displayKeys(for: command) else { return label }
    return "\(label) · \u{2066}\(keys)\u{2069}"
  }
}

/// Drawn inside the dock, so the same menu can be rendered offscreen without ordering an NSMenu.
struct InspectorCopyMenu: View {
  @Bindable var model: InspectorModel
  @AppStorage("inspectorSourceEditor") private var sourceEditor = InspectorSourceEditor.vscode
    .rawValue
  var body: some View {
    VStack(spacing: 1) {
      item(
        "Open source", symbol: "arrow.up.right.square",
        enabled: model.aiCopy.canCopy && !model.sourceActions.busy
      ) {
        model.presentation.copyMenuOpen = false
        Task { await model.sourceActions.open() }
      }
      item(
        "Copy for agent", symbol: "terminal",
        enabled: model.aiCopy.canCopy && !model.sourceActions.busy
      ) {
        model.presentation.copyMenuOpen = false
        Task { await model.sourceActions.copyForAgent() }
      }
      Menu {
        ForEach(InspectorSourceEditor.allCases) { editor in
          Button(editor.label) { sourceEditor = editor.rawValue }
        }
      } label: {
        HStack(spacing: 8) {
          Image(systemName: "hammer").font(.system(size: 10)).frame(width: 14)
          Text(
            InspectorL10n.string("Editor") + ": "
              + (InspectorSourceEditor(rawValue: sourceEditor)?.label ?? "VS Code")
          )
          .font(.system(size: 11))
          Spacer()
          Image(systemName: InspectorL10n.forwardChevron())
            .font(.system(size: 8)).foregroundStyle(.secondary)
        }.padding(.horizontal, 8).frame(maxWidth: .infinity, alignment: .leading)
          .frame(height: 27).contentShape(Rectangle())
      }.buttonStyle(.plain).frame(maxWidth: .infinity)
      Divider().padding(.vertical, 4).padding(.horizontal, 5)
      item("Copy element", symbol: "doc.on.doc", enabled: model.aiCopy.canCopy) {
        perform(.element)
      }
      item(
        "Copy with notes", symbol: "text.bubble",
        enabled: model.aiCopy.canCopy && !model.aiCopy.notes.isEmpty
      ) {
        perform(.withNotes)
      }
      item("Copy image", symbol: "photo", enabled: model.aiCopy.canCopy) { perform(.image) }
      Divider().padding(.vertical, 4).padding(.horizontal, 5)
      Button {
        model.aiCopy.detailed.toggle()
      } label: {
        HStack(spacing: 8) {
          Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold))
            .opacity(model.aiCopy.detailed ? 1 : 0).frame(width: 14)
          Text(InspectorL10n.string("Detailed")).font(.system(size: 11))
          Spacer()
        }.padding(.horizontal, 8).frame(height: 27).contentShape(Rectangle())
      }.buttonStyle(InspectorMenuItemStyle()).help(
        InspectorL10n.string("Include computed styles, CSS rules and page diagnostics")
      )
      .accessibilityValue(InspectorL10n.string(model.aiCopy.detailed ? "On" : "Off"))
    }.padding(5)
      .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
      .overlay(
        RoundedRectangle(cornerRadius: 6).strokeBorder(.primary.opacity(0.14), lineWidth: 0.5)
      )
      .shadow(color: .black.opacity(0.17), radius: 8, y: 3)
      .accessibilityElement(children: .contain).accessibilityLabel(
        InspectorL10n.string("Copy options"))
  }

  private func perform(_ kind: InspectorAICopyModel.CopyKind) {
    model.presentation.copyMenuOpen = false
    Task { await model.aiCopy.copy(kind) }
  }

  private func item(_ title: String, symbol: String, enabled: Bool, action: @escaping () -> Void)
    -> some View
  {
    Button(action: action) {
      HStack(spacing: 8) {
        Image(systemName: symbol).font(.system(size: 10)).foregroundStyle(.secondary).frame(
          width: 14)
        InspectorL10n.text(title).font(.system(size: 11))
        Spacer()
      }.padding(.horizontal, 8).frame(height: 27).contentShape(Rectangle())
    }.buttonStyle(InspectorMenuItemStyle()).disabled(!enabled)
  }
}

private struct InspectorMenuItemStyle: ButtonStyle {
  @Environment(\.isEnabled) private var enabled
  @State private var hovered = false
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .foregroundStyle(enabled ? .primary : .tertiary)
      .background(
        .primary.opacity(enabled && (hovered || configuration.isPressed) ? 0.07 : 0),
        in: RoundedRectangle(cornerRadius: 3)
      )
      .onHover { hovered = $0 }
  }
}
