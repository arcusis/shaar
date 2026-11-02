// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import SwiftUI

/// Flat subviews keep their identity when the balanced row boundaries change.
struct FavoritesGridLayout: Layout {
  static let spacing: CGFloat = 8
  static let height: CGFloat = 44

  static func rows(for count: Int) -> [Int]? {
    guard (0...BrowserSession.maximumFavoritesPerProfile).contains(count) else { return nil }
    return balancedRows(for: count)
  }

  private static func balancedRows(for count: Int) -> [Int] {
    guard count > 0 else { return [] }
    let rows = (count + 3) / 4
    return (0..<rows).map { count / rows + ($0 < count % rows ? 1 : 0) }
  }

  static func frames(count: Int, width: CGFloat, isRightToLeft: Bool = false) -> [CGRect] {
    // Older catalogs can contain more than twelve. Keep them reachable; refuse new additions.
    balancedRows(for: count).enumerated().flatMap { row, columns in
      let tileWidth = max(0, (width - CGFloat(columns - 1) * spacing) / CGFloat(columns))
      return (0..<columns).map { column in
        let physicalColumn = isRightToLeft ? columns - column - 1 : column
        return CGRect(
          x: CGFloat(physicalColumn) * (tileWidth + spacing),
          y: CGFloat(row) * (height + spacing), width: tileWidth, height: height)
      }
    }
  }

  static func insertionIndex(at point: CGPoint, count: Int, width: CGFloat, rtl: Bool) -> Int {
    let slots = frames(count: count, width: width, isRightToLeft: rtl)
    return slots.indices.min {
      let left = slots[$0]
      let right = slots[$1]
      // Select the nearest destination slot, independent of the animated tiles' current frames.
      return hypot(point.x - left.midX, point.y - left.midY)
        < hypot(point.x - right.midX, point.y - right.midY)
    } ?? 0
  }

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let frames = Self.frames(count: subviews.count, width: proposal.width ?? 212)
    return CGSize(width: proposal.width ?? 212, height: frames.last?.maxY ?? 0)
  }

  func placeSubviews(
    in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
  ) {
    // SwiftUI mirrors Layout's semantic coordinates in right-to-left environments.
    let frames = Self.frames(count: subviews.count, width: bounds.width)
    for (view, frame) in zip(subviews, frames) {
      view.place(
        at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
        anchor: .topLeading, proposal: ProposedViewSize(frame.size))
    }
  }
}

private struct SidebarMotionNamespaceKey: EnvironmentKey {
  static let defaultValue: Namespace.ID? = nil
}

extension EnvironmentValues {
  var sidebarMotionNamespace: Namespace.ID? {
    get { self[SidebarMotionNamespaceKey.self] }
    set { self[SidebarMotionNamespaceKey.self] = newValue }
  }
}

private struct SidebarPageMotion: ViewModifier {
  let id: UUID
  let reduceMotion: Bool
  @Environment(\.sidebarMotionNamespace) private var namespace

  @ViewBuilder func body(content: Content) -> some View {
    if let namespace, !reduceMotion {
      content.matchedGeometryEffect(id: id, in: namespace).transition(.opacity)
    } else {
      content.transition(.opacity)
    }
  }
}

extension View {
  func sidebarPageMotion(id: UUID, reduceMotion: Bool) -> some View {
    modifier(SidebarPageMotion(id: id, reduceMotion: reduceMotion))
  }
}

/// Presentation measurements used by the offscreen sidebar probes.
struct FavoritesGridPresentation: Equatable {
  var ids: [UUID?] = []
  var refusal: String?
}

struct FavoritesGridPresentationKey: PreferenceKey {
  static let defaultValue = FavoritesGridPresentation()
  static func reduce(
    value: inout FavoritesGridPresentation, nextValue: () -> FavoritesGridPresentation
  ) {
    let next = nextValue()
    if !next.ids.isEmpty || next.refusal != nil { value = next }
  }
}
