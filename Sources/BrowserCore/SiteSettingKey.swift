// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// The site a per-site setting applies to: the lowercased host of an http or https page.
/// Other schemes have no site settings.
public enum SiteSettingKey {
  public static func site(for url: URL) -> String? {
    guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
      var host = url.host(percentEncoded: false)?.lowercased(), !host.isEmpty
    else { return nil }
    if host.hasSuffix(".") { host.removeLast() }
    return host.isEmpty ? nil : host
  }
}
