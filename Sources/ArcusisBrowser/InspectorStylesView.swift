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
            InspectorSection("Layout") {
              VStack(spacing: 2) {
                ForEach(model.layout) { row in
                  InspectorProperty(row.name, value: row.value, copy: inspector.copy)
                }
                if model.canOverlay {
                  Toggle(
                    "Show \(model.layout.first?.value.contains("grid") == true ? "grid" : "flex") overlay",
                    isOn: Binding(
                      get: { model.overlay },
                      set: { _ in Task { await model.toggleOverlay() } }
                    )
                  )
                  .toggleStyle(.checkbox).font(.system(size: 11)).padding(.top, 8)
                }
              }
            }
            InspectorSection("Element overrides") {
              VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 6) {
                  TextField("property", text: $property)
                    .frame(width: 104).accessibilityLabel("CSS property")
                  Text(":").foregroundStyle(.secondary)
                  TextField("value", text: $value).accessibilityLabel("CSS value")
                }
                .font(.system(size: 11, design: .monospaced)).textFieldStyle(.roundedBorder)
                .onSubmit(apply)
                HStack {
                  Toggle("!important", isOn: $important).toggleStyle(.checkbox)
                    .font(.system(size: 11, design: .monospaced))
                  Spacer()
                  Button("Undo", systemImage: "arrow.uturn.backward") {
                    Task { await model.undo() }
                  }
                  .disabled(model.undoDepth == 0 || model.busy)
                  Button("Apply", action: apply).disabled(property.isEmpty || model.busy)
                }.controlSize(.small).font(.system(size: 11))
                Text("Applies to this element until reload. Empty value removes the override.")
                  .font(.system(size: 10)).foregroundStyle(.secondary)
              }
            }
            InspectorSection("Matched rules") {
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
                          }.font(.system(size: 11, design: .monospaced)).multilineTextAlignment(
                            .leading
                          )
                          .padding(.vertical, 3).contentShape(Rectangle())
                        }.buttonStyle(.plain).help("Override \(declaration.name) on this element")
                      }
                    }.padding(.leading, 2).padding(.top, 5)
                  } label: {
                    VStack(alignment: .leading, spacing: 4) {
                      Text(rule.selector).font(
                        .system(size: 11, weight: .medium, design: .monospaced)
                      )
                      .lineLimit(3).fixedSize(horizontal: false, vertical: true)
                      Text(sourceLabel(rule.source)).font(.system(size: 10)).foregroundStyle(
                        .secondary
                      )
                      .lineLimit(1).truncationMode(.middle).help(rule.source)
                    }
                  }.tint(.secondary)
                }
                Text(
                  "Matched declarations include cascade candidates. Computed values show the final result."
                )
                .font(.system(size: 10)).foregroundStyle(.secondary)
              }
            }
            InspectorSection("Computed values") {
              VStack(alignment: .leading, spacing: 8) {
                HStack {
                  Button("Copy CSS", systemImage: "doc.on.doc") { inspector.copy(model.css) }
                    .help("Copy a computed CSS snapshot")
                  Button("Tailwind") { inspector.copy(model.tailwind) }
                    .help("Copy computed styles as Tailwind arbitrary-property utilities")
                  Spacer()
                }.controlSize(.small).font(.system(size: 11)).disabled(model.computed.isEmpty)
                DisclosureGroup("All computed properties", isExpanded: $showComputed) {
                  VStack(spacing: 3) {
                    TextField("Filter properties", text: $model.filter)
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
            InspectorSection("Tools") {
              VStack(alignment: .leading, spacing: 10) {
                Button("Save element at 2×", systemImage: "camera") {
                  Task { await model.saveScreenshot() }
                }.controlSize(.small).font(.system(size: 11))
                Label("Hold Option over another element to measure.", systemImage: "ruler")
                  .font(.system(size: 11)).foregroundStyle(.secondary)
                  .help(
                    "Shows horizontal and vertical gaps; overlapping elements show leading-edge offsets."
                  )
              }
            }
          } else {
            ProgressView("Reading styles…").controlSize(.small).font(.system(size: 11)).padding(24)
          }
        } else {
          Text("Click an element to lock its styles.")
            .font(.system(size: 12)).foregroundStyle(.secondary).padding(24)
        }
        if let failure = model.failure {
          Text(failure).font(.system(size: 11)).foregroundStyle(.secondary)
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
      return "Source unavailable"
        + (source.components(separatedBy: ":").last.flatMap(Int.init).map { " · line \($0)" } ?? "")
    }
    guard source.contains("://") else { return source }
    return source.components(separatedBy: "/").last ?? source
  }
}
