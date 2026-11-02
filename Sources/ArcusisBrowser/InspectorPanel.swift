// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

struct InspectorPanel: View {
  @Bindable var model: InspectorModel
  var layout: InspectorLayoutSnapshot? = nil
  @State private var copyButtonFrame = CGRect.zero
  var body: some View {
    GeometryReader { geometry in
      VStack(spacing: 0) {
        header
        Divider()
        modeSwitch.padding(.vertical, 6)
        if model.panelMode == .element {
          VStack(alignment: .leading, spacing: 7) {
            if let selection = model.selection { elementHeader(selection) }
            InspectorActionsView(model: model, copyButtonFrame: $copyButtonFrame)
            if let selection = model.selection { breadcrumb(selection) }
          }.padding(.horizontal, 12).padding(.top, 5).padding(.bottom, 9)
          tabs(width: geometry.size.width)
          Divider()
        }
        content
        if let failure = model.failure ?? model.aiCopy.failure {
          Divider()
          Text(failure).font(.system(size: 11)).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading).padding(12)
        }
        if model.panelMode == .element, model.tab != .notes {
          Divider()
          footer
        }
      }.frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }
    .coordinateSpace(name: "InspectorPanel")
    .environment(\.inspectorPresentation, model.presentation)
    .environment(\.inspectorSectionScope, model.tab.rawValue)
    .overlay {
      if model.presentation.copyMenuOpen, model.panelMode == .element {
        GeometryReader { geometry in
          let width = min(230, max(180, geometry.size.width - 24))
          ZStack(alignment: .topLeading) {
            Color.clear.contentShape(Rectangle()).onTapGesture {
              model.presentation.copyMenuOpen = false
            }
            InspectorCopyMenu(model: model).frame(width: width)
              .offset(
                x: max(
                  12, min(copyButtonFrame.minX, geometry.size.width - width - 12)
                ),
                y: min(
                  copyButtonFrame.maxY + 6, max(6, geometry.size.height - 158))
              )
              .onGeometryChange(for: CGRect.self) {
                $0.frame(in: .named("InspectorPanel"))
              } action: {
                layout?.copyMenuFrame = $0
              }
          }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
      }
    }
    .overlay(alignment: .bottom) {
      if let message = model.presentation.toast {
        InspectorToast(message: message).padding(.horizontal, 12)
          .padding(.bottom, model.panelMode == .element && model.tab != .notes ? 39 : 12)
      }
    }
    .onChange(of: model.selection?.id) { model.presentation.copyMenuOpen = false }
    .onExitCommand {
      if model.presentation.copyMenuOpen {
        model.presentation.copyMenuOpen = false
      } else {
        model.close()
      }
    }
    .onMoveCommand(perform: moveAction)
  }

  private var header: some View {
    HStack(spacing: 7) {
      Image(systemName: "viewfinder").font(.system(size: 12)).foregroundStyle(.secondary)
      Text("Inspector").font(.system(size: 12, weight: .semibold))
      Spacer()
      InspectorIconButton("Pick an element", symbol: "cursorarrow.rays", action: model.pick)
      InspectorIconButton(
        model.mode == .locked ? "Unlock element" : "Lock element",
        symbol: model.mode == .locked ? "lock.fill" : "lock.open", action: model.toggleLock
      )
      .disabled(model.selection == nil || model.panelMode == .page)
      InspectorIconButton("Close Inspector", symbol: "xmark", action: model.close)
    }.padding(.horizontal, 12).frame(height: 34)
  }

  private var modeSwitch: some View {
    HStack(spacing: 2) {
      ForEach(InspectorModel.PanelMode.allCases, id: \.self) { value in
        Button {
          model.setPanelMode(value)
        } label: {
          Text(value.rawValue).font(
            .system(size: 11, weight: model.panelMode == value ? .medium : .regular)
          )
          .foregroundStyle(model.panelMode == value ? .primary : .secondary)
          .frame(width: 72, height: 23)
          .background(
            model.panelMode == value ? Color(nsColor: .controlBackgroundColor) : .clear,
            in: RoundedRectangle(cornerRadius: 4))
        }.buttonStyle(.plain).accessibilityAddTraits(model.panelMode == value ? .isSelected : [])
      }
    }.padding(2).background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
      .accessibilityLabel("Inspector mode")
  }

