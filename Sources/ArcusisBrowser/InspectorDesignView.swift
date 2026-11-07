// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

struct InspectorDesignView: View {
  @Bindable var model: InspectorModel
  let selection: InspectorSelection
  private var layoutCSS: String {
    let box = selection.box
    return [
      selection.display.map { "display: \($0);" },
      "width: \(InspectorColor.number(box.width))px;",
      "height: \(InspectorColor.number(box.height))px;",
      "margin: \(box.margin.joined(separator: " "));",
      "border-width: \(box.border.joined(separator: " "));",
      "padding: \(box.padding.joined(separator: " "));",
    ].compactMap { $0 }.joined(separator: "\n")
  }
  private var typographyCSS: String {
    let font = selection.typography
    return
      "font-family: \(font.family);\nfont-weight: \(font.weight);\nfont-size: \(font.size);\nline-height: \(font.lineHeight);\nletter-spacing: \(font.letterSpacing);"
  }
  private var colorsCSS: String {
    selection.colors.map {
      let property =
        $0.label == "Text"
        ? "color"
        : $0.label == "Background"
          ? "background-color"
          : $0.label == "Border"
            ? "border-color"
            : $0.label.lowercased().replacingOccurrences(of: " ", with: "-") + "-color"
      return property + ": " + $0.value.formatted(model.colorFormat) + ";"
    }.joined(separator: "\n")
  }
  private var boxEdit: ((String, String) -> Void)? {
    guard selection.locked else { return nil }
    return { property, value in
      Task { await model.styles.edit(property: property, value: value, important: false) }
    }
  }

