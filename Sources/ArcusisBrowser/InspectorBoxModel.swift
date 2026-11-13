// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

struct InspectorBoxModel: View {
  let box: InspectorSelection.Box
  /// Sits ahead of `highlight` so a trailing closure still highlights an edge.
  var edit: ((String, String) -> Void)?
  /// Opens one value for offscreen evidence. The dock starts closed.
  var editingEdge: String?
  var highlight: ((String, Int, Bool) -> Void)?
  @State private var hovered: String?
  @State private var editing: String?
  @State private var draft: String
  @State private var cancelRequested = false
  @State private var committed = false
  @State private var wantsFocus = false
  @FocusState private var fieldFocused: Bool

  init(
    box: InspectorSelection.Box,
    edit: ((String, String) -> Void)? = nil,
    editingEdge: String? = nil,
    highlight: ((String, Int, Bool) -> Void)? = nil
  ) {
    self.box = box
    self.edit = edit
    self.editingEdge = editingEdge
    self.highlight = highlight
    _hovered = State(initialValue: nil)
    _editing = State(initialValue: editingEdge)
    _draft = State(initialValue: InspectorBoxEdit.draft(for: box, edge: editingEdge))
  }

  var body: some View {
    ZStack {
      ring("margin", values: box.margin, inset: 0)
      ring("border", values: box.border, inset: 18)
      ring("padding", values: box.padding, inset: 36)
      RoundedRectangle(cornerRadius: 2).fill(.primary.opacity(0.035))
        .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(.primary.opacity(0.14)))
        .padding(54)
      contentSize
    }.frame(height: 142).environment(\.layoutDirection, .leftToRight)
      .accessibilityElement(children: .contain)
      .accessibilityLabel(
        InspectorL10n.format(
          "Box model. Content %@ by %@ pixels.",
          arguments: [
            .string(InspectorColor.number(box.contentWidth.rounded())),
            .string(InspectorColor.number(box.contentHeight.rounded())),
          ])
      )
  }

  @ViewBuilder private var contentSize: some View {
    let width = InspectorColor.number(box.contentWidth.rounded())
    let height = InspectorColor.number(box.contentHeight.rounded())
    if edit == nil, editing != "content0", editing != "content1" {
      Text("\(width) × \(height)")
        .font(.system(size: 11, weight: .medium, design: .monospaced))
    } else {
      HStack(spacing: 0) {
        contentValue(width, index: 0)
        Text(" × ")
        contentValue(height, index: 1)
      }.font(.system(size: 11, weight: .medium, design: .monospaced))
    }
  }

  private func ring(_ name: String, values: [String], inset: CGFloat) -> some View {
    GeometryReader { geometry in
      let width = max(0, geometry.size.width - inset * 2)
      let height = max(0, geometry.size.height - inset * 2)
      ZStack(alignment: .topLeading) {
        RoundedRectangle(cornerRadius: 2).fill(.primary.opacity(0.02))
          .overlay(
            RoundedRectangle(cornerRadius: 2).strokeBorder(
              .primary.opacity(0.13),
              style: StrokeStyle(lineWidth: 0.5, dash: name == "margin" ? [3, 2] : [])))
        InspectorL10n.text(name.capitalized).font(.system(size: 9)).foregroundStyle(.secondary)
          .offset(x: 5, y: 3)
        if values.count == 4 {
          value(values[0], region: name, index: 0).position(x: width / 2, y: 10)
          value(values[1], region: name, index: 1).position(x: width - 10, y: height / 2)
          value(values[2], region: name, index: 2).position(x: width / 2, y: height - 10)
          value(values[3], region: name, index: 3).position(x: 10, y: height / 2)
        }
      }.frame(width: width, height: height).offset(x: inset, y: inset)
    }
  }

  @ViewBuilder private func value(_ raw: String, region: String, index: Int) -> some View {
    let key = region + String(index)
    if editing == key {
      editor(region: region, index: index, compact: true)
    } else {
      measurement(raw, region: region, index: index, key: key)
    }
  }

  @ViewBuilder private func contentValue(_ raw: String, index: Int) -> some View {
    let key = "content" + String(index)
    if editing == key {
      editor(region: "content", index: index, compact: false)
    } else if edit == nil {
      Text(raw)
    } else {
      Button {
        beginEditing(raw, region: "content", index: index)
      } label: {
        Text(raw)
          .padding(.horizontal, 2)
          .background(
            .primary.opacity(hovered == key ? 0.08 : 0), in: RoundedRectangle(cornerRadius: 3))
      }
      .buttonStyle(.plain)
      .accessibilityLabel(InspectorL10n.string(index == 0 ? "Width" : "Height"))
      .accessibilityHint(InspectorL10n.string("Edit box model value"))
      .onHover { hover(key, region: "content", index: index, active: $0) }
    }
  }

  @ViewBuilder private func measurement(
    _ raw: String, region: String, index: Int, key: String
  ) -> some View {
    let text = raw.replacingOccurrences(of: "px", with: "")
    let zero = Double(text) == 0
    let label = Text(zero ? "—" : text)
      .font(.system(size: 10, weight: zero ? .regular : .medium, design: .monospaced))
      .foregroundStyle(zero ? .secondary : .primary).lineLimit(1)
      .padding(.horizontal, 2).frame(minWidth: 16, minHeight: 16)
      .background(
        .primary.opacity(hovered == key ? 0.08 : 0), in: RoundedRectangle(cornerRadius: 3)
      )
      .contentShape(Rectangle())
    if edit == nil {
      label.help(tip(region: region, index: index, raw: raw)).onHover { active in
        hover(key, region: region, index: index, active: active)
      }
    } else {
      Button {
        beginEditing(raw, region: region, index: index)
      } label: {
        label
      }
      .buttonStyle(.plain)
      .help(tip(region: region, index: index, raw: raw))
      .accessibilityLabel(Self.editAccessibilityLabel(region: region, index: index))
      .accessibilityHint(InspectorL10n.string("Edit box model value"))
      .onHover { hover(key, region: region, index: index, active: $0) }
    }
  }

  static func editAccessibilityLabel(region: String, index: Int) -> String {
    let side = ["top", "right", "bottom", "left"][index]
    return InspectorL10n.format(
      "Edit %@ %@",
      arguments: [
        .string(InspectorL10n.string(region.capitalized)),
        .string(InspectorL10n.string(side.capitalized)),
      ])
  }

  private func editor(region: String, index: Int, compact: Bool) -> some View {
    TextField("", text: $draft)
      .textFieldStyle(.plain)
      .font(.system(size: compact ? 10 : 11, weight: .medium, design: .monospaced))
      .multilineTextAlignment(.center)
      .frame(width: compact ? 36 : 44, height: compact ? 14 : 16)
      .padding(.horizontal, 2)
      .background(.background, in: RoundedRectangle(cornerRadius: 3))
      .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(.primary.opacity(0.35)))
      .accessibilityLabel(Self.editorAccessibilityLabel(region: region, index: index))
      .focused($fieldFocused)
      .onKeyPress(keys: [.upArrow, .downArrow], phases: [.down, .repeat]) { press in
        nudgeBox(press)
      }
      .onAppear {
        if wantsFocus { fieldFocused = true }
      }
      .onSubmit(commitEditing)
      .onExitCommand(perform: cancelEditing)
      .onChange(of: fieldFocused) { _, focused in
        guard !focused, let key = editing else { return }
        let typed = draft
        Task { @MainActor in
          if cancelRequested {
            cancelRequested = false
            committed = true
            return
          }
          apply(key: key, typed: typed)
        }
      }
  }

  private func nudgeBox(_ press: KeyPress) -> KeyPress.Result {
    guard
      case .nudgeLength(let delta) = ShaarElementsShortcuts.action(
        for: ShaarElementsKeyPress(press), context: .lengthField
      ), let next = ShaarCSSLength.nudged(draft, caret: (draft as NSString).length, by: delta)
    else { return .ignored }
    draft = next
    return .handled
  }

  private func tip(region: String, index: Int, raw: String) -> String {
    let side = ["top", "right", "bottom", "left"][index]
    return InspectorL10n.format(
      "%@ %@: %@",
      arguments: [
        .string(InspectorL10n.string(region.capitalized)),
        .string(InspectorL10n.string(side.capitalized)), .string(raw),
      ])
  }

  static func edgeAccessibilityLabel(region: String, index: Int) -> String {
    if region == "content" {
      let dimension = InspectorL10n.string(index == 0 ? "Width" : "Height")
      return InspectorL10n.format("Edit %@", arguments: [.string(dimension)])
    }
    let side = ["top", "right", "bottom", "left"][index]
    return InspectorL10n.format(
      "Edit %@ %@",
      arguments: [
        .string(InspectorL10n.string(region.capitalized)),
        .string(InspectorL10n.string(side.capitalized)),
      ])
  }

  static func editorAccessibilityLabel(region: String, index: Int) -> String {
    guard region == "content" else { return edgeAccessibilityLabel(region: region, index: index) }
    return InspectorL10n.format(
      "Edit %@", arguments: [.string(InspectorL10n.string(index == 0 ? "Width" : "Height"))])
  }

  private func hover(_ key: String, region: String, index: Int, active: Bool) {
    if active { hovered = key } else if hovered == key { hovered = nil }
    guard region != "content" else { return }
    highlight?(region, index, active)
  }

  private func beginEditing(_ raw: String, region: String, index: Int) {
    highlight?(region, index, false)
    hovered = nil
    cancelRequested = false
    committed = false
    wantsFocus = true
    draft = InspectorBoxEdit.draft(raw)
    editing = region + String(index)
    fieldFocused = true
  }

  private func commitEditing() {
    guard let key = editing else { return }
    let typed = draft
    apply(key: key, typed: typed)
  }

  private func cancelEditing() {
    cancelRequested = true
    editing = nil
    draft = ""
    fieldFocused = false
  }

  private func apply(key: String, typed: String) {
    if editing == key {
      editing = nil
      draft = ""
    }
    guard !committed else { return }
    committed = true
    guard let edit, let change = InspectorBoxEdit.submission(edge: key, typed: typed, box: box)
    else { return }
    edit(change.property, change.value)
  }
}
