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
  static let preferredCommandWidth: CGFloat = 580
  static let commandChromeHeight: CGFloat = 112
  static let preferredResultsHeight: CGFloat = 330
  static let minimumResultsHeight: CGFloat = 76
  static let resultRowHeight: CGFloat = 59

  static func commandPanelFrame(
    in webContent: CGRect,
    resultCount: Int = 0
  ) -> CGRect {
    let width = min(preferredCommandWidth, webContent.width)
    let resultsHeight = commandResultsHeight(
      resultCount: resultCount, availableHeight: webContent.height)
    let height = min(commandChromeHeight + resultsHeight, webContent.height)

    return CGRect(
      x: webContent.midX - width / 2,
      y: webContent.midY - height / 2,
      width: width,
      height: height
    )
  }

  static func commandResultsHeight(resultCount: Int, availableHeight: CGFloat) -> CGFloat {
    let availableResultsHeight = max(0, availableHeight - commandChromeHeight)
    let naturalHeight = min(
      max(CGFloat(resultCount) * resultRowHeight + 16, minimumResultsHeight),
      preferredResultsHeight
    )
    return min(naturalHeight, availableResultsHeight)
  }
}
