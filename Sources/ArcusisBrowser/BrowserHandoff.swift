// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

enum BrowserHandoff {
  static let activityType = NSUserActivityTypeBrowsingWeb

  static func webURL(_ url: URL?) -> URL? {
    guard let url else { return nil }
    return IncomingURLPolicy.url(from: url.absoluteString)
  }

  @discardableResult
  static func update(
    _ activity: NSUserActivity, for url: URL?, title: String?
  ) -> Bool {
    guard let url = webURL(url) else {
      activity.isEligibleForHandoff = false
      return false
    }
    let pageTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
    activity.title = pageTitle?.isEmpty == false ? pageTitle : url.host()
    activity.webpageURL = url
    activity.isEligibleForHandoff = true
    activity.isEligibleForSearch = false
    activity.isEligibleForPublicIndexing = false
    return true
  }

  static func continuationURL(for activity: NSUserActivity) -> URL? {
    guard activity.activityType == activityType else { return nil }
    return webURL(activity.webpageURL)
  }

  static func continueBrowsing(_ activity: NSUserActivity, open: (URL) -> Void) {
    guard let url = continuationURL(for: activity) else { return }
    open(url)
  }
}
