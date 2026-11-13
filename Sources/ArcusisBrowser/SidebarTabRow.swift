// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import SwiftUI

/// How a sidebar tab title is measured. The close control stays in the row for focus,
/// but it must not reserve width while it is hidden: that reservation was clipping
/// “Shaar DevTools QA” to “Shaar DevToo…”.
enum SidebarTabTitle {
  static let fontSize: CGFloat = 13
  static let minimumScale: CGFloat = 0.85
  /// Room kept clear of the close glyph once that control is actually shown.
  static let closeReserve: CGFloat = 22

  static func isMidwordClip(_ painted: String) -> Bool {
    painted.range(of: #"Shaar DevToo(?!ls)"#, options: [.regularExpression, .caseInsensitive])
      != nil
  }

  static func showsFullTitle(_ painted: String) -> Bool {
    painted.range(of: #"Shaar DevTools\b"#, options: [.regularExpression, .caseInsensitive]) != nil
  }

  static func accessibilityLabel(title: String, isSleeping: Bool) -> String {
    guard isSleeping else { return title }
    return ShellL10n.format(
      "%@, %@", arguments: [.string(title), .string(ShellL10n.string("Sleeping"))])
  }
}

struct SidebarTabRow: View {
  private enum Control: Hashable {
    case select
    case close
  }

  let tabID: UUID
  let title: String
  let favicon: NSImage?
  let isPinned: Bool
  let isSelected: Bool
  let closeIsVisible: Bool
  var isSleeping: Bool = false
  let onSelect: () -> Void
  let onClose: () -> Void
  let onHoverChanged: (Bool) -> Void
  @FocusState private var focusedControl: Control?

  private var showsClose: Bool {
    closeIsVisible || focusedControl != nil
  }

  var body: some View {
    ZStack(alignment: .trailing) {
      selectButton
      closeButton
    }
    .padding(.horizontal, 10)
    .frame(height: 34)
    .background(
      .white.opacity(isSelected ? 0.12 : 0),
      in: RoundedRectangle(cornerRadius: 8)
    )
    .onHover(perform: onHoverChanged)
  }

  private var selectButton: some View {
    Button(action: onSelect) {
      HStack(spacing: 9) {
        tabIcon
        Text(title)
          .font(.system(size: SidebarTabTitle.fontSize))
          .lineLimit(1)
          .minimumScaleFactor(SidebarTabTitle.minimumScale)
          .truncationMode(.tail)
          .padding(.trailing, showsClose ? SidebarTabTitle.closeReserve : 0)
        if isSleeping {
          Image(systemName: "moon.zzz")
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("sidebar-tab-sleeping-\(tabID.uuidString)")
            .accessibilityLabel(ShellL10n.string("Sleeping"))
        }
        Spacer(minLength: 0)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .frame(maxWidth: .infinity, alignment: .leading)
    .focused($focusedControl, equals: .select)
    .accessibilityLabel(SidebarTabTitle.accessibilityLabel(title: title, isSleeping: isSleeping))
    .accessibilityAddTraits(isSelected ? .isSelected : [])
    .accessibilityAction(named: ShellL10n.text("Close tab"), onClose)
    .accessibilityIdentifier("sidebar-tab-select-\(tabID.uuidString)")
  }

  @ViewBuilder private var tabIcon: some View {
    if let favicon {
      Image(nsImage: favicon)
        .resizable()
        .scaledToFit()
        .frame(width: 16, height: 16)
    } else {
      Image(systemName: isPinned ? "pin" : "globe")
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
    }
  }

  private var closeButton: some View {
    Button(action: onClose) {
      Image(systemName: "xmark").font(.system(size: 9, weight: .medium))
        .frame(width: 18, height: 18)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .focused($focusedControl, equals: .close)
    .opacity(showsClose ? 1 : 0)
    .allowsHitTesting(showsClose)
    .accessibilityHidden(!showsClose)
    .accessibilityLabel(ShellL10n.format("Close %@", arguments: [.string(title)]))
    .help(ShellL10n.format("Close %@", arguments: [.string(title)]))
    .accessibilityIdentifier("sidebar-tab-close-\(tabID.uuidString)")
  }
}
