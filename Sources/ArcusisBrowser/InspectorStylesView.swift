// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

struct InspectorStylesView: View {
  @Bindable var inspector: InspectorModel
  @Bindable var model: InspectorStylesModel
  @State private var property = ""
  @State private var value = ""
  @State private var important = false
  @State private var expanded: Set<Int> = [0]
  @State private var draftRule: Int?
  @State private var draftKey = ""
  @State private var draftName = ""
  @State private var draftValue = ""
  @State private var draftImportant = false
  @State private var addingRule: Int?
  @State private var addedName = ""
  @State private var addedValue = ""
  @State private var showNewRule = false
  @State private var newSelector = ""
  @State private var showComputed: Bool

  static func declarationToggleAccessibilityLabel(for declaration: InspectorDeclaration) -> String {
    declaration.name
  }

  static var matchedRulesLoadingAccessibilityLabel: String {
    InspectorL10n.string("Reading styles…")
  }

  init(inspector: InspectorModel, model: InspectorStylesModel) {
    self.inspector = inspector
    self.model = model
    // Offscreen evidence opens the list. The dock leaves it collapsed.
    let capture = ProcessInfo.processInfo.environment["SHAAR_COMPUTED_CAPTURE"] != nil
    _showComputed = State(initialValue: capture)
  }

