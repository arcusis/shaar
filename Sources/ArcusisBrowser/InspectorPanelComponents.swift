// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

struct InspectorSection<Content: View>: View {
  let title: String
  let identifier: String
  let copy: (() -> Void)?
  let code: String?
  let format: Binding<InspectorColor.Format>?
  @ViewBuilder let content: () -> Content
  @Environment(\.inspectorPresentation) private var presentation
  @Environment(\.inspectorSectionScope) private var scope
  @Environment(\.layoutDirection) private var layoutDirection
  @State private var collapsed = false
  @State private var showingCode = false
  @State private var hovered = false
  @FocusState private var copyFocused: Bool
  private var key: String { scope + ":" + identifier }
  private var isCollapsed: Bool { presentation?.collapsedSections.contains(key) ?? collapsed }
  private var isCode: Bool { presentation?.codeSections.contains(key) ?? showingCode }

  static func disclosureSymbol(isCollapsed: Bool, rightToLeft: Bool) -> String {
    guard isCollapsed else { return "chevron.down" }
    return rightToLeft ? "chevron.left" : "chevron.right"
  }

  init(
    _ title: String, id: String? = nil, copy: (() -> Void)? = nil, code: String? = nil,
    format: Binding<InspectorColor.Format>? = nil, @ViewBuilder content: @escaping () -> Content
  ) {
    self.title = title
    self.identifier = id ?? title
    self.copy = copy
    self.code = code
    self.format = format
    self.content = content
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 7) {
        Button {
          if let presentation {
            presentation.collapsedSections.formSymmetricDifference([key])
          } else {
            collapsed.toggle()
          }
        } label: {
          HStack(spacing: 6) {
            Image(
              systemName: Self.disclosureSymbol(
                isCollapsed: isCollapsed, rightToLeft: layoutDirection == .rightToLeft))
              .font(.system(size: 8, weight: .semibold)).foregroundStyle(.secondary).frame(width: 9)
            Text(title).font(.system(size: 11, weight: .semibold))
            Spacer(minLength: 0)
          }.contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityValue(
          InspectorL10n.string(isCollapsed ? "Collapsed" : "Expanded"))
        if let format {
          Menu {
            ForEach(InspectorColor.Format.allCases, id: \.self) { value in
              Button {
                format.wrappedValue = value
              } label: {
                if value == format.wrappedValue {
                  Label(value.rawValue, systemImage: "checkmark")
                } else {
                  InspectorL10n.text(value.rawValue)
                }
              }
            }
          } label: {
            Text(format.wrappedValue.rawValue).font(.system(size: 10, design: .monospaced))
              .foregroundStyle(.secondary)
          }.menuStyle(.borderlessButton).menuIndicator(.visible).fixedSize().help(
            InspectorL10n.string("Color format"))
        }
        if code != nil, !isCollapsed {
          HStack(spacing: 1) {
            modeButton("List", code: false)
            modeButton("Code", code: true)
          }.padding(2).background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 4))
        }
        if let copy, !isCode {
          InspectorIconButton(
            InspectorL10n.format("Copy %@", arguments: [.string(title)]), symbol: "doc.on.doc",
            action: copy
          )
          .focused($copyFocused).opacity(hovered || copyFocused ? 1 : 0)
        }
      }.frame(minHeight: 34).padding(.horizontal, 12)
      if !isCollapsed {
        Group {
          if isCode, let code { InspectorCodeBlock(code: code, copy: copy) } else { content() }
        }.padding(.horizontal, 12).padding(.bottom, 12)
      }
    }.frame(maxWidth: .infinity, alignment: .leading)
      .overlay(alignment: .bottom) { Divider() }.onHover { hovered = $0 }
  }

  private func modeButton(_ title: String, code: Bool) -> some View {
    Button {
      if let presentation {
        if code {
          presentation.codeSections.insert(key)
        } else {
          presentation.codeSections.remove(key)
        }
      } else {
        showingCode = code
      }
    } label: {
      InspectorL10n.text(title).font(.system(size: 10, weight: isCode == code ? .medium : .regular))
        .foregroundStyle(isCode == code ? .primary : .secondary)
        .padding(.horizontal, 4).frame(minWidth: 30, minHeight: 18)
        .background(
          isCode == code ? Color(nsColor: .controlBackgroundColor) : .clear,
          in: RoundedRectangle(cornerRadius: 3))
    }.buttonStyle(.plain).help(InspectorL10n.string(code ? "Show CSS code" : "Show property list"))
      .accessibilityAddTraits(isCode == code ? .isSelected : [])
  }
}

