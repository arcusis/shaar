// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Locates a SwiftPM resource bundle staged inside a packaged app.
///
/// `fallback` is only the unpackaged SwiftPM bundle used by `swift test` and
/// `swift run`. A packaged `.app` never evaluates it, so a missing bundle
/// cannot reach `Bundle.module` and trap.
public enum PackagedResourceBundle {
  public static func resolve(
    named name: String, in host: Bundle, fallback: () -> Bundle
  ) -> Bundle? {
    if let packaged = stagedBundle(named: name, in: host) {
      return packaged
    }
    if hostIsPackagedApp(host) {
      return nil
    }
    return fallback()
  }

  private static func stagedBundle(named name: String, in host: Bundle) -> Bundle? {
    guard let url = host.url(forResource: name, withExtension: "bundle") else { return nil }
    return Bundle(url: url)
  }

  private static func hostIsPackagedApp(_ host: Bundle) -> Bool {
    host.bundleURL.pathExtension == "app"
  }
}
