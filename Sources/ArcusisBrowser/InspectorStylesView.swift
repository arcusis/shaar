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
  @State private var showComputed = false

  var body: some View {
    ScrollView {
      VStack(spacing: 0) {
        if inspector.selection?.locked == true {
          if model.selectedID == inspector.selection?.id {
            InspectorSection(InspectorL10n.string("Layout")) {
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
            InspectorSection(InspectorL10n.string("Element overrides")) {
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
            InspectorSection(InspectorL10n.string("Matched rules")) {
              VStack(alignment: .leading, spacing: 12) {
                if model.busy && model.rules.isEmpty {
                  ProgressView().controlSize(.small).frame(maxWidth: .infinity)
                }
                ForEach(model.rules) { rule in
                  DisclosureGroup(
                    isExpanded: Binding(
                      get: { expanded.contains(rule.id) },
                      set: { if $0 { expanded.insert(rule.id) } else { expanded.remove(rule.id) } }
                    )
                  ) {
                    VStack(alignment: .leading, spacing: 2) {
                      ForEach(rule.declarations) { declaration in
                        Button {
                          property = declaration.name
                          important = declaration.value.hasSuffix(" !important")
                          value =
                            important ? String(declaration.value.dropLast(11)) : declaration.value
                        } label: {
                          HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text(declaration.name + ":").foregroundStyle(.secondary)
                            Text(declaration.value).foregroundStyle(.primary)
                            Spacer(minLength: 0)
                          }.environment(\.layoutDirection, .leftToRight).font(
                            .system(size: 11, design: .monospaced)
                          ).multilineTextAlignment(
                            .leading
                          )
                          .padding(.vertical, 3).contentShape(Rectangle())
                        }.buttonStyle(.plain).help(
                          InspectorL10n.format(
                            "Override %@ on this element", arguments: [.string(declaration.name)]))
                      }
                    }.padding(.leading, 2).padding(.top, 5)
                  } label: {
                    VStack(alignment: .leading, spacing: 4) {
                      Text(rule.selector).font(
                        .system(size: 11, weight: .medium, design: .monospaced)
                      )
                      .lineLimit(3).fixedSize(horizontal: false, vertical: true)
                      .environment(\.layoutDirection, .leftToRight)
                      Text(sourceLabel(rule.source)).font(.system(size: 10)).foregroundStyle(
                        .secondary
                      )
                      .lineLimit(1).truncationMode(.middle).help(InspectorL10n.display(rule.source))
                      .environment(\.layoutDirection, .leftToRight)
                    }
                  }.tint(.secondary)
                }
                InspectorL10n.text(
                  "Matched declarations include cascade candidates. Computed values show the final result."
                )
                .font(.system(size: 10)).foregroundStyle(.secondary)
              }
            }
            InspectorSection(InspectorL10n.string("Computed values")) {
              VStack(alignment: .leading, spacing: 8) {
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
                  VStack(spacing: 3) {
                    TextField(InspectorL10n.string("Filter properties"), text: $model.filter)
                      .textFieldStyle(.roundedBorder).font(.system(size: 11)).padding(.vertical, 6)
                    ForEach(
                      model.computed.filter {
                        model.filter.isEmpty
                          || $0.name.localizedCaseInsensitiveContains(model.filter)
                          || $0.value.localizedCaseInsensitiveContains(model.filter)
                      }
                    ) { row in
                      InspectorProperty(row.name, value: row.value, copy: inspector.copy)
                    }
                  }
                }.font(.system(size: 11))
              }
            }
            InspectorSection(InspectorL10n.string("Tools")) {
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

  private func apply() {
    Task {
      await model.edit(
        property: property.trimmingCharacters(in: .whitespacesAndNewlines), value: value,
        important: important)
    }
  }
  private func sourceLabel(_ source: String) -> String {
    if source.hasPrefix("Stylesheet ") {
      let suffix =
        source.components(separatedBy: ":").last.flatMap(Int.init)
        .map { InspectorL10n.format(" · line %d", arguments: [.integer($0)]) } ?? ""
      return InspectorL10n.string("Source unavailable") + suffix
    }
    if ["Inline overrides", "Browser default", "Source unavailable"].contains(source) {
      return InspectorL10n.display(source)
    }
    guard source.contains("://") else { return source }
    return source.components(separatedBy: "/").last ?? source
  }
}
