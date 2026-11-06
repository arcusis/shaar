// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit

enum DefaultBrowserService {
  static func isDefault(application: URL = Bundle.main.bundleURL) -> Bool {
    let identifier = Bundle(url: application)?.bundleIdentifier
    return ["http", "https"].allSatisfy { scheme in
      guard let identifier, let url = URL(string: "\(scheme)://example.com"),
        let current = NSWorkspace.shared.urlForApplication(toOpen: url)
      else { return false }
      return Bundle(url: current)?.bundleIdentifier == identifier
    }
  }

  static func makeDefault(application: URL = Bundle.main.bundleURL) async throws {
    for scheme in ["http", "https"] {
      try await NSWorkspace.shared.setDefaultApplication(
        at: application, toOpenURLsWithScheme: scheme)
    }
  }
}