  private func elementHeader(_ selection: InspectorSelection) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text(elementChip(selection)).font(.system(size: 11, weight: .medium, design: .monospaced))
          .lineLimit(1).truncationMode(.middle).padding(.horizontal, 6).padding(.vertical, 3)
          .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 4)).help(
            String(elementChip(selection).characters))
        Spacer(minLength: 0)
        Text(selection.dimensions).font(.system(size: 10, design: .monospaced)).foregroundStyle(
          .secondary
        ).fixedSize()
      }
      if let component = selection.component, InspectorAIFormatter.readableComponent(component) {
        Label(component, systemImage: "cube").font(.system(size: 11)).foregroundStyle(.secondary)
          .lineLimit(1).truncationMode(.middle)
      }
    }
  }

  private func elementChip(_ selection: InspectorSelection) -> AttributedString {
    var tag = AttributedString("<" + selection.tag + ">")
    tag.foregroundColor = .purple
    if selection.identifier != nil || selection.classNames != nil {
      if let id = selection.identifier, !id.isEmpty {
        var text = AttributedString(" #" + id)
        text.foregroundColor = .orange
        tag.append(text)
      }
      for name in (selection.classNames ?? []).prefix(2) {
        var text = AttributedString(" ." + name)
        text.foregroundColor = .blue
        tag.append(text)
      }
      return tag
    }
    let suffix =
      selection.label.hasPrefix(selection.tag)
      ? String(selection.label.dropFirst(selection.tag.count)) : ""
    var identifier = AttributedString(suffix.isEmpty ? "" : " " + suffix)
    identifier.foregroundColor = suffix.hasPrefix("#") ? .orange : .blue
    tag.append(identifier)
    return tag
  }

  private func tabs(width: CGFloat) -> some View {
    HStack(spacing: 0) {
      ForEach(InspectorModel.Tab.allCases, id: \.self) { value in
        Button {
          model.presentation.copyMenuOpen = false
          model.tab = value
        } label: {
          HStack(spacing: 4) {
            Image(systemName: symbol(value)).font(.system(size: 10))
            if width >= 400 {
              Text(value.rawValue).font(.system(size: 11)).lineLimit(1).fixedSize()
            }
          }.fontWeight(model.tab == value ? .semibold : .regular)
            .foregroundStyle(model.tab == value ? .primary : .secondary)
            .padding(.horizontal, width >= 400 ? 7 : 0)
            .frame(maxWidth: width >= 400 ? nil : .infinity, minHeight: 32).contentShape(
              Rectangle()
            )
            .overlay(alignment: .bottom) {
              if model.tab == value {
                Rectangle().fill(.primary.opacity(0.8)).frame(height: 2).padding(.horizontal, 7)
              }
            }
        }.buttonStyle(.plain).help(value.rawValue).accessibilityLabel(value.rawValue)
          .accessibilityAddTraits(model.tab == value ? .isSelected : [])
          .onGeometryChange(for: CGRect.self) {
            $0.frame(in: .named("InspectorPanel"))
          } action: {
            layout?.tabFrames[value.rawValue] = $0
          }
      }
    }.frame(maxWidth: .infinity).padding(.horizontal, 6).accessibilityLabel("Inspector section")
  }

  private func symbol(_ tab: InspectorModel.Tab) -> String {
    switch tab {
    case .design: "slider.horizontal.3"
    case .styles: "chevron.left.forwardslash.chevron.right"
    case .component: "cube"
    case .accessibility: "accessibility"
    case .assets: "photo.on.rectangle"
    case .notes: "square.and.pencil"
    }
  }

  private func breadcrumb(_ selection: InspectorSelection) -> some View {
    ScrollViewReader { proxy in
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 3) {
          ForEach(selection.ancestors) { ancestor in
            if ancestor.id != selection.ancestors.first?.id {
              Image(systemName: "chevron.right").font(.system(size: 6)).foregroundStyle(.tertiary)
            }
            Button {
              model.selectAncestor(ancestor.id)
            } label: {
              Text(ancestor.label).font(.system(size: 10, design: .monospaced)).lineLimit(1)
                .foregroundStyle(ancestor.id == selection.id ? .primary : .secondary)
                .padding(.horizontal, 5).frame(height: 21)
                .background(
                  .primary.opacity(ancestor.id == selection.id ? 0.05 : 0),
                  in: RoundedRectangle(cornerRadius: 3))
            }.buttonStyle(.plain).help("Inspect \(ancestor.label)").id(ancestor.id)
          }
        }.fixedSize(horizontal: true, vertical: false)
      }.frame(height: 23).environment(\.layoutDirection, .leftToRight)
        .onAppear { proxy.scrollTo(selection.id, anchor: .trailing) }
        .onChange(of: selection.id) { proxy.scrollTo(selection.id, anchor: .trailing) }
    }
  }

  @ViewBuilder private var content: some View {
    if model.panelMode == .page, let tools = model.pageTools {
      InspectorPageToolsView(inspector: model, model: tools)
    } else if model.tab == .notes {
      InspectorNotesView(model: model.aiCopy)
    } else if let selection = model.selection {
      if model.tab == .styles {
        InspectorStylesView(inspector: model, model: model.styles)
      } else if [.component, .accessibility, .assets].contains(model.tab) {
        InspectorDetailsView(inspector: model, model: model.details)
      } else {
        InspectorDesignView(model: model, selection: selection)
      }
    } else {
      VStack(spacing: 10) {
        Image(systemName: "cursorarrow.rays").font(.system(size: 24, weight: .light))
          .foregroundStyle(.tertiary)
        Text("Inspect any element").font(.system(size: 13, weight: .medium))
        Text("Hover to preview. Click to lock.\nUse arrow keys to explore the DOM.")
          .font(.system(size: 11)).foregroundStyle(.secondary).multilineTextAlignment(.center)
      }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(24)
    }
  }

  private var footer: some View {
    HStack(spacing: 4) {
      InspectorKeycap(key: "↑")
      InspectorKeycap(key: "↓")
      Text("Parent / child").font(.system(size: 10))
      Spacer(minLength: 2)
      InspectorKeycap(key: "←")
      InspectorKeycap(key: "→")
      Text("Siblings").font(.system(size: 10))
      Spacer(minLength: 2)
      InspectorKeycap(key: "esc")
      Text("Exit").font(.system(size: 10))
    }.foregroundStyle(.secondary).padding(.horizontal, 10).frame(height: 29)
      .environment(\.layoutDirection, .leftToRight)
  }

  private var moveAction: ((MoveCommandDirection) -> Void)? {
    guard model.panelMode == .element, model.tab != .notes, !model.presentation.copyMenuOpen else {
      return nil
    }
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
}
