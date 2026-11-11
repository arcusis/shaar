// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Security
import SwiftUI

/// Why the page connection is or is not secure, using the level site controls already report.
enum ShaarPageConnection: Equatable, Sendable {
  case secure
  case http
  case certificateError
  case mixedContent
  case unavailable

  var title: String {
    switch self {
    case .secure: "Secure"
    case .http, .certificateError, .mixedContent: "Not Secure"
    case .unavailable: "Unavailable"
    }
  }

  var explanation: String {
    switch self {
    case .secure: "The connection to this site is encrypted."
    case .http: "This page was loaded over HTTP."
    case .certificateError: "This page has a certificate error."
    case .mixedContent: "This page includes content loaded over an insecure connection."
    case .unavailable: "Connection security is unavailable for this page."
    }
  }

  var symbol: String {
    switch self {
    case .secure: "lock.fill"
    case .unavailable: "questionmark.circle"
    case .http, .certificateError, .mixedContent: "exclamationmark.triangle.fill"
    }
  }
}

struct ShaarCertificateIdentity: Equatable, Sendable {
  var subject: String
  var issuer: String
  var notBefore: Date
  var notAfter: Date
  var subjectAltNames: [String] = []
  var chainSubjects: [String] = []
}

struct ShaarDevToolsSecuritySummary: Equatable, Sendable {
  var connection: ShaarPageConnection
  var certificate: ShaarCertificateIdentity?

  static func make(
    url: URL, engineLevel: String?, certificate: ShaarCertificateIdentity?
  ) -> ShaarDevToolsSecuritySummary {
    ShaarDevToolsSecuritySummary(
      connection: connection(url: url, engineLevel: engineLevel),
      certificate: certificate)
  }

  static func connection(url: URL, engineLevel: String?) -> ShaarPageConnection {
    if let known = connection(engineLevel: engineLevel) { return known }
    if url.scheme?.lowercased() == "http" { return .http }
    return .unavailable
  }

  private static func connection(engineLevel: String?) -> ShaarPageConnection? {
    switch engineLevel {
    case "secure": .secure
    case "insecure": .http
    case "certificateError": .certificateError
    case "mixed": .mixedContent
    case "unavailable": .unavailable
    default: nil
    }
  }
}

enum ShaarCertificateIdentityReader {
  static func read(_ details: SiteCertificateChain.Details) -> ShaarCertificateIdentity? {
    guard let certificate = details.certificates.first,
      var identity = leaf(from: certificate)
    else { return nil }
    identity.subjectAltNames = details.subjectAltNames
    identity.chainSubjects = details.certificates.enumerated().map { index, certificate in
      (SecCertificateCopySubjectSummary(certificate) as String?) ?? "Certificate \(index + 1)"
    }
    return identity
  }

  /// Subject, issuer, and validity of one certificate the site controls already loaded.
  static func leaf(from certificate: SecCertificate) -> ShaarCertificateIdentity? {
    let keys =
      [
        kSecOIDX509V1SubjectName, kSecOIDX509V1IssuerName,
        kSecOIDX509V1ValidityNotBefore, kSecOIDX509V1ValidityNotAfter,
      ] as CFArray
    guard let values = SecCertificateCopyValues(certificate, keys, nil) as? NSDictionary
    else { return nil }
    guard let subject = distinguishedName(values[kSecOIDX509V1SubjectName]),
      let issuer = distinguishedName(values[kSecOIDX509V1IssuerName]),
      let notBefore = date(values[kSecOIDX509V1ValidityNotBefore]),
      let notAfter = date(values[kSecOIDX509V1ValidityNotAfter])
    else { return nil }
    return ShaarCertificateIdentity(
      subject: subject, issuer: issuer, notBefore: notBefore, notAfter: notAfter)
  }

  private static func distinguishedName(_ entry: Any?) -> String? {
    guard let entry = entry as? NSDictionary,
      let items = entry[kSecPropertyKeyValue] as? NSArray
    else { return nil }
    var parts: [String] = []
    for case let part as NSDictionary in items {
      guard let label = part[kSecPropertyKeyLabel] as? String,
        let value = part[kSecPropertyKeyValue] as? String,
        !label.isEmpty, !value.isEmpty
      else { continue }
      parts.append("\(label)=\(value)")
    }
    guard !parts.isEmpty else { return nil }
    return parts.joined(separator: ", ")
  }

  private static func date(_ entry: Any?) -> Date? {
    guard let entry = entry as? NSDictionary else { return nil }
    let value = entry[kSecPropertyKeyValue]
    if let date = value as? Date { return date }
    if let number = value as? NSNumber {
      return Date(timeIntervalSinceReferenceDate: number.doubleValue)
    }
    return nil
  }
}

enum ShaarCertificateDateText {
  static func string(from date: Date) -> String {
    date.formatted(date: .abbreviated, time: .omitted)
  }
}
