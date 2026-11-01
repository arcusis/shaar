// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import CryptoKit
import Foundation
import Network
import Security

/// Reads the certificate chain a site presents during a TLS handshake. The pinned engine reports
/// only a summary of the page's leaf certificate, so callers accept a chain only when its leaf
/// matches the SHA-256 fingerprint Chromium reports for the page.
enum SiteCertificateChain {
  struct Failure: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = ShellL10n.string(message) }
  }

  /// DER certificates, leaf first. The connection closes once the handshake finishes; no request
  /// is sent to the site.
  static func fetch(host: String, port: UInt16, timeout: TimeInterval = 10) async throws -> [Data] {
    guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
      throw Failure("The site's address is not valid.")
    }
    let queue = DispatchQueue(label: "com.arcusis.browser.site-certificate")
    let handshake = Handshake()
    let options = NWProtocolTLS.Options()
    sec_protocol_options_set_verify_block(
      options.securityProtocolOptions,
      { _, trust, complete in
        handshake.record(
          SecTrustCopyCertificateChain(sec_trust_copy_ref(trust).takeRetainedValue()))
        // Chromium already judged this certificate; this handshake only reads it.
        complete(true)
      }, queue)
    let connection = NWConnection(
      host: NWEndpoint.Host(host), port: endpointPort,
      using: NWParameters(tls: options, tcp: NWProtocolTCP.Options()))
    return try await withCheckedThrowingContinuation { continuation in
      handshake.onFinish = { chain in
        connection.cancel()
        if chain.isEmpty {
          continuation.resume(throwing: Failure("The site did not present a certificate."))
        } else {
          continuation.resume(returning: chain)
        }
      }
      connection.stateUpdateHandler = { state in
        switch state {
        case .ready, .failed, .cancelled, .waiting: handshake.finish()
        default: break
        }
      }
      queue.asyncAfter(deadline: .now() + timeout) { handshake.finish() }
      connection.start(queue: queue)
    }
  }

  /// Uppercase hex SHA-256 of a DER certificate without separators.
  static func fingerprint(of certificate: Data) -> String {
    SHA256.hash(data: certificate).map { String(format: "%02X", $0) }.joined()
  }

  /// Compares fingerprints regardless of case and the colon separators Chromium uses.
  static func fingerprint(_ value: String, matches certificate: Data) -> Bool {
    value.replacingOccurrences(of: ":", with: "").uppercased() == fingerprint(of: certificate)
  }
}

/// Collects one handshake's chain and reports it exactly once. All calls run on its queue.
private final class Handshake: @unchecked Sendable {
  var onFinish: (([Data]) -> Void)?
  private var chain: [Data] = []

  func record(_ certificates: CFArray?) {
    let values = certificates as? [SecCertificate] ?? []
    chain = values.map { SecCertificateCopyData($0) as Data }
  }

  func finish() {
    guard let onFinish else { return }
    self.onFinish = nil
    onFinish(chain)
  }
}
