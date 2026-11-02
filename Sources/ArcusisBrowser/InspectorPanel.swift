// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

struct InspectorPanel: View {
  @Bindable var model: InspectorModel

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 8) {
        Image(systemName: "viewfinder").foregroundStyle(Color.accentColor)
        InspectorL10n.text("Inspector").font(.system(size: 12, weight: .semibold))
        Spacer()
        Text(
          model.panelMode == .page
            ? InspectorL10n.string("Page tools")
            : (model.mode == .locked
              ? InspectorL10n.string("Locked") : InspectorL10n.string("Inspecting"))
        )
        .font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
        InspectorIconButton(
          InspectorL10n.string(model.tab == .notes ? "Back to element" : "Notes"),
          symbol: model.tab == .notes ? "arrow.left" : "square.and.pencil"
        ) {
          model.setPanelMode(.element)
          model.tab = model.tab == .notes ? .design : .notes
        }
        InspectorIconButton(
          InspectorL10n.string("Pick an element"), symbol: "cursorarrow.rays"
        ) { model.pick() }

        InspectorIconButton(
          InspectorL10n.string("Close Inspector"), symbol: "xmark", action: model.close)
      }
      .padding(.horizontal, 12).frame(height: 40)
      Divider()
      Picker(
        InspectorL10n.string("Inspector mode"),
        selection: Binding(get: { model.panelMode }, set: { model.setPanelMode($0) })
      ) {
        ForEach(InspectorModel.PanelMode.allCases, id: \.self) {
          InspectorL10n.text($0.rawValue).tag($0)
        }
      }.pickerStyle(.segmented).labelsHidden().controlSize(.small).padding(12)
      Divider()
      if model.panelMode == .page, let tools = model.pageTools {
        InspectorPageToolsView(inspector: model, model: tools)
      } else if model.tab == .notes {
        InspectorNotesView(model: model.aiCopy)
      } else if let selection = model.selection {
        selectionHeader(selection)
        Picker(InspectorL10n.string("Inspector section"), selection: $model.tab) {
          ForEach(InspectorModel.Tab.allCases, id: \.self) {
            InspectorL10n.text($0 == .accessibility ? "Accessibility" : $0.rawValue).tag($0)
          }
        }.pickerStyle(.segmented).labelsHidden().controlSize(.small)
          .padding(.horizontal, 12).padding(.bottom, 10)
        Divider()
        if model.tab == .styles {
          InspectorStylesView(inspector: model, model: model.styles)
        } else if [.component, .accessibility, .assets].contains(model.tab) {
          InspectorDetailsView(inspector: model, model: model.details)
        } else {
          ScrollView {
            VStack(spacing: 0) {
              InspectorSection(InspectorL10n.string("Box model")) {
                InspectorBoxModel(box: selection.box)
              }
              InspectorSection(InspectorL10n.string("Typography")) {
                VStack(alignment: .leading, spacing: 4) {
                  if !selection.typography.preview.isEmpty {
                    Text(selection.typography.preview).font(.system(size: 13))
                      .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                      .padding(10).background(
                        .primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 5)
                      )
                      .padding(.bottom, 7)
                  }
                  InspectorProperty(
                    InspectorL10n.string("Rendered font"),
                    value: selection.fontsAvailable
                      ? (selection.renderedFonts.isEmpty
                        ? InspectorL10n.string("No rendered text")
                        : selection.renderedFonts.joined(separator: ", "))
                      : (model.readingFonts
                        ? InspectorL10n.string("Reading…") : InspectorL10n.string("Unavailable")),
                    copy: model.copy)
                  InspectorProperty(
                    InspectorL10n.string("CSS family"), value: selection.typography.family,
                    copy: model.copy)
                  HStack(spacing: 12) {
                    InspectorProperty(
                      InspectorL10n.string("Size"), value: selection.typography.size,
                      copy: model.copy)
                    InspectorProperty(
                      InspectorL10n.string("Weight"), value: selection.typography.weight,
                      copy: model.copy)
                  }
                  InspectorProperty(
                    InspectorL10n.string("Line height"), value: selection.typography.lineHeight,
                    copy: model.copy)
                  InspectorProperty(
                    InspectorL10n.string("Letter spacing"),
                    value: selection.typography.letterSpacing, copy: model.copy)
                  if !selection.pageFonts.isEmpty {
                    Divider().padding(.vertical, 6)
                    InspectorL10n.text("Fonts on this page").font(.system(size: 11))
                      .foregroundStyle(.secondary)
                    Text(selection.pageFonts.joined(separator: " · "))
                      .font(.system(size: 11, design: .monospaced))
                      .fixedSize(horizontal: false, vertical: true).padding(.top, 3)
                    Text(
                      model.pageFontsTruncated
                        ? InspectorL10n.string("Rendered text sample limit reached")
                        : InspectorL10n.string("From rendered text samples")
                    )
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                  }
                  if !selection.fontsAvailable && !model.readingFonts {
                    InspectorL10n.text("Rendered font data unavailable; CSS family is shown above.")
                      .font(.system(size: 10)).foregroundStyle(.secondary)
                  }
                }
              }
              InspectorSection(InspectorL10n.string("Colors")) {
                VStack(alignment: .leading, spacing: 10) {
                  Picker(InspectorL10n.string("Color format"), selection: $model.colorFormat) {
                    ForEach(InspectorColor.Format.allCases, id: \.self) {
                      Text($0.rawValue).tag($0)
                    }
                  }.pickerStyle(.segmented).labelsHidden().controlSize(.small)
                  ForEach(selection.colors) { swatch in
                    InspectorSwatch(swatch: swatch, format: model.colorFormat, copy: model.copy)
                  }
                  Divider().padding(.vertical, 2)
                  contrast(selection)
                }
              }
            }
          }.scrollBounceBehavior(.basedOnSize)
        }
      } else {
        VStack(spacing: 10) {
          Image(systemName: "cursorarrow.rays").font(.system(size: 24, weight: .light))
            .foregroundStyle(.tertiary)
          InspectorL10n.text("Inspect any element").font(.system(size: 13, weight: .medium))
          InspectorL10n.text("Hover to preview. Click to lock.\nUse arrow keys to explore the DOM.")
            .font(.system(size: 11)).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).padding(24)
      }
      if let failure = model.failure {
        Divider()
        Text(InspectorL10n.display(failure)).font(.system(size: 11)).foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading).padding(12)
      }
      Divider()
      if model.panelMode == .element, model.tab != .notes {
        HStack(spacing: 5) {
          Image(systemName: "arrow.up.arrow.down").font(.system(size: 9))
          InspectorL10n.text("Parent / child").font(.system(size: 10))
          Spacer()
          InspectorL10n.text("← → Siblings   esc Exit").font(.system(size: 10, design: .monospaced))
        }.environment(\.layoutDirection, .leftToRight).foregroundStyle(.secondary).padding(
          .horizontal, 12
        ).frame(height: 28)
      }
    }
    .background(Color(nsColor: .windowBackgroundColor))
    .onExitCommand(perform: model.close)
    .onMoveCommand(perform: moveAction)
    .inspectorLocalization()
  }

  private var moveAction: ((MoveCommandDirection) -> Void)? {
    guard model.panelMode == .element, model.tab != .notes else { return nil }
    return { direction in
      switch direction {
      case .up: model.navigate("up")
      case .down: model.navigate("down")
      case .left: model.navigate("left")
      case .right: model.navigate("right")
      @unknown default: break
      }
    }
  }

  private func selectionHeader(_ selection: InspectorSelection) -> some View {
    VStack(alignment: .leading, spacing: 9) {
      HStack(alignment: .firstTextBaseline) {
        Text(selection.component ?? selection.tag)
          .font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.middle)
          .environment(\.layoutDirection, .leftToRight)
        Spacer(minLength: 4)
        Text(selection.dimensions).font(.system(size: 11, design: .monospaced)).foregroundStyle(
          .secondary
        )
        .environment(\.layoutDirection, .leftToRight)
      }
      Text(selection.label).font(.system(size: 11, design: .monospaced))
        .foregroundStyle(.secondary).lineLimit(1).help(selection.label)
        .environment(\.layoutDirection, .leftToRight)
      HStack(spacing: 5) {
        copyButton("CSS", value: selection.css)
        copyButton("Playwright", value: selection.playwright)
        copyButton("XPath", value: selection.xpath)
        copyButton("JS path", value: selection.jsPath)
        Spacer(minLength: 0)
        InspectorIconButton(InspectorL10n.string("Save element at 2×"), symbol: "camera") {
          Task { await model.styles.saveScreenshot() }
        }.disabled(!selection.locked)
      }.environment(\.layoutDirection, .leftToRight)
      InspectorAICopyControls(model: model.aiCopy)
      HStack(spacing: 4) {
        if selection.ancestors.count > 3 {
          Menu {
            ForEach(selection.ancestors.dropLast(3)) { ancestor in
              Button(ancestor.label) { model.selectAncestor(ancestor.id) }
            }
          } label: {
            Image(systemName: "ellipsis").frame(width: 16)
          }
          .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
          .help(InspectorL10n.string("Inspect an earlier ancestor"))
        }
        ForEach(selection.ancestors.suffix(3)) { ancestor in
          if ancestor.id != selection.ancestors.suffix(3).first?.id {
            Image(systemName: "chevron.right").font(.system(size: 7)).foregroundStyle(.secondary)
          }
          Button {
            model.selectAncestor(ancestor.id)
          } label: {
            Text(ancestor.label).font(.system(size: 11, design: .monospaced))
              .lineLimit(1).truncationMode(.middle)
              .foregroundStyle(ancestor.id == selection.id ? Color.primary : .secondary)
          }.buttonStyle(.plain).help(
            InspectorL10n.format("Inspect %@", arguments: [.string(ancestor.label)])
          )
          .layoutPriority(ancestor.id == selection.id ? 1 : 0)
        }
      }.environment(\.layoutDirection, .leftToRight)
      if !selection.frames.isEmpty {
        Label(
          InspectorL10n.plural("Inside %d frame", count: selection.frames.count),
          systemImage: "rectangle.inset.filled"
        )
        .font(.system(size: 10)).foregroundStyle(.secondary)
      }
    }.padding(12)
  }

  private func copyButton(_ title: String, value: String) -> some View {
    let label = InspectorL10n.string(title)
    return Button {
      model.copy(value)
    } label: {
      Text(label).font(.system(size: 10, weight: .medium))
        .padding(.horizontal, 7).frame(height: 23)
        .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 4))
    }
    .buttonStyle(.plain).disabled(value.isEmpty)
    .help(InspectorL10n.format("Copy %@", arguments: [.string(label)]))
    .accessibilityLabel(InspectorL10n.format("Copy %@", arguments: [.string(label)]))
  }

  @ViewBuilder private func contrast(_ selection: InspectorSelection) -> some View {
    if let ratio = selection.contrast, let grade = selection.contrastGrade {
      HStack {
        InspectorL10n.text("Text contrast").font(.system(size: 11))
        Spacer()
        Text(String(format: "%.2f:1", ratio)).font(
          .system(size: 12, weight: .medium, design: .monospaced))
        Text(InspectorL10n.string(grade)).font(.system(size: 10, weight: .semibold))
          .padding(.horizontal, 6).padding(.vertical, 3)
          .foregroundStyle(grade == "Fail" ? Color.red : Color.green)
          .background(
            (grade == "Fail" ? Color.red : Color.green).opacity(0.1),
            in: RoundedRectangle(cornerRadius: 4))
      }
      Text(
        InspectorL10n.format(
          "WCAG 2.2 · %@ · Solid background",
          arguments: [
            .string(InspectorL10n.string(selection.largeText ? "Large text" : "Normal text"))
          ])
      )
      .font(.system(size: 10)).foregroundStyle(.secondary)
    } else {
      InspectorL10n.text("Contrast unavailable").font(.system(size: 11, weight: .medium))
      Text(
        InspectorL10n.display(
          selection.contrastLimit ?? "A solid background could not be resolved.")
      )
      .font(.system(size: 10)).foregroundStyle(.secondary)
    }
  }
}

