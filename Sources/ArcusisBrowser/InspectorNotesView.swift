// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

struct InspectorNotesView: View {
  @Bindable var model: InspectorAICopyModel
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 12) {
        HStack {
          Text(InspectorL10n.format("Notes · %1$lld/50", arguments: [.integer(model.notes.count)]))
            .font(.system(size: 12, weight: .semibold))
          Spacer()
          Toggle(InspectorL10n.string("Detailed"), isOn: $model.detailed).toggleStyle(.checkbox)
            .fixedSize()
        }
        Text(
          InspectorL10n.string(
            "Notes stay in this tab across page navigation. Form controls are omitted from copied context."
          )
        )
        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        Picker(InspectorL10n.string("Intent"), selection: $model.intent) {
          ForEach(InspectorAIFormatter.Intent.allCases, id: \.self) {
            InspectorL10n.text($0.rawValue).tag($0)
          }
        }.pickerStyle(.segmented).labelsHidden()
        TextEditor(text: $model.feedback).font(.system(size: 11)).frame(height: 80)
          .border(.secondary.opacity(0.2)).accessibilityLabel(
            InspectorL10n.string("Feedback for selected element")
          )
          .overlay(alignment: .topLeading) {
            if model.feedback.isEmpty {
              InspectorL10n.text("Describe a change, question or important detail…")
                .font(.system(size: 11)).foregroundStyle(.tertiary).padding(5)
                .allowsHitTesting(false).accessibilityHidden(true)
            }
          }
        Button(InspectorL10n.string("Add note for selected element")) {
          Task { await model.addNote() }
        }
        .disabled(
          !model.canCopy || model.feedback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || model.notes.count >= 50)
        Divider()
        HStack {
          Button(InspectorL10n.string("Copy all for AI")) { model.copyNotes() }.disabled(
            model.notes.isEmpty || model.busy)
          Spacer()
          Button(InspectorL10n.string("Clear")) { model.clear() }.disabled(
            model.notes.isEmpty || model.busy)
        }
        if !model.clearedNotes.isEmpty {
          Button(
            InspectorL10n.format(
              "Undo clear (%1$lld)", arguments: [.integer(model.clearedNotes.count)])
          ) { model.undoClear() }
        }
        ForEach(model.notes) { note in
          VStack(alignment: .leading, spacing: 5) {
            HStack {
              InspectorL10n.text(note.intent.rawValue).fontWeight(.semibold)
              Text(
                note.context.accessibleName.isEmpty ? note.context.tag : note.context.accessibleName
              ).lineLimit(1)
              Spacer()
              InspectorIconButton(InspectorL10n.string("Delete note"), symbol: "trash") {
                model.delete(note.id)
              }
            }
            Text(InspectorAIFormatter.url(note.context.url)).font(
              .system(size: 10, design: .monospaced)
            ).lineLimit(1).foregroundStyle(.secondary)
              .environment(\.layoutDirection, .leftToRight)
            Text(note.feedback).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
          }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 5))
        }
        if model.busy { ProgressView().controlSize(.small) }
        if let value = model.failure ?? model.status { Text(value).foregroundStyle(.secondary) }
      }.padding(12).font(.system(size: 11)).controlSize(.small)
    }.scrollBounceBehavior(.basedOnSize)
  }
}

struct InspectorAICopyControls: View {
  @Bindable var model: InspectorAICopyModel
  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Button {
          Task { await model.copyElement() }
        } label: {
          Label(
            InspectorL10n.string(model.busy ? "Preparing…" : "Copy for AI"),
            systemImage: "doc.on.clipboard")
        }.disabled(!model.canCopy).help(
          InspectorL10n.string("Copy context and element PNG (Command-Shift-C)"))
        Spacer()
        Toggle(InspectorL10n.string("Detailed"), isOn: $model.detailed).toggleStyle(.checkbox)
          .fixedSize()
      }.controlSize(.small).font(.system(size: 11))
      if let message = model.failure ?? model.status {
        Text(message).font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(
          horizontal: false, vertical: true)
      }
    }
  }
}
