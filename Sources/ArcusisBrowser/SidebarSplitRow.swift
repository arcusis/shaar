// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import BrowserCore
import SwiftUI

/// One sidebar row for a split: a segment per tab. Hovering a segment swaps its icon for a
/// close button; the focused pane's segment is raised.
struct SidebarSplitRow: View {
  struct Segment: Identifiable {
    let id: UUID
    let title: String
    let favicon: NSImage?
  }

  static let titleMinimumWidth: CGFloat = 64

  static func isActivationKey(_ key: KeyEquivalent) -> Bool {
    key == .return || key == .space
  }

  static func reduceMotionEnabled(systemSetting: Bool, override: Bool?) -> Bool {
    systemSetting || override == true
  }

  static func hoverAnimation(reduceMotion: Bool) -> Animation? {
    reduceMotion ? nil : .easeOut(duration: 0.12)
  }

  static func hoverAnimation(systemSetting: Bool, override: Bool?) -> Animation? {
    reduceMotionEnabled(systemSetting: systemSetting, override: override)
      ? nil : .easeOut(duration: 0.12)
  }

  static func keyboardActivationAction(_ action: @escaping () -> Void) -> () -> KeyPress.Result {
    { action(); return .handled }
  }

  static func showsTitles(
    totalWidth: CGFloat, segmentCount: Int, hasStackDragHandle: Bool
  ) -> Bool {
    guard segmentCount > 0 else { return false }
    let handleWidth: CGFloat = hasStackDragHandle ? 18 : 0
    let gaps = segmentCount - 1 + (hasStackDragHandle ? 1 : 0)
    let contentWidth = totalWidth - 6 - handleWidth - CGFloat(gaps) * 2
    return contentWidth / CGFloat(segmentCount) >= titleMinimumWidth
  }

  let segments: [Segment]
  let focusedID: UUID?
  let isSelected: Bool
  let onSelect: (UUID) -> Void
  let onClose: (UUID) -> Void
  let onDrag: (UUID) -> SidebarTransfer
  var memberMenu: ((UUID) -> AnyView)? = nil
  var onStackDrag: (() -> SidebarTransfer)? = nil
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.browserChromeAccessibilityOverrides) private var accessibilityOverrides
  @State private var hoveredID: UUID?

  var body: some View {
    GeometryReader { geometry in
      let showsTitle = Self.showsTitles(
        totalWidth: geometry.size.width, segmentCount: segments.count,
        hasStackDragHandle: onStackDrag != nil)
      HStack(spacing: 2) {
        if let onStackDrag {
          Image(systemName: "rectangle.split.2x1")
            .font(.system(size: 10)).foregroundStyle(.secondary)
            .frame(width: 18, height: 28).contentShape(Rectangle())
            .help(ShellL10n.string("Drag split stack"))
            .accessibilityLabel(ShellL10n.string("Drag split stack"))
            .draggable(onStackDrag())
        }
        ForEach(segments) { segment in
          segmentView(segment, showsTitle: showsTitle)
        }
      }
      .padding(3)
    }
    .frame(height: 36)
    .background(
      Color.primary.opacity(isSelected ? 0.10 : 0.05), in: RoundedRectangle(cornerRadius: 10)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
    )
    .animation(
      Self.hoverAnimation(
        systemSetting: reduceMotion, override: accessibilityOverrides.reduceMotion),
      value: hoveredID)
    .accessibilityElement(children: .contain)
    .accessibilityLabel(ShellL10n.plural("Split View, %d tabs", count: segments.count))
  }

  private func segmentView(_ segment: Segment, showsTitle: Bool) -> some View {
    let raised = isSelected && focusedID == segment.id
    let hovered = hoveredID == segment.id
    return HStack(spacing: 6) {
      leadingControl(segment, hovered: hovered)
      if showsTitle {
        Text(segment.title)
          .font(.system(size: 12.5, weight: raised ? .medium : .regular))
          .foregroundStyle(raised ? .primary : .secondary)
          .lineLimit(1)
          .truncationMode(.tail)
      }
    }
    .padding(.horizontal, 7)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: showsTitle ? .leading : .center)
    .background {
      RoundedRectangle(cornerRadius: 7)
        .fill(Color.primary.opacity(segmentFill(raised: raised, hovered: hovered)))
        .shadow(color: .black.opacity(raised ? 0.18 : 0), radius: 2, y: 1)
    }
    .contentShape(RoundedRectangle(cornerRadius: 7))
    .simultaneousGesture(TapGesture().onEnded { onSelect(segment.id) })
    .focusable()
    .onKeyPress(keys: [.return, .space]) { press in
      guard Self.isActivationKey(press.key) else { return .ignored }
      onSelect(segment.id)
      return .handled
    }
    .onHover { inside in
      hoveredID = hoveredID.updatingTarget(segment.id, isActive: inside)
    }
    .help(segment.title)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(segment.title)
    .accessibilityAddTraits(raised ? [.isButton, .isSelected] : .isButton)
    .accessibilityAction { onSelect(segment.id) }
    .accessibilityAction(named: ShellL10n.text("Close tab")) { onClose(segment.id) }
    .focusable()
    .onKeyPress(.return, action: Self.keyboardActivationAction { onSelect(segment.id) })
    .onKeyPress(.space, action: Self.keyboardActivationAction { onSelect(segment.id) })
    .sidebarPageMotion(
      id: segment.id,
      reduceMotion: Self.reduceMotionEnabled(
        systemSetting: reduceMotion, override: accessibilityOverrides.reduceMotion)
    )
    .draggable(onDrag(segment.id))
    .contextMenu { if let memberMenu { memberMenu(segment.id) } }
  }

  private func segmentFill(raised: Bool, hovered: Bool) -> Double {
    if raised { return 0.14 }
    return hovered ? 0.06 : 0
  }

  @ViewBuilder
  private func leadingControl(_ segment: Segment, hovered: Bool) -> some View {
    if hovered {
      Button {
        onClose(segment.id)
      } label: {
        Image(systemName: "xmark")
          .font(.system(size: 9, weight: .bold))
          .frame(width: 16, height: 16)
          .background(Color.primary.opacity(0.12), in: Circle())
          .contentShape(Circle())
      }
      .buttonStyle(.plain)
      .help(ShellL10n.format("Close %@", arguments: [.string(segment.title)]))
      .accessibilityLabel(ShellL10n.format("Close %@", arguments: [.string(segment.title)]))
    } else if let favicon = segment.favicon {
      Image(nsImage: favicon).resizable().scaledToFit().frame(width: 16, height: 16)
    } else {
      Image(systemName: "globe").font(.system(size: 12)).foregroundStyle(.secondary)
        .frame(width: 16, height: 16)
    }
  }
}

extension SplitEdge {
  static func forPhysicalRight(isRightToLeft: Bool) -> SplitEdge {
    isRightToLeft ? .left : .right
  }

  func menuTitle(isRightToLeft: Bool = false) -> String {
    switch self {
    case .left: ShellL10n.string(isRightToLeft ? "Right" : "Left")
    case .right: ShellL10n.string(isRightToLeft ? "Left" : "Right")
    case .top: ShellL10n.string("Top")
    case .bottom: ShellL10n.string("Bottom")
    }
  }
}