struct InspectorSection<Content: View>: View {
  let title: String
  let copy: (() -> Void)?
  @ViewBuilder let content: () -> Content
  @State private var hovered = false
  @FocusState private var copyFocused: Bool
  init(_ title: String, copy: (() -> Void)? = nil, @ViewBuilder content: @escaping () -> Content) {
    self.title = title
    self.copy = copy
    self.content = content
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text(title).font(.system(size: 11, weight: .semibold))
        Spacer()
        if let copy {
          Button(action: copy) {
            Image(systemName: "doc.on.doc").font(.system(size: 11)).frame(width: 16, height: 16)
          }
          .buttonStyle(.plain).focused($copyFocused).opacity(hovered || copyFocused ? 1 : 0)
          .help(InspectorL10n.format("Copy %@", arguments: [.string(title)]))
          .accessibilityLabel(InspectorL10n.format("Copy %@", arguments: [.string(title)]))
        }
      }
      content()
    }
    .frame(maxWidth: .infinity, alignment: .leading).padding(12)
    .overlay(alignment: .bottom) { Divider() }
    .onHover { hovered = $0 }
  }
}

struct InspectorProperty: View {
  let title: String
  let value: String
  let copy: (String) -> Void
  let copyLabel: String
  @State private var hovered = false
  @FocusState private var copyFocused: Bool
  init(_ title: String, value: String, copyLabel: String? = nil, copy: @escaping (String) -> Void) {
    self.title = title
    self.value = value
    self.copyLabel = copyLabel ?? title
    self.copy = copy
  }
  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
      Spacer(minLength: 4)
      Text(value).font(.system(size: 11, design: .monospaced)).lineLimit(1).truncationMode(.middle)
        .environment(\.layoutDirection, .leftToRight)
      Button {
        copy(value)
      } label: {
        Image(systemName: "doc.on.doc").font(.system(size: 10))
      }
      .buttonStyle(.plain).focused($copyFocused).opacity(hovered || copyFocused ? 1 : 0)
      .accessibilityLabel(InspectorL10n.format("Copy %@", arguments: [.string(copyLabel)]))
      .help(InspectorL10n.format("Copy %@", arguments: [.string(copyLabel)]))
    }
    .frame(minHeight: 23).contentShape(Rectangle()).onHover { hovered = $0 }
    .help(value)
  }
}

