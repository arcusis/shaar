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
      let segmentWidth = geometry.size.width / CGFloat(max(segments.count, 1))
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
          segmentView(segment, showsTitle: segmentWidth >= Self.titleMinimumWidth)
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
    .animation(.easeOut(duration: 0.12), value: hoveredID)
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
    .onTapGesture { onSelect(segment.id) }
    .onHover { inside in
      hoveredID = hoveredID.updatingTarget(segment.id, isActive: inside)
    }
    .help(segment.title)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(segment.title)
    .accessibilityAddTraits(raised ? [.isButton, .isSelected] : .isButton)
    .accessibilityAction { onSelect(segment.id) }
    .accessibilityAction(named: ShellL10n.text("Close tab")) { onClose(segment.id) }
    .sidebarPageMotion(
      id: segment.id, reduceMotion: reduceMotion || accessibilityOverrides.reduceMotion == true
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