  var body: some View {
    ScrollViewReader { proxy in
      ScrollView {
        VStack(spacing: 0) {
          if inspector.selection?.locked == true {
            InspectorPseudoForceControls(forced: model.forcedPseudos) { name in
              Task { await model.togglePseudo(name) }
            }
            if model.selectedID == inspector.selection?.id {
              InspectorSection(
                InspectorL10n.string("Styles"), id: "Styles",
                copy: { inspector.copy(model.css, label: "CSS") },
                code: model.css
              ) {
                VStack(spacing: 2) {
                  ForEach(model.exported) { row in
                    InspectorProperty(row.name, value: row.value, copy: inspector.copy)
                  }
                }
              }
              InspectorSection(
                InspectorL10n.string("Layout"), id: "Layout",
                copy: { inspector.copy(layoutCSS, label: "layout") },
                code: layoutCSS
              ) {
                VStack(spacing: 2) {
                  ForEach(model.layout) { row in
                    InspectorProperty(row.name, value: row.value, copy: inspector.copy)
                  }
                  if model.canOverlay {
                    Toggle(
                      InspectorL10n.format(
                        "Show %@ overlay",
                        arguments: [
                          .string(
                            InspectorL10n.string(
                              model.layout.first?.value.contains("grid") == true ? "grid" : "flex"))
                        ]),
                      isOn: Binding(
                        get: { model.overlay },
                        set: { _ in Task { await model.toggleOverlay() } }
                      )
                    )
                    .toggleStyle(.checkbox).font(.system(size: 11)).padding(.top, 8)
                  }
                }
              }
              InspectorSection(InspectorL10n.string("Element overrides"), id: "Element overrides") {
                VStack(alignment: .leading, spacing: 9) {
                  HStack(spacing: 6) {
                    TextField(InspectorL10n.string("property"), text: $property)
                      .frame(width: 104).accessibilityLabel(InspectorL10n.string("CSS property"))
                      .environment(\.layoutDirection, .leftToRight)
                    Text(":").foregroundStyle(.secondary)
                    TextField(InspectorL10n.string("value"), text: $value).accessibilityLabel(
                      InspectorL10n.string("CSS value")
                    )
                    .environment(\.layoutDirection, .leftToRight)
                  }.environment(\.layoutDirection, .leftToRight)
                    .font(.system(size: 11, design: .monospaced)).textFieldStyle(.roundedBorder)
                    .onSubmit(apply)
                  HStack {
                    Toggle("!important", isOn: $important).toggleStyle(.checkbox)
                      .font(.system(size: 11, design: .monospaced))
                    Spacer()
                    Button(InspectorL10n.string("Undo"), systemImage: "arrow.uturn.backward") {
                      Task { await model.undo() }
                    }
                    .disabled(model.undoDepth == 0 || model.busy)
                    Button(InspectorL10n.string("Apply"), action: apply).disabled(
                      property.isEmpty || model.busy)
                  }.controlSize(.small).font(.system(size: 11))
                  InspectorL10n.text(
                    "Applies to this element until reload. Empty value removes the override."
                  )
                  .font(.system(size: 10)).foregroundStyle(.secondary)
                }
              }
              InspectorSection(
                InspectorL10n.string("Matched rules"), id: "Matched rules",
                copy: { inspector.copy(matchedCSS, label: "matched rules") },
                code: matchedCSS
              ) {
                VStack(alignment: .leading, spacing: 12) {
                  if model.busy && model.rules.isEmpty {
                    ProgressView().controlSize(.small)
                      .accessibilityLabel(Self.matchedRulesLoadingAccessibilityLabel)
                      .frame(maxWidth: .infinity)
                  }
                  newRuleControl
                  ForEach(model.rules) { rule in
                    DisclosureGroup(
                      isExpanded: Binding(
                        get: { expanded.contains(rule.id) },
                        set: {
                          if $0 { expanded.insert(rule.id) } else { expanded.remove(rule.id) }
                        }
                      )
                    ) {
                      VStack(alignment: .leading, spacing: 2) {
                        ForEach(rule.declarations) { declaration in
                          declarationRow(rule, declaration)
                        }
                        if rule.editable { addPropertyRow(rule) }
                      }.padding(.leading, 2).padding(.top, 5)
                    } label: {
                      VStack(alignment: .leading, spacing: 4) {
                        Text(rule.selector).font(
                          .system(size: 11, weight: .medium, design: .monospaced)
                        )
                        .lineLimit(3).fixedSize(horizontal: false, vertical: true)
                        .environment(\.layoutDirection, .leftToRight)
                        if let caption = ruleCaption(rule) {
                          Text(caption).font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                        Text(sourceLabel(rule.source)).font(.system(size: 10)).foregroundStyle(
                          .secondary
                        )
                        .lineLimit(1).truncationMode(.middle).help(
                          InspectorL10n.display(rule.source)
                        )
                        .environment(\.layoutDirection, .leftToRight)
                      }
                    }.tint(.secondary).id("matched-rule-\(rule.id)")
                  }
                  InspectorL10n.text(
                    "Matched declarations include cascade candidates. Computed values show the final result."
                  )
                  .font(.system(size: 10)).foregroundStyle(.secondary)
                }
              }
              InspectorSection(
                InspectorL10n.string("Computed values"), id: "Computed values",
                copy: { inspector.copy(model.css, label: "CSS") }, code: model.css
              ) {
                computedProperties(proxy)
              }
              InspectorSection(InspectorL10n.string("Tools"), id: "Tools") {
                VStack(alignment: .leading, spacing: 10) {
                  Button(InspectorL10n.string("Save element at 2×"), systemImage: "camera") {
                    Task { await model.saveScreenshot() }
                  }.controlSize(.small).font(.system(size: 11))
                  Label(
                    InspectorL10n.string("Hold Option over another element to measure."),
                    systemImage: "ruler"
                  )
                  .font(.system(size: 11)).foregroundStyle(.secondary)
                  .help(
                    InspectorL10n.string(
                      "Shows horizontal and vertical gaps; overlapping elements show leading-edge offsets."
                    )
                  )
                }
              }
            } else {
              ProgressView(InspectorL10n.string("Reading styles…")).controlSize(.small).font(
                .system(size: 11)
              ).padding(24)
            }
          } else {
            InspectorL10n.text("Click an element to lock its styles.")
              .font(.system(size: 12)).foregroundStyle(.secondary).padding(24)
          }
          if let failure = model.failure {
            Text(InspectorL10n.display(failure)).font(.system(size: 11)).foregroundStyle(.secondary)
              .frame(maxWidth: .infinity, alignment: .leading).padding(12)
          }
        }
      }
      .scrollBounceBehavior(.basedOnSize)
      .task(id: inspector.documentGeneration) {
        while !Task.isCancelled {
          await model.refresh()
          do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
        }
      }
    }
  }

  private func apply() {
    Task {
      await model.edit(
        property: property.trimmingCharacters(in: .whitespacesAndNewlines), value: value,
        important: important)
    }
  }

  @ViewBuilder private var newRuleControl: some View {
    if showNewRule {
      VStack(alignment: .leading, spacing: 6) {
        TextField(InspectorL10n.string("Selector"), text: $newSelector)
          .accessibilityLabel(InspectorL10n.string("CSS selector"))
          .textFieldStyle(.roundedBorder)
          .font(.system(size: 11, design: .monospaced))
          .environment(\.layoutDirection, .leftToRight)
          .onSubmit(commitNewRule)
        HStack {
          Button(InspectorL10n.string("Cancel"), role: .cancel) {
            showNewRule = false
            newSelector = ""
          }
          .keyboardShortcut(.cancelAction)
          Spacer()
          Button(InspectorL10n.string("Apply"), action: commitNewRule)
            .disabled(trimmed(newSelector).isEmpty || model.busy)
        }
      }.controlSize(.small).font(.system(size: 11))
    } else {
      Button(InspectorL10n.string("New rule")) {
        newSelector = inspector.selection?.css ?? ""
        showNewRule = true
      }
      .controlSize(.small).font(.system(size: 11))
    }
  }

  private func declarationRow(
    _ rule: InspectorRule, _ declaration: InspectorDeclaration
  ) -> some View {
    VStack(alignment: .leading, spacing: 1) {
      if isDraft(rule, declaration) {
        draftFields(rule, declaration)
      } else if rule.editable {
        editableDeclaration(rule, declaration)
      } else {
        overrideDeclaration(declaration)
      }
      if let reason = model.inactiveHints[declaration.name.lowercased()],
        !isDraft(rule, declaration)
      {
        InspectorInactiveCSSHint(reason: reason)
      }
    }
  }

  private func editableDeclaration(
    _ rule: InspectorRule, _ declaration: InspectorDeclaration
  ) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 4) {
      Toggle(
        "",
        isOn: Binding(
          get: { !declaration.disabled },
          set: { enabled in
            Task { await model.setDeclaration(rule, declaration, enabled: enabled) }
          }
        )
      )
      .toggleStyle(.checkbox).labelsHidden().disabled(model.busy)
      .accessibilityLabel(Self.declarationToggleAccessibilityLabel(for: declaration))
      if declaration.disabled {
        declarationLabel(declaration)
      } else {
        Button {
          beginDraft(rule, declaration)
        } label: {
          declarationLabel(declaration)
        }.buttonStyle(.plain)
      }
    }
  }

  private func overrideDeclaration(_ declaration: InspectorDeclaration) -> some View {
    Button {
      property = declaration.name
      important = declaration.important
      value = declaration.plainValue
    } label: {
      declarationLabel(declaration)
    }.buttonStyle(.plain).help(
      InspectorL10n.format(
        "Override %@ on this element", arguments: [.string(declaration.name)])
    )
  }

  private func declarationLabel(_ declaration: InspectorDeclaration) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 4) {
      Text(declaration.name + ":")
        .foregroundStyle(declaration.disabled ? .tertiary : .secondary)
        .strikethrough(declaration.disabled)
      Text(declaration.value)
        .foregroundStyle(declaration.disabled ? .tertiary : .primary)
        .strikethrough(declaration.disabled)
      Spacer(minLength: 0)
    }
    .environment(\.layoutDirection, .leftToRight)
    .font(.system(size: 11, design: .monospaced))
    .multilineTextAlignment(.leading)
    .padding(.vertical, 3)
    .contentShape(Rectangle())
  }

  private func draftFields(
    _ rule: InspectorRule, _ declaration: InspectorDeclaration
  ) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 6) {
        TextField(InspectorL10n.string("property"), text: $draftName)
          .frame(width: 104)
          .accessibilityLabel(InspectorL10n.string("CSS property"))
        Text(":").foregroundStyle(.secondary)
        TextField(InspectorL10n.string("value"), text: $draftValue)
          .accessibilityLabel(InspectorL10n.string("CSS value"))
      }
      .environment(\.layoutDirection, .leftToRight)
      .font(.system(size: 11, design: .monospaced))
      .textFieldStyle(.roundedBorder)
      .onSubmit { commitDraft(rule, declaration) }
      HStack {
        Toggle("!important", isOn: $draftImportant).toggleStyle(.checkbox)
          .font(.system(size: 11, design: .monospaced))
        Spacer()
        Button(InspectorL10n.string("Cancel"), role: .cancel) { clearDraft() }
          .keyboardShortcut(.cancelAction)
        Button(InspectorL10n.string("Apply")) { commitDraft(rule, declaration) }
          .disabled(trimmed(draftName).isEmpty || model.busy)
      }.controlSize(.small).font(.system(size: 11))
    }
  }

  @ViewBuilder private func addPropertyRow(_ rule: InspectorRule) -> some View {
    if addingRule == rule.id {
      VStack(alignment: .leading, spacing: 6) {
        HStack(spacing: 6) {
          TextField(InspectorL10n.string("property"), text: $addedName)
            .frame(width: 104)
            .accessibilityLabel(InspectorL10n.string("CSS property"))
          Text(":").foregroundStyle(.secondary)
          TextField(InspectorL10n.string("value"), text: $addedValue)
            .accessibilityLabel(InspectorL10n.string("CSS value"))
        }
        .environment(\.layoutDirection, .leftToRight)
        .font(.system(size: 11, design: .monospaced))
        .textFieldStyle(.roundedBorder)
        .onSubmit { commitAddedProperty(rule) }
        HStack {
          Button(InspectorL10n.string("Cancel"), role: .cancel) { clearAddedProperty() }
            .keyboardShortcut(.cancelAction)
          Spacer()
          Button(InspectorL10n.string("Apply")) { commitAddedProperty(rule) }
            .disabled(trimmed(addedName).isEmpty || trimmed(addedValue).isEmpty || model.busy)
        }.controlSize(.small).font(.system(size: 11))
      }
    } else {
      Button(InspectorL10n.string("Add property")) {
        addedName = ""
        addedValue = ""
        addingRule = rule.id
      }
      .controlSize(.small).font(.system(size: 11)).disabled(model.busy)
    }
  }

  private func ruleCaption(_ rule: InspectorRule) -> String? {
    if rule.note == "Inherited" { return InspectorL10n.string("Inherited") }
    guard rule.note.hasPrefix("::") else { return nil }
    let name = String(rule.note.dropFirst(2))
    guard !name.isEmpty else { return nil }
    return InspectorL10n.format("Pseudo-element %@", arguments: [.string(name)])
  }

  private func isDraft(_ rule: InspectorRule, _ declaration: InspectorDeclaration) -> Bool {
    draftRule == rule.id && draftKey == declaration.id
  }

  private func beginDraft(_ rule: InspectorRule, _ declaration: InspectorDeclaration) {
    draftRule = rule.id
    draftKey = declaration.id
    draftName = declaration.name
    draftValue = declaration.plainValue
    draftImportant = declaration.important
  }

  private func clearDraft() {
    draftRule = nil
    draftKey = ""
    draftName = ""
    draftValue = ""
    draftImportant = false
  }

  private func commitDraft(_ rule: InspectorRule, _ declaration: InspectorDeclaration) {
    let name = trimmed(draftName)
    guard !name.isEmpty else { return }
    let replacing = name == declaration.name ? nil : declaration.name
    let nextValue = draftValue
    let nextImportant = draftImportant
    clearDraft()
    Task {
      await model.editRule(
        rule, property: name, value: nextValue, important: nextImportant, replacing: replacing)
    }
  }

  private func commitNewRule() {
    let selector = trimmed(newSelector)
    guard !selector.isEmpty else { return }
    showNewRule = false
    newSelector = ""
    Task { await model.addRule(selector: selector) }
  }

  private func commitAddedProperty(_ rule: InspectorRule) {
    let name = trimmed(addedName)
    let nextValue = trimmed(addedValue)
    guard !name.isEmpty, !nextValue.isEmpty else { return }
    clearAddedProperty()
    Task { await model.editRule(rule, property: name, value: nextValue, important: false) }
  }

  private func clearAddedProperty() {
    addingRule = nil
    addedName = ""
    addedValue = ""
  }

  private func trimmed(_ text: String) -> String {
    text.trimmingCharacters(in: .whitespacesAndNewlines)
  }
  private func editBox(property: String, value: String) {
    Task { await model.edit(property: property, value: value, important: false) }
  }

  private func computedProperties(_ proxy: ScrollViewProxy) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      if let box = inspector.selection?.box {
        InspectorBoxModel(box: box, edit: editBox) { region, index, active in
          inspector.highlightEdge(region, index, active: active)
        }
      }
      HStack {
        Button(InspectorL10n.string("Copy CSS"), systemImage: "doc.on.doc") {
          inspector.copy(model.css)
        }
        .help(InspectorL10n.string("Copy a computed CSS snapshot"))
        Button(InspectorL10n.string("Tailwind")) { inspector.copy(model.tailwind) }
          .help(
            InspectorL10n.string(
              "Copy computed styles as Tailwind arbitrary-property utilities"))
        Spacer()
      }.controlSize(.small).font(.system(size: 11)).disabled(model.computed.isEmpty)
      DisclosureGroup(
        InspectorL10n.string("All computed properties"), isExpanded: $showComputed
      ) {
        VStack(alignment: .leading, spacing: 3) {
          TextField(InspectorL10n.string("Filter properties"), text: $model.filter)
            .accessibilityLabel(InspectorL10n.string("Filter properties"))
            .accessibilityIdentifier("shaar.devtools.computedFilter")
            .textFieldStyle(.roundedBorder).font(.system(size: 11)).padding(.vertical, 6)
          ForEach(visibleComputed) { row in
            computedRow(row, proxy: proxy)
          }
        }
      }.font(.system(size: 11))
    }
  }

  private var visibleComputed: [InspectorDeclaration] {
    model.computed.filter { row in
      model.filter.isEmpty
        || row.name.localizedCaseInsensitiveContains(model.filter)
        || row.value.localizedCaseInsensitiveContains(model.filter)
    }
  }

  private func computedRow(_ row: InspectorDeclaration, proxy: ScrollViewProxy) -> some View {
    VStack(alignment: .leading, spacing: 1) {
      InspectorProperty(row.name, value: row.value, copy: inspector.copy)
      if let trace = InspectorCascade.trace(for: row.name, rules: model.rules) {
        winningRule(trace, proxy: proxy)
      }
    }
  }

  private func winningRule(_ trace: InspectorCascade.Trace, proxy: ScrollViewProxy) -> some View {
    Button {
      expanded.insert(trace.ruleID)
      proxy.scrollTo("matched-rule-\(trace.ruleID)", anchor: .top)
    } label: {
      VStack(alignment: .leading, spacing: 1) {
        Text(trace.selector).font(.system(size: 10, weight: .medium, design: .monospaced))
          .lineLimit(1).environment(\.layoutDirection, .leftToRight)
        Text(sourceLabel(trace.source)).font(.system(size: 10)).foregroundStyle(.secondary)
          .lineLimit(1).truncationMode(.middle).environment(\.layoutDirection, .leftToRight)
      }.frame(maxWidth: .infinity, alignment: .leading)
    }
    .buttonStyle(.plain).padding(.leading, 2).padding(.bottom, 4)
    .accessibilityLabel(InspectorL10n.string("Show the winning rule"))
    .help(InspectorL10n.string("Show the winning rule"))
  }

  private func sourceLabel(_ source: String) -> String {
    if source.hasPrefix("Stylesheet ") {
      return InspectorL10n.format(
        "Stylesheet %@", arguments: [.string(String(source.dropFirst(11)))])
    }
    if ["Inline overrides", "Browser default", "Source unavailable"].contains(source) {
      return InspectorL10n.display(source)
    }
    guard source.contains("://") else { return source }
    return source.components(separatedBy: "/").last ?? source
  }

  private var layoutCSS: String {
    model.layout.map { "\($0.name): \($0.value);" }.joined(separator: "\n")
  }
  private var matchedCSS: String {
    model.rules.map { rule in
      let source = rule.source.replacingOccurrences(of: "*/", with: "* /")
      return (source.isEmpty ? "" : "/* \(source) */\n") + rule.selector + " {\n"
        + rule.declarations.map { "  \($0.name): \($0.value);" }.joined(separator: "\n") + "\n}"
    }.joined(separator: "\n\n")
  }
}