struct InspectorSwatch: View {
  let swatch: InspectorSelection.Swatch
  let format: InspectorColor.Format
  let copy: (String) -> Void
  var body: some View {
    HStack(spacing: 10) {
      RoundedRectangle(cornerRadius: 4).fill(swatch.value.color)
        .background {
          Canvas { context, size in
            for x in stride(from: 0.0, to: size.width, by: 5) {
              for y in stride(from: 0.0, to: size.height, by: 5) {
                context.fill(
                  Path(CGRect(x: x, y: y, width: 5, height: 5)),
                  with: .color(
                    Color.primary.opacity((Int(x / 5) + Int(y / 5)).isMultiple(of: 2) ? 0.05 : 0.15)
                  ))
              }
            }
          }.clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.primary.opacity(0.14)))
        .frame(width: 26, height: 26)
      VStack(alignment: .leading, spacing: 1) {
        Text(InspectorL10n.display(swatch.label)).font(.system(size: 10)).foregroundStyle(
          .secondary)
        InspectorProperty(
          "", value: swatch.value.formatted(format),
          copyLabel: InspectorL10n.display(swatch.label), copy: copy)
      }
    }
  }
}

struct InspectorIconButton: View {
  let title: String
  let symbol: String
  let action: () -> Void
  init(_ title: String, symbol: String, action: @escaping () -> Void) {
    self.title = title
    self.symbol = symbol
    self.action = action
  }
  var body: some View {
    Button(action: action) {
      Image(systemName: symbol).font(.system(size: 11)).frame(width: 22, height: 24)
    }
    .buttonStyle(.plain).help(title).accessibilityLabel(title)
  }
}