struct InspectorCodeBlock: View {
  let code: String
  let copy: (() -> Void)?
  private var lines: [String] { code.components(separatedBy: "\n") }
  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Text("CSS").font(.system(size: 9, weight: .medium, design: .monospaced)).foregroundStyle(
          .tertiary)
        Spacer()
        if let copy {
          InspectorIconButton(InspectorL10n.string("Copy code"), symbol: "doc.on.doc", action: copy)
        }
      }.padding(.horizontal, 9).frame(height: 27)
      ScrollView([.horizontal, .vertical]) {
        VStack(alignment: .leading, spacing: 3) {
          ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
            HStack(alignment: .firstTextBaseline, spacing: 10) {
              Text(String(index + 1)).foregroundStyle(.tertiary).frame(
                width: 23, alignment: .trailing)
              Text(line.isEmpty ? " " : line).foregroundStyle(.primary).textSelection(.enabled)
              Spacer(minLength: 12)
            }.font(.system(size: 11, weight: .regular, design: .monospaced)).fixedSize(
              horizontal: true, vertical: false)
          }
        }.padding(.bottom, 9)
      }.defaultScrollAnchor(.topLeading).frame(
        height: min(260, CGFloat(max(1, lines.count)) * 17 + 9))
    }.background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 5))
      .environment(\.layoutDirection, .leftToRight)
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
      Text(title).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
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
    }.frame(minHeight: 24).contentShape(Rectangle()).onHover { hovered = $0 }.help(value)
  }
}

struct InspectorSwatch: View {
  let swatch: InspectorSelection.Swatch
  let format: InspectorColor.Format
  let copy: (String) -> Void
  var body: some View {
    Button {
      copy(swatch.value.formatted(format))
    } label: {
      HStack(spacing: 8) {
        RoundedRectangle(cornerRadius: 4).fill(swatch.value.color)
          .background {
            Canvas { context, size in
              for x in stride(from: 0.0, to: size.width, by: 5) {
                for y in stride(from: 0.0, to: size.height, by: 5) {
                  context.fill(
                    Path(CGRect(x: x, y: y, width: 5, height: 5)),
                    with: .color(
                      Color.primary.opacity(
                        (Int(x / 5) + Int(y / 5)).isMultiple(of: 2) ? 0.05 : 0.15)))
                }
              }
            }.clipShape(RoundedRectangle(cornerRadius: 4))
          }
          .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.primary.opacity(0.14)))
          .frame(width: 21, height: 21)
        Text(InspectorL10n.display(swatch.label)).font(.system(size: 11)).foregroundStyle(
          .secondary
        ).lineLimit(1)
        Spacer(minLength: 4)
        Text(swatch.value.formatted(format)).environment(\.layoutDirection, .leftToRight).font(
          .system(size: 11, design: .monospaced)
        )
        .lineLimit(1).truncationMode(.middle)
        Text("\(Int(((swatch.value.rgba.last ?? 1) * 100).rounded()))%")
          .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
          .frame(minWidth: 28, alignment: .trailing)
      }.frame(minHeight: 29).contentShape(Rectangle())
    }.buttonStyle(.plain).help(
      InspectorL10n.format("Copy %@", arguments: [.string(InspectorL10n.display(swatch.label))]))
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
      Image(systemName: symbol).font(.system(size: 11)).foregroundStyle(.secondary)
        .frame(width: 22, height: 24).contentShape(Rectangle())
    }.buttonStyle(.plain).help(title).accessibilityLabel(title)
  }
}

struct InspectorToast: View {
  let message: String
  var body: some View {
    Label(message, systemImage: "checkmark.circle.fill")
      .font(.system(size: 11)).padding(.horizontal, 11).padding(.vertical, 8)
      .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
      .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.primary.opacity(0.12)))
      .shadow(color: .black.opacity(0.12), radius: 5, y: 2).allowsHitTesting(false)
  }
}

struct InspectorKeycap: View {
  let key: String
  var body: some View {
    Text(key).font(.system(size: 9, design: .monospaced)).padding(.horizontal, 4)
      .frame(minWidth: 17, minHeight: 17)
      .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 3))
      .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(.primary.opacity(0.1)))
  }
}
