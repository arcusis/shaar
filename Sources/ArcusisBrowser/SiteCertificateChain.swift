// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Security

/// Certificates from the selected tab's last committed Chromium navigation.
enum SiteCertificateChain {
  struct Details {
    let certificates: [SecCertificate]
    let subjectAltNames: [String]
  }

  static func read(_ info: [String: Any]?) -> Details? {
    guard let certificate = info?["certificate"] as? [String: Any],
      let encoded = certificate["derChain"] as? [String],
      !encoded.isEmpty, encoded.count <= 16
    else { return nil }
    var certificates: [SecCertificate] = []
    var totalBytes = 0
    for value in encoded {
      guard value.utf8.count <= 87_384,
        let der = Data(base64Encoded: value),
        !der.isEmpty, der.count <= 65_536,
        totalBytes + der.count <= 262_144,
        let parsed = SecCertificateCreateWithData(nil, der as CFData)
      else { return nil }
      totalBytes += der.count
      certificates.append(parsed)
    }
    let names = (certificate["subjectAltNames"] as? [String] ?? []).prefix(128).filter {
      !$0.isEmpty && $0.utf8.count <= 255
    }
    return Details(certificates: certificates, subjectAltNames: Array(names))
  }
}
