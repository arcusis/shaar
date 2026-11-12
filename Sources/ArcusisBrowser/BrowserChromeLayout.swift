// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import CoreGraphics

enum BrowserChromeLayout {
  static let sidebarWidth: CGFloat = 200
  static let libraryRailWidth: CGFloat = 88
  static let libraryPanelWidth: CGFloat = 300
  static let libraryPageSliver: CGFloat = 24

  static func libraryWidth(windowWidth: CGFloat, spaces: Bool) -> CGFloat {
    let available = max(0, windowWidth - libraryPageSliver)
    return spaces ? available : min(libraryRailWidth + libraryPanelWidth, available)
  }
  static let pageCardInset: CGFloat = 8
  static let pageCardRadius: CGFloat = 10
  /// Titlebar space after the traffic lights kept clickable for the sidebar toggle.
  static let titlebarAccessoryWidth: CGFloat = 36
  static let titlebarToggleLeading: CGFloat = 84
  /// Full screen has no titlebar: the toggle gets its own row at the sidebar's top-left.
  static let fullScreenToggleRowHeight: CGFloat = 36
  static let fullScreenToggleLeading: CGFloat = 12
  static let preferredCommandWidth: CGFloat = 580
  static let commandSearchHeight: CGFloat = 60
  /// Search row, two separators and footer when results are visible.
  static let commandChromeHeight: CGFloat = 94
  static let preferredResultsHeight: CGFloat = 396
  static let minimumResultsHeight: CGFloat = 76
  static let resultRowHeight: CGFloat = 38
  static let resultSectionHeaderHeight: CGFloat = 26

  static func pageWidth(windowWidth: CGFloat, leadingWidth: CGFloat) -> CGFloat {
    max(0, windowWidth - leadingWidth)
  }

  // SwiftUI mirrors horizontal offsets with layout direction.
  static let hiddenSidebarOffset = -sidebarWidth

  static func initialWebContentFrame(
    size: CGSize, sidebarVisible: Bool, isRightToLeft: Bool, findBarVisible: Bool
  ) -> CGRect {
    let pageInset = pageCardInset
    let sidebar = sidebarVisible ? sidebarWidth : 0
    let x = (isRightToLeft ? pageInset : sidebar + pageInset)
    let contentTop: CGFloat = findBarVisible ? 95 : 45
    return CGRect(
      x: x, y: contentTop, width: max(0, size.width - sidebar - 2 * pageInset),
      height: max(0, size.height - contentTop - pageInset))
  }

  static func commandPanelFrame(
    in webContent: CGRect,
    resultCount: Int = 0,
    headerCount: Int = 0
  ) -> CGRect {
    let width = min(preferredCommandWidth, webContent.width)
    let resultsHeight = commandResultsHeight(
      resultCount: resultCount, headerCount: headerCount, availableHeight: webContent.height)
    let chromeHeight = resultCount == 0 ? commandSearchHeight : commandChromeHeight
    let height = min(chromeHeight + resultsHeight, webContent.height)

    return CGRect(
      x: webContent.midX - width / 2,
      y: webContent.midY - height / 2,
      width: width,
      height: height
    )
  }

  static func commandResultsHeight(
    resultCount: Int, headerCount: Int = 0, availableHeight: CGFloat
  ) -> CGFloat {
    guard resultCount > 0 else { return 0 }
    let availableResultsHeight = max(0, availableHeight - commandChromeHeight)
    let contentHeight =
      CGFloat(resultCount) * resultRowHeight + CGFloat(headerCount) * resultSectionHeaderHeight
    let naturalHeight = min(
      max(contentHeight + 16, minimumResultsHeight),
      preferredResultsHeight
    )
    return min(naturalHeight, availableResultsHeight)
  }
}

struct StableContainerFrameSampler {
  private(set) var previousFrame: CGRect?
  private(set) var consecutiveStableSamples = 0
  let tolerance: CGFloat

  init(tolerance: CGFloat = 0.25) {
    self.tolerance = tolerance
  }

  mutating func sample(_ frame: CGRect) -> Bool {
    guard let previousFrame else {
      self.previousFrame = frame
      consecutiveStableSamples = 1
      return false
    }

    let stable = abs(frame.minX - previousFrame.minX) <= tolerance
      && abs(frame.minY - previousFrame.minY) <= tolerance
      && abs(frame.width - previousFrame.width) <= tolerance
      && abs(frame.height - previousFrame.height) <= tolerance
    self.previousFrame = frame
    consecutiveStableSamples = stable ? consecutiveStableSamples + 1 : 1
    return stable && consecutiveStableSamples >= 2
  }
}
