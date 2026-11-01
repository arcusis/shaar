// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import SwiftUI

@MainActor
@Observable
final class SpacePagerState {
  var offset: CGFloat = 0
  var width: CGFloat = 0
  var reduceMotion = false
  private var rawOffset: CGFloat = 0
  private var velocity: CGFloat = 0
  private var lastTimestamp: TimeInterval = 0

  func begin() {
    rawOffset = 0
    velocity = 0
    lastTimestamp = 0
  }

  func move(delta: CGFloat, timestamp: TimeInterval, index: Int, count: Int) {
    rawOffset += delta
    if lastTimestamp > 0, timestamp > lastTimestamp {
      velocity = delta / CGFloat(timestamp - lastTimestamp)
    }
    lastTimestamp = timestamp
    if !reduceMotion {
      offset = SpacePagerDecision.rubberBand(rawOffset, index: index, count: count, width: width)
    }
  }

  func finish(store: BrowserStore, cancelled: Bool) {
    let spaces = store.session.spaces
    guard let index = spaces.firstIndex(where: { $0.id == store.session.selectedSpaceID }) else {
      offset = 0
      return
    }
    let target =
      cancelled
      ? index
      : SpacePagerDecision.targetIndex(
        index: index, count: spaces.count, offset: rawOffset, velocity: velocity, width: width)
    let animation: Animation? = reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.85)
    withAnimation(animation) {
      offset = 0
      if target != index { store.cycleSpace(by: target - index) }
    }
    begin()
  }
}

enum SpacePagerDecision {
  static func rubberBand(_ offset: CGFloat, index: Int, count: Int, width: CGFloat) -> CGFloat {
    guard width > 0, count > 0 else { return 0 }
    let minOffset = -CGFloat(count - 1 - index) * width
    let maxOffset = CGFloat(index) * width
    if offset < minOffset { return minOffset - resistance(minOffset - offset, width: width) }
    if offset > maxOffset { return maxOffset + resistance(offset - maxOffset, width: width) }
    return offset
  }

  private static func resistance(_ distance: CGFloat, width: CGFloat) -> CGFloat {
    width * 0.55 * distance / (width + 0.55 * distance)
  }

  static func targetIndex(
    index: Int, count: Int, offset: CGFloat, velocity: CGFloat, width: CGFloat
  ) -> Int {
    guard count > 0, width > 0 else { return index }
    let projected = offset + velocity * 0.12
    let step = Int((-projected / width).rounded())
    return min(count - 1, max(0, index + step))
  }
}

struct SpacePager<Content: View>: View {
  let store: BrowserStore
  let state: SpacePagerState
  let reduceMotion: Bool
  @Environment(\.layoutDirection) private var layoutDirection
  @ViewBuilder let content: (BrowserSpace) -> Content

  var body: some View {
    GeometryReader { geometry in
      let spaces = store.session.spaces
      let index = spaces.firstIndex(where: { $0.id == store.session.selectedSpaceID }) ?? 0
      HStack(spacing: 0) {
        ForEach(spaces) { space in
          content(space)
            .frame(width: geometry.size.width)
            .allowsHitTesting(space.id == store.session.selectedSpaceID)
            .accessibilityHidden(space.id != store.session.selectedSpaceID)
        }
      }
      .offset(
        x: (layoutDirection == .rightToLeft ? CGFloat(index) : -CGFloat(index))
          * geometry.size.width + state.offset
      )
      .frame(width: geometry.size.width, alignment: .leading)
      .animation(
        reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.85),
        value: store.session.selectedSpaceID
      )
      .clipped()
      .onAppear { update(geometry.size.width) }
      .onChange(of: geometry.size.width) { _, width in update(width) }
      .onChange(of: reduceMotion) { _, _ in update(geometry.size.width) }
    }
  }

  private func update(_ width: CGFloat) {
    state.width = width
    state.reduceMotion = reduceMotion
  }
}
