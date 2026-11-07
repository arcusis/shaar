// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import ShaarEngineABI
import SwiftUI
import UniformTypeIdentifiers

private enum DOMEditor: String, Identifiable {
  case attribute
  case text
  case html
  var id: String { rawValue }
}

struct ShaarDOMTreePanel: View {
  @Bindable var model: ShaarDOMTreeModel
  @Bindable var listeners: ShaarEventListenersModel
  let inspector: InspectorModel
  let openChromium: () -> Void

  init(
    model: ShaarDOMTreeModel, inspector: InspectorModel, openChromium: @escaping () -> Void,
    listeners: ShaarEventListenersModel? = nil,
    dropPreview: ShaarDOMDropPreview? = nil
  ) {
    self.model = model
    self.inspector = inspector
    self.openChromium = openChromium
    self.listeners =
      listeners
      ?? ShaarEventListenersModel(
        target: model.target, transport: ShaarEventListenersPendingTransport())
    _dropPreview = State(initialValue: dropPreview)
  }
  @State private var dropPreview: ShaarDOMDropPreview?
  @State private var editor: DOMEditor?
  @State private var attributeName = ""
  @State private var editorValue = ""
  @State private var deleting = false
  @FocusState private var focusedNode: Int?
  @FocusState private var searchFieldFocused: Bool
  @Environment(\.colorSchemeContrast) private var colorSchemeContrast

  var body: some View {
    GeometryReader { geometry in
      if geometry.size.width >= 680 {
        HStack(spacing: 0) {
          tree.frame(width: max(300, geometry.size.width * 0.44))
          Divider()
          InspectorPanel(model: inspector)
        }
      } else {
        VStack(spacing: 0) {
          tree.frame(height: max(190, geometry.size.height * 0.55))
          Divider()
          InspectorPanel(model: inspector)
        }
      }
    }
    .sheet(item: $editor) { mode in editorSheet(mode) }
    .confirmationDialog(
      ShellL10n.string("Delete selected node?"), isPresented: $deleting
    ) {
      Button(ShellL10n.string("Delete"), role: .destructive) {
        Task { await model.removeSelected() }
      }
    }
    .onChange(of: inspector.selection?.id) { _, _ in
      syncInspectorSelection()
    }
    .onChange(of: model.rootID) { _, _ in syncInspectorSelection() }
    .accessibilityIdentifier("shaar.devtools.domTree")
  }

  private func syncInspectorSelection() {
    Task {
      if let id = await inspector.currentDOMNodeID() { model.select(id) }
    }
  }

