import AppKit
import BrowserCore
import SwiftUI

/// One sidebar row for a split: a segment per tab, each with its own close button.
struct SidebarSplitRow: View {
  struct Segment: Identifiable {
    let id: UUID
    let title: String
    let favicon: NSImage?
  }

  let segments: [Segment]
  let focusedID: UUID?
  let isSelected: Bool
  let onSelect: (UUID) -> Void
  let onClose: (UUID) -> Void
  @State private var hoveredID: UUID?

  var body: some View {
    HStack(spacing: 0) {
      ForEach(Array(segments.enumerated()), id: \.element.id) { index, segment in
        if index > 0 {
          Rectangle().fill(Color.primary.opacity(0.12)).frame(width: 1, height: 18)
        }
        segmentView(segment)
      }
    }
    .padding(.horizontal, 4)
    .frame(height: 34)
    .background(
      .white.opacity(isSelected ? 0.12 : 0),
      in: RoundedRectangle(cornerRadius: 8)
    )
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Split View, \(segments.count) tabs")
  }

  private var showsTitles: Bool { segments.count <= 2 }

  private func segmentView(_ segment: Segment) -> some View {
    let hovered = hoveredID == segment.id
    return HStack(spacing: 6) {
      Button { onSelect(segment.id) } label: {
        HStack(spacing: 7) {
          favicon(segment.favicon)
          if showsTitles {
            Text(segment.title).font(.system(size: 13)).lineLimit(1).truncationMode(.tail)
          }
          Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel(segment.title)
      .accessibilityAddTraits(isSelected && focusedID == segment.id ? .isSelected : [])
      .accessibilityAction(named: Text("Close tab")) { onClose(segment.id) }

      Button { onClose(segment.id) } label: {
        Image(systemName: "xmark").font(.system(size: 9, weight: .medium))
          .frame(width: 16, height: 16)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .opacity(hovered ? 1 : 0)
      .allowsHitTesting(hovered)
      .accessibilityLabel("Close \(segment.title)")
      .help("Close \(segment.title)")
    }
    .padding(.horizontal, 6)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(
      Color.primary.opacity(isSelected && focusedID == segment.id ? 0.08 : 0),
      in: RoundedRectangle(cornerRadius: 6)
    )
    .help(segment.title)
    .onHover { inside in
      hoveredID = inside ? segment.id : hoveredID == segment.id ? nil : hoveredID
    }
  }

  @ViewBuilder
  private func favicon(_ image: NSImage?) -> some View {
    if let image {
      Image(nsImage: image).resizable().scaledToFit().frame(width: 16, height: 16)
    } else {
      Image(systemName: "globe").font(.system(size: 12)).foregroundStyle(.secondary)
    }
  }
}

extension SplitEdge {
  var menuTitle: String {
    switch self {
    case .left: "Left"
    case .right: "Right"
    case .top: "Top"
    case .bottom: "Bottom"
    }
  }
}
