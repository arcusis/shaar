// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

struct InspectorNotesView: View {
  @Bindable var model: InspectorAICopyModel

  static var sectionHeadingTraits: AccessibilityTraits { .isHeader }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 12) {
        VStack(alignment: .leading, spacing: 8) {
          Text(InspectorL10n.string("Add feedback")).font(.system(size: 11, weight: .semibold))
            .accessibilityAddTraits(Self.sectionHeadingTraits)
          if !model.canCopy {
            Text(InspectorL10n.string("Lock an element to add a note.")).font(.system(size: 11))
              .foregroundStyle(
                .secondary)
          }
          TextEditor(text: $model.feedback).font(.system(size: 11)).frame(height: 76)
            .padding(4).background(
              Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 5)
            )
            .overlay(
              RoundedRectangle(cornerRadius: 5).strokeBorder(.primary.opacity(0.13), lineWidth: 0.5)
            )
            .accessibilityLabel(InspectorL10n.string("Feedback for selected element"))
            .overlay(alignment: .topLeading) {
              if model.feedback.isEmpty {
                Text(InspectorL10n.string("Describe feedback…")).font(.system(size: 11))
                  .foregroundStyle(.tertiary)
                  .padding(8)
                  .allowsHitTesting(false).accessibilityHidden(true)
              }
            }
          HStack(spacing: 8) {
            Picker(InspectorL10n.string("Intent"), selection: $model.intent) {
              ForEach(InspectorAIFormatter.Intent.allCases, id: \.self) {
                InspectorL10n.text($0.rawValue).tag($0)
              }
            }.pickerStyle(.segmented).labelsHidden()
            Button(InspectorL10n.string("Add note")) { Task { await model.addNote() } }
              .disabled(
                !model.canCopy
                  || model.feedback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                  || model.notes.count >= 50)
          }
        }
        Divider()
        HStack(spacing: 7) {
          Text(InspectorL10n.string("Notes")).font(.system(size: 11, weight: .semibold))
            .accessibilityAddTraits(Self.sectionHeadingTraits)
          Text("\(model.notes.count)/50").font(.system(size: 10, design: .monospaced))
            .foregroundStyle(.tertiary)
          Spacer(minLength: 0)
          Button(InspectorL10n.string("Copy all for AI")) { model.copyNotes() }.disabled(
            model.notes.isEmpty || model.busy)
          InspectorIconButton(InspectorL10n.string("Clear notes"), symbol: "trash") {
            model.clear()
          }.disabled(
            model.notes.isEmpty || model.busy)
        }
        if !model.clearedNotes.isEmpty {
          Button(
            InspectorL10n.format(
              "Undo clear (%1$lld)", arguments: [.integer(model.clearedNotes.count)]),
            systemImage: "arrow.uturn.backward"
          ) {
            model.undoClear()
          }
        }
        ForEach(model.notes) { note in
          VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
              InspectorL10n.text(note.intent.rawValue).font(.system(size: 9, weight: .medium))
                .padding(.horizontal, 5).padding(.vertical, 3)
                .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 3))
              Text(
                note.context.accessibleName.isEmpty ? note.context.tag : note.context.accessibleName
              )
              .font(.system(size: 11, weight: .medium)).lineLimit(1).truncationMode(.middle)
              Spacer(minLength: 0)
              InspectorIconButton(InspectorL10n.string("Delete note"), symbol: "xmark") {
                model.delete(note.id)
              }
            }
            Text(note.feedback).font(.system(size: 11)).textSelection(.enabled)
              .fixedSize(horizontal: false, vertical: true)
            Text(note.context.selector).font(.system(size: 10, design: .monospaced))
              .foregroundStyle(.secondary)
              .lineLimit(1).truncationMode(.middle).help(note.context.selector)
              .environment(\.layoutDirection, .leftToRight)
            Text(InspectorL10n.display(InspectorAIFormatter.url(note.context.url))).font(.system(size: 10))
              .foregroundStyle(.secondary)
              .lineLimit(1).truncationMode(.middle).help(InspectorL10n.display(InspectorAIFormatter.url(note.context.url)))
              .environment(\.layoutDirection, .leftToRight)
          }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 5))
            .overlay(
              RoundedRectangle(cornerRadius: 5).strokeBorder(.primary.opacity(0.08), lineWidth: 0.5)
            )
        }
        Text(InspectorL10n.string("Notes stay in this tab across page navigation."))
          .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(
            horizontal: false, vertical: true)
        if model.busy {
          ProgressView().controlSize(.small)
            .accessibilityLabel(InspectorL10n.string("Working…"))
        }
        if let value = model.status,
          ![
            "Copied element to clipboard", "Copied image to clipboard", "Copied notes to clipboard",
          ]
          .map(InspectorL10n.string).contains(value)
        {
          Text(value).foregroundStyle(.secondary)
        }
      }.padding(12).font(.system(size: 11)).controlSize(.small)
    }.scrollBounceBehavior(.basedOnSize)
  }
}