  private var tree: some View {
    VStack(spacing: 0) {
      header
      Divider()
      if !model.available {
        VStack(spacing: 9) {
          Image(systemName: "point.3.connected.trianglepath.dotted")
            .font(.system(size: 22, weight: .ultraLight)).foregroundStyle(.primary)
          Text(ShellL10n.string("Live DOM tree is unavailable for this tab"))
            .font(.system(size: 12, weight: .medium))
          Button(ShellL10n.string("Open Chromium DevTools"), action: openChromium)
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("shaar.devtools.domUnavailable")
      } else if model.loading && model.rows.isEmpty {
        ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if let failure = model.failure, model.rows.isEmpty {
        Text(failure).font(.system(size: 11)).foregroundStyle(.primary)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ScrollView {
          LazyVStack(spacing: 0) {
            ForEach(model.rows) { row in treeRow(row) }
          }
        }
        .devToolsDataDirection()
      }
      Divider()
      ShaarEventListenersPane(model: listeners)
        .frame(height: 220)
      Divider()
      breadcrumbs
      if let selected = model.selected, selected.nodeType == 1 {
        classControls(selected)
      }
    }
    .background(Color(nsColor: .windowBackgroundColor))
    .onMoveCommand(perform: moveSelection)
    .onDeleteCommand { if model.selectedID != nil { deleting = true } }
    .onChange(of: listenerChainKey, initial: true) { _, _ in
      let ancestors = ShaarEventListenerAncestors.chain(from: model.selectedID, nodes: model.nodes)
      Task { await listeners.load(nodeID: model.selectedID, ancestors: ancestors) }
    }
  }

  private var listenerChainKey: String {
    let chain = ShaarEventListenerAncestors.chain(from: model.selectedID, nodes: model.nodes)
    let ids = [model.selectedID].compactMap { $0 } + chain
    return ids.map(String.init).joined(separator: "/")
  }

  private var header: some View {
    HStack(spacing: 7) {
      Image(systemName: "point.3.connected.trianglepath.dotted")
        .font(.system(size: 12)).foregroundStyle(.primary)
      Text(ShellL10n.string("DOM tree"))
        .font(.system(size: 11, weight: .semibold))
      TextField(ShellL10n.string("Search text or selector"), text: $model.search)
        .textFieldStyle(.roundedBorder)
        .font(.system(size: 11))
        .devToolsDataDirection()
        .focused($searchFieldFocused)
        .onSubmit { Task { await model.performSearch() } }
        .help(ShellL10n.string("Search the DOM and press Return to apply the search"))
        .onExitCommand { model.search = "" }
      if let label = model.matchCountLabel {
        Text(label)
          .font(.system(size: 10, design: .monospaced))
          .foregroundStyle(.primary)
          .lineLimit(1)
          .fixedSize()
          .accessibilityIdentifier("shaar.devtools.domMatchCount")
      }
      Button {
        Task { await model.stepSearchMatch(forward: false) }
      } label: {
        Image(systemName: "chevron.up")
      }
      .disabled(model.matchOrder.isEmpty)
      .help(ShellL10n.string("Previous match"))
      .accessibilityLabel(ShellL10n.string("Previous match"))
      Button {
        Task { await model.stepSearchMatch(forward: true) }
      } label: {
        Image(systemName: "chevron.down")
      }
      .disabled(model.matchOrder.isEmpty)
      .help(ShellL10n.string("Next match"))
      .accessibilityLabel(ShellL10n.string("Next match"))
      Button {
        Task { await model.performSearch() }
      } label: {
        Image(systemName: "magnifyingglass")
      }
      .help(ShellL10n.string("Find in DOM"))
      .accessibilityLabel(ShellL10n.string("Find in DOM"))
      Button {
        Task { await model.loadDocument() }
      } label: {
        Image(systemName: "arrow.clockwise")
      }
      .help(ShellL10n.string("Refresh DOM tree"))
      .accessibilityLabel(ShellL10n.string("Refresh DOM tree"))
      Button {
        Task { await model.undo() }
      } label: {
        Image(systemName: "arrow.uturn.backward")
      }
      .disabled(!model.canUndo)
      .help(ShellL10n.string("Undo DOM edit with Command-Z"))
      .accessibilityLabel(ShellL10n.string("Undo DOM edit"))
      .keyboardShortcut("z", modifiers: .command)
    }
    .buttonStyle(.plain)
    .controlSize(.small)
    .padding(.horizontal, 10)
    .frame(height: 36)
    .background {
      Button {
        searchFieldFocused = true
      } label: {
        Color.clear
      }
      .keyboardShortcut("f", modifiers: .command)
      .frame(width: 0, height: 0)
      .accessibilityHidden(true)
    }
  }

  private func treeRow(_ row: ShaarDOMRow) -> some View {
    HStack(spacing: 5) {
      if row.node.canExpand {
        Button {
          Task { await model.toggleExpanded(row.id) }
        } label: {
          Image(systemName: model.expanded.contains(row.id) ? "chevron.down" : "chevron.right")
            .font(.system(size: 9, weight: .semibold))
            .frame(width: 14, height: 20)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
          ShellL10n.string(model.expanded.contains(row.id) ? "Collapse node" : "Expand node"))
      } else {
        Color.clear.frame(width: 14, height: 20)
      }
      Button {
        model.select(row.id)
        focusedNode = row.id
        Task { try? await inspector.selectDOMNode(row.id) }
      } label: {
        HStack(spacing: 5) {
          Text(nodeLabel(row.node))
            .foregroundStyle(.primary)
          if !row.node.attributeSummary.isEmpty {
            Text(row.node.attributeSummary).foregroundStyle(.primary)
          }
          Spacer(minLength: 0)
          if model.matches.contains(row.id) {
            Image(systemName: "magnifyingglass.circle.fill").foregroundStyle(.primary)
          }
        }
        .lineLimit(1)
        .font(.system(size: 10, design: .monospaced))
        .frame(height: ShaarDOMDrop.rowHeight)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .focusable()
      .focused($focusedNode, equals: row.id)
      .accessibilityLabel(rowAccessibilityLabel(row))
      .accessibilityValue(model.selectedID == row.id ? ShellL10n.string("Selected") : "")
      .accessibilityAddTraits(model.selectedID == row.id ? .isSelected : [])
    }
    .padding(.leading, CGFloat(row.depth) * 15 + 8)
    .padding(.trailing, 8)
    .background(
      model.selectedID == row.id
        ? Color.accentColor.opacity(colorSchemeContrast == .increased ? 0.22 : 0.12)
        : .clear
    )
    .overlay {
      if focusedNode == row.id {
        RoundedRectangle(cornerRadius: 3)
          .strokeBorder(
            Color.primary, lineWidth: colorSchemeContrast == .increased ? 2 : 1)
      }
    }
    .overlay(alignment: .top) { dropLine(row) }
    .overlay { dropInside(row) }
    .onHover { hovering in Task { await model.highlight(hovering ? row.id : nil) } }
    .contextMenu { rowMenu(row.node) }
    .onDrag { NSItemProvider(object: String(row.id) as NSString) }
    .onDrop(
      of: [UTType.plainText],
      delegate: ShaarDOMRowDropDelegate(
        row: row.node, nodes: model.nodes, preview: $dropPreview,
        move: { id, parent, before in
          Task { await model.move(id, to: parent, before: before) }
        })
    )
    .accessibilityHint(dropAccessibilityHint(row))
    .accessibilityIdentifier("shaar.devtools.domRow")
  }

  @ViewBuilder private func dropLine(_ row: ShaarDOMRow) -> some View {
    if dropPreview == ShaarDOMDropPreview(rowID: row.id, kind: .before) {
      Rectangle()
        .fill(Color.accentColor)
        .frame(height: 2)
        .accessibilityIdentifier("shaar.devtools.domDrop.before")
    }
  }

  @ViewBuilder private func dropInside(_ row: ShaarDOMRow) -> some View {
    if dropPreview == ShaarDOMDropPreview(rowID: row.id, kind: .inside) {
      RoundedRectangle(cornerRadius: 3)
        .strokeBorder(Color.accentColor, lineWidth: 2)
        .accessibilityIdentifier("shaar.devtools.domDrop.inside")
    }
  }

  private func dropAccessibilityHint(_ row: ShaarDOMRow) -> String {
    guard let dropPreview, dropPreview.rowID == row.id else { return "" }
    if dropPreview.kind == .inside { return ShellL10n.string("Drop inside") }
    return ShellL10n.string("Drop before")
  }

  private func nodeLabel(_ node: ShaarDOMNode) -> String {
    if node.relation == .shadowRoot { return "#shadow-root" }
    if node.relation == .frameDocument { return "#frame-document" }
    if node.nodeType == 1 { return "<\(node.name.lowercased())>" }
    if node.nodeType == 3 { return "\"\(node.value.prefix(100))\"" }
    return node.name
  }

  @ViewBuilder private func rowMenu(_ node: ShaarDOMNode) -> some View {
    Button(ShellL10n.string("Copy element")) {
      Task { if let html = await model.outerHTML(for: node.id) { copy(html) } }
    }
    Button(ShellL10n.string("Copy selector")) {
      Task { copy(await copiedPath(for: node.id).css) }
    }
    Button(ShellL10n.string("Copy XPath")) {
      Task { copy(await copiedPath(for: node.id).xpath) }
    }
    Button(ShellL10n.string("Copy Playwright locator")) {
      Task {
        let selector = await copiedPath(for: node.id).css
        guard !selector.isEmpty else { return }
        let encoded = try? JSONEncoder().encode(selector)
        let quoted = encoded.flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
        copy("page.locator(\(quoted))")
      }
    }
    Button(ShellL10n.string("Copy for agent")) {
      Task {
        if (try? await inspector.selectDOMNode(node.id)) != nil {
          await inspector.aiCopy.copyElement()
        }
      }
    }
    Divider()
    Button(ShellL10n.string("Edit attribute…")) {
      model.select(node.id)
      attributeName = ""
      editorValue = ""
      editor = .attribute
    }
    Button(ShellL10n.string("Edit text…")) {
      model.select(node.id)
      editorValue = node.value
      editor = .text
    }
    Button(ShellL10n.string("Edit as HTML…")) {
      model.select(node.id)
      Task {
        editorValue = await model.outerHTML(for: node.id) ?? ""
        editor = .html
      }
    }
    Divider()
    Button(ShellL10n.string("Delete node"), role: .destructive) {
      model.select(node.id)
      deleting = true
    }
  }

  private var breadcrumbs: some View {
    ScrollView(.horizontal) {
      HStack(spacing: 4) {
        ForEach(model.breadcrumbs) { node in
          Button(nodeLabel(node)) {
            model.select(node.id)
            Task { try? await inspector.selectDOMNode(node.id) }
          }
          .buttonStyle(.plain)
          .foregroundStyle(.primary)
          if node.id != model.selectedID {
            Image(systemName: "chevron.right").font(.system(size: 7))
              .foregroundStyle(.primary)
          }
        }
      }
      .font(.system(size: 10, design: .monospaced))
      .padding(.horizontal, 10)
    }
    .frame(height: 29)
  }

  private func classControls(_ node: ShaarDOMNode) -> some View {
    let classes =
      node.attributes.first { $0.name == "class" }?
      .value.split(whereSeparator: \.isWhitespace).map(String.init) ?? []
    return ScrollView(.horizontal) {
      HStack(spacing: 5) {
        Text(ShellL10n.string("Classes"))
          .foregroundStyle(.primary)
        ForEach(classes, id: \.self) { name in
          Button {
            Task { await model.toggleClass(name) }
          } label: {
            Label(name, systemImage: "checkmark.square.fill")
              .font(.system(size: 10, design: .monospaced))
          }
          .buttonStyle(.plain)
          .help(ShellL10n.string("Toggle class"))
        }
      }
      .padding(.horizontal, 10)
    }
    .frame(height: 30)
  }

  private func editorSheet(_ mode: DOMEditor) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(ShellL10n.string(editorTitle(mode))).font(.headline)
      if mode == .attribute {
        TextField(ShellL10n.string("Attribute name"), text: $attributeName)
          .devToolsDataDirection()
      }
      if mode == .html {
        TextEditor(text: $editorValue).font(.system(size: 11, design: .monospaced))
          .devToolsDataDirection()
          .frame(height: 180)
          .accessibilityLabel(ShellL10n.string(editorTitle(mode)))
      } else {
        TextField(ShellL10n.string("Value"), text: $editorValue)
          .devToolsDataDirection()
      }
      HStack {
        Spacer()
        Button(ShellL10n.string("Cancel")) { editor = nil }
        Button(ShellL10n.string("Save")) {
          let name = attributeName
          let value = editorValue
          editor = nil
          Task {
            switch mode {
            case .attribute: await model.setAttribute(name, value: value)
            case .text: await model.setText(value)
            case .html: await model.setHTML(value)
            }
          }
        }
      }
    }
    .padding(18)
    .frame(width: 440)
  }

  private func editorTitle(_ mode: DOMEditor) -> String {
    switch mode {
    case .attribute: "Edit attribute"
    case .text: "Edit text"
    case .html: "Edit as HTML"
    }
  }

  private func moveSelection(_ direction: MoveCommandDirection) {
    let rows = model.rows
    guard focusedNode != nil, !rows.isEmpty else { return }
    let index =
      rows.firstIndex { $0.id == focusedNode }
      ?? rows.firstIndex { $0.id == model.selectedID }
      ?? 0
    switch direction {
    case .up: model.select(rows[max(0, index - 1)].id)
    case .down: model.select(rows[min(rows.count - 1, index + 1)].id)
    case .left:
      if model.expanded.contains(rows[index].id) {
        Task { await model.toggleExpanded(rows[index].id) }
      } else if let parent = rows[index].node.parentID {
        model.select(parent)
      }
    case .right:
      if !model.expanded.contains(rows[index].id) {
        Task { await model.toggleExpanded(rows[index].id) }
      }
    default: break
    }
    focusedNode = model.selectedID
  }

  private func rowAccessibilityLabel(_ row: ShaarDOMRow) -> String {
    [nodeLabel(row.node), row.node.attributeSummary]
      .filter { !$0.isEmpty }
      .joined(separator: ", ")
  }

  private func copiedPath(for id: Int) async -> (css: String, xpath: String) {
    if let live = await inspector.pathsForDOMNode(id) { return live }
    await model.prepareCopyPath(for: id)
    return (model.selector(for: id), model.xpath(for: id))
  }

  private func copy(_ value: String) {
    guard !value.isEmpty else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(value, forType: .string)
  }
}

extension InspectorModel {
  func currentDOMNodeID() async -> Int? {
    try? await withSelectedNode { $0 }
  }
}