  var body: some View {
    ScrollView {
      VStack(spacing: 0) {
        InspectorSection(
          InspectorL10n.string("Layout"), id: "Layout",
          copy: { model.copy(layoutCSS, label: "layout") },
          code: layoutCSS
        ) {
          VStack(spacing: 7) {
            if let display = selection.display { displayRow(display) }
            HStack(spacing: 12) {
              InspectorProperty(
                InspectorL10n.string("Width"),
                value: InspectorColor.number(selection.box.width.rounded()) + "px"
              ) { model.copy($0, label: "width") }
              InspectorProperty(
                InspectorL10n.string("Height"),
                value: InspectorColor.number(selection.box.height.rounded()) + "px"
              ) { model.copy($0, label: "height") }
            }
            InspectorBoxModel(box: selection.box, edit: boxEdit) { region, index, active in
              model.highlightEdge(region, index, active: active)
            }.padding(.top, 3)
            if let failure = model.styles.failure {
              Text(InspectorL10n.display(failure)).font(.system(size: 11)).foregroundStyle(
                .secondary
              )
              .frame(maxWidth: .infinity, alignment: .leading)
            }
          }
        }
        if !selection.typography.preview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          InspectorSection(
            InspectorL10n.string("Typography"), id: "Typography",
            copy: { model.copy(typographyCSS, label: "typography") },
            code: typographyCSS
          ) {
            VStack(spacing: 8) {
              Text(selection.typography.preview)
                .font(.custom(previewFont, size: 18).weight(previewWeight)).lineLimit(2)
                .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading).padding(8)
                .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 5))
              LazyVGrid(
                columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading,
                spacing: 7
              ) {
                field(
                  "Font",
                  value: selection.renderedFonts.isEmpty
                    ? selection.typography.family : selection.renderedFonts.joined(separator: ", "))
                field("Weight", value: selection.typography.weight)
                field("Size", value: selection.typography.size)
                field("Line height", value: selection.typography.lineHeight)
                field("Letter spacing", value: selection.typography.letterSpacing)
              }
            }
          }
        }
        if !selection.colors.isEmpty {
          InspectorSection(
            InspectorL10n.string("Colors"), id: "Colors",
            copy: { model.copy(colorsCSS, label: "colors") },
            code: colorsCSS,
            format: $model.colorFormat
          ) {
            VStack(spacing: 3) {
              ForEach(selection.colors) { swatch in
                InspectorSwatch(swatch: swatch, format: model.colorFormat) {
                  model.copy($0, label: "color")
                }
              }
              if !selection.typography.preview.isEmpty {
                Divider().padding(.vertical, 7)
                contrast
              }
            }
          }
        }
      }
    }.scrollBounceBehavior(.basedOnSize)
  }

  private var previewFont: String {
    selection.renderedFonts.first ?? selection.typography.family.components(separatedBy: ",").first?
      .trimmingCharacters(
        in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'")))
      ?? "System"
  }

  private var previewWeight: Font.Weight {
    guard let weight = Double(selection.typography.weight), weight.isFinite else { return .regular }
    switch weight {
    case ..<150: return .ultraLight
    case ..<250: return .thin
    case ..<350: return .light
    case ..<450: return .regular
    case ..<550: return .medium
    case ..<650: return .semibold
    case ..<750: return .bold
    case ..<850: return .heavy
    default: return .black
    }
  }

  private func field(_ title: String, value: String) -> some View {
    Button {
      model.copy(value, label: title)
    } label: {
      VStack(alignment: .leading, spacing: 4) {
        InspectorL10n.text(title).font(.system(size: 10)).foregroundStyle(.secondary)
        Text(value).environment(\.layoutDirection, .leftToRight).font(
          .system(size: 11, design: .monospaced)
        ).lineLimit(1).truncationMode(
          .middle
        )
        .frame(maxWidth: .infinity, alignment: .leading)
      }.padding(.horizontal, 8).padding(.vertical, 6)
        .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 4))
    }.buttonStyle(.plain).help(
      InspectorL10n.format("Copy %@", arguments: [.string(InspectorL10n.string(title))]) + ": "
        + value)
  }

  private func displayRow(_ display: String) -> some View {
    HStack(spacing: 8) {
      Text(InspectorL10n.string("Display")).font(.system(size: 11)).foregroundStyle(.secondary)
      Spacer(minLength: 0)
      HStack(spacing: 1) {
        ForEach(
          ["block", "flex", "grid"]
            + (["block", "flex", "grid"].contains(display) ? [] : [display]), id: \.self
        ) { value in
          Text(value.replacingOccurrences(of: "-", with: " ").capitalized)
            .font(.system(size: 10, weight: value == display ? .medium : .regular))
            .foregroundStyle(value == display ? .primary : .tertiary)
            .padding(.horizontal, 6).frame(height: 22)
            .background(
              value == display ? Color(nsColor: .controlBackgroundColor) : .clear,
              in: RoundedRectangle(cornerRadius: 3))
        }
      }.padding(2).background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 4))
        .help("display: " + display)
    }
  }

  @ViewBuilder private var contrast: some View {
    if let ratio = selection.contrast {
      HStack(spacing: 7) {
        Text(InspectorL10n.string("Contrast")).font(.system(size: 11)).foregroundStyle(.secondary)
        Spacer(minLength: 0)
        Text(String(format: "%.2f:1", ratio)).font(.system(size: 11, design: .monospaced))
        badge("AA", passes: ratio >= (selection.largeText ? 3 : 4.5))
        badge("AAA", passes: ratio >= (selection.largeText ? 4.5 : 7))
      }
    } else if let reason = selection.contrastLimit {
      Text(InspectorL10n.display(reason)).font(.system(size: 10)).foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading).fixedSize(
          horizontal: false, vertical: true)
    }
  }

  private func badge(_ title: String, passes: Bool) -> some View {
    Label(title, systemImage: passes ? "checkmark" : "xmark")
      .font(.system(size: 9, weight: .medium)).padding(.horizontal, 5).padding(.vertical, 3)
      .foregroundStyle(passes ? Color.green : .red)
      .background(
        (passes ? Color.green : .red).opacity(0.08), in: RoundedRectangle(cornerRadius: 3)
      )
      .help(InspectorL10n.format(passes ? "%@ passes" : "%@ fails", arguments: [.string(title)]))
  }
}
