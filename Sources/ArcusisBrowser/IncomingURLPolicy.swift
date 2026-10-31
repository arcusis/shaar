// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import Foundation

/// Links handed over by other apps are untrusted input. They are size-bounded before parsing, and
/// credentials in the authority are refused because they can disguise the real host, as in
/// `https://bank.example@attacker.test`.
enum IncomingURLPolicy {
  static let maximumLength = 32 * 1024

  static func url(from text: String) -> URL? {
    guard text.utf8.count <= maximumLength, let url = URL(string: text),
      NavigationInput.isWebURL(url), url.user == nil, url.password == nil
    else { return nil }
    return url
  }
}
