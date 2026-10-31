// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import CoreGraphics

enum BrowserChromeLayout {
  static let sidebarWidth: CGFloat = 240
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
  /// Search field, filter chips and footer.
  static let commandChromeHeight: CGFloat = 146
  static let preferredResultsHeight: CGFloat = 396
  static let minimumResultsHeight: CGFloat = 76
  static let resultRowHeight: CGFloat = 38
  static let resultSectionHeaderHeight: CGFloat = 26

  static func pageWidth(windowWidth: CGFloat, leadingWidth: CGFloat) -> CGFloat {
    max(0, windowWidth - leadingWidth)
  }

  static func commandPanelFrame(
    in webContent: CGRect,
    resultCount: Int = 0,
    headerCount: Int = 0
  ) -> CGRect {
    let width = min(preferredCommandWidth, webContent.width)
    let resultsHeight = commandResultsHeight(
      resultCount: resultCount, headerCount: headerCount, availableHeight: webContent.height)
    let height = min(commandChromeHeight + resultsHeight, webContent.height)

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
