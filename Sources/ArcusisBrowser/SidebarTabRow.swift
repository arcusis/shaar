import AppKit
import SwiftUI

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
  let onSelect: () -> Void
  let onClose: () -> Void
  let onHoverChanged: (Bool) -> Void
  @FocusState private var focusedControl: Control?

  private var showsClose: Bool {
    closeIsVisible || isSelected || focusedControl != nil
  }

  var body: some View {
    HStack(spacing: 8) {
      Button(action: onSelect) {
        HStack(spacing: 9) {
          if let favicon {
            Image(nsImage: favicon)
              .resizable()
              .scaledToFit()
              .frame(width: 14, height: 14)
          } else {
            Image(systemName: isPinned ? "pin" : "globe")
              .font(.system(size: 12))
              .foregroundStyle(.secondary)
          }
          Text(title).font(.system(size: 13)).lineLimit(1).truncationMode(.tail)
          Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .focused($focusedControl, equals: .select)
      .accessibilityLabel(title)
      .accessibilityAddTraits(isSelected ? .isSelected : [])
      .accessibilityAction(named: Text("Close tab"), onClose)
      .accessibilityIdentifier("sidebar-tab-select-\(tabID.uuidString)")

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
      .accessibilityLabel("Close \(title)")
      .help("Close \(title)")
      .accessibilityIdentifier("sidebar-tab-close-\(tabID.uuidString)")
    }
    .padding(10)
    .background(
      .white.opacity(isSelected ? 0.43 : 0),
      in: RoundedRectangle(cornerRadius: 8)
    )
    .onHover(perform: onHoverChanged)
  }
}
