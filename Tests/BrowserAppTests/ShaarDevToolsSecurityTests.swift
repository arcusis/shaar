// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import Foundation
import Security
import SwiftUI
import Testing

@testable import ArcusisBrowser

@Suite struct ShaarDevToolsSecuritySummaryTests {
  @Test func secureSummaryNamesAnEncryptedConnection() {
    let summary = ShaarDevToolsSecuritySummary.make(
      url: URL(string: "https://example.com/")!, engineLevel: "secure", certificate: nil)
    #expect(summary.connection == .secure)
    #expect(summary.connection.title == "Secure")
    #expect(summary.connection.explanation == "The connection to this site is encrypted.")
    #expect(summary.certificate == nil)
  }

  @Test func httpSummaryExplainsTheUnencryptedPage() {
    let fromLevel = ShaarDevToolsSecuritySummary.make(
      url: URL(string: "http://localhost:3000/")!, engineLevel: "insecure", certificate: nil)
    let fromScheme = ShaarDevToolsSecuritySummary.make(
      url: URL(string: "http://news.example/")!, engineLevel: nil, certificate: nil)
    #expect(fromLevel.connection == .http)
    #expect(fromScheme.connection == .http)
    #expect(fromScheme.connection.title == "Not Secure")
    #expect(fromScheme.connection.explanation == "This page was loaded over HTTP.")
    #expect(fromScheme.certificate == nil)
  }

  @Test func certificateErrorAndMixedContentKeepTheirReasons() {
    let certificate = ShaarDevToolsSecuritySummary.make(
      url: URL(string: "https://expired.example/")!, engineLevel: "certificateError",
      certificate: nil)
    let mixed = ShaarDevToolsSecuritySummary.make(
      url: URL(string: "https://example.com/")!, engineLevel: "mixed", certificate: nil)
    #expect(certificate.connection == .certificateError)
    #expect(certificate.connection.explanation == "This page has a certificate error.")
    #expect(mixed.connection == .mixedContent)
    #expect(
      mixed.connection.explanation
        == "This page includes content loaded over an insecure connection.")
  }

  @Test func certificateReaderReportsSubjectIssuerAndDates() throws {
    let certificate = try #require(
      SecCertificateCreateWithData(nil, SecurityCertificateFixture.der as CFData))
    let identity = try #require(ShaarCertificateIdentityReader.leaf(from: certificate))
    #expect(identity.subject.contains("localhost"))
    #expect(!identity.subject.contains("Test CA"))
    #expect(identity.issuer.contains("Shaar Test CA"))
    #expect(abs(identity.notBefore.timeIntervalSince(SecurityCertificateFixture.notBefore)) < 1)
    #expect(abs(identity.notAfter.timeIntervalSince(SecurityCertificateFixture.notAfter)) < 1)
  }
}

@Suite @MainActor struct ShaarDevToolsSecurityModelTests {
  @Test func refreshAppliesASecureSummaryAndANewPageClearsIt() async {
    let defaults = UserDefaults(suiteName: "ShaarDevToolsSecurity.\(UUID().uuidString)")!
    let page = URL(string: "https://example.com/")!
    let target = SiteControlTarget(tabID: UUID(), profileID: UUID(), url: page)
    let shell = ShaarDevToolsModel(target: target, layoutDefaults: defaults)
    #expect(shell.securitySummary.connection == .unavailable)
    let identity = ShaarCertificateIdentity(
      subject: "localhost", issuer: "Shaar Test CA",
      notBefore: SecurityCertificateFixture.notBefore,
      notAfter: SecurityCertificateFixture.notAfter)
    shell.loadSecurity = { requested in
      ShaarDevToolsSecuritySummary.make(
        url: requested.url, engineLevel: "secure", certificate: identity)
    }
    await shell.refreshSecurity()
    #expect(shell.securitySummary.connection == .secure)
    #expect(shell.securitySummary.certificate?.subject == "localhost")
    #expect(shell.securitySummary.certificate?.issuer == "Shaar Test CA")

    let next = SiteControlTarget(
      tabID: target.tabID, profileID: target.profileID, url: URL(string: "http://localhost/")!)
    shell.updateTarget(next)
    #expect(shell.securitySummary.connection == .http)
    #expect(shell.securitySummary.certificate == nil)
  }

  @Test func securityPanelRendersOffscreenForEachConnection() throws {
    _ = NSApplication.shared
    #expect(ShaarPageConnection.secure.symbol == "lock.fill")
    #expect(ShaarPageConnection.http.symbol == "exclamationmark.triangle.fill")
    #expect(ShaarPageConnection.unavailable.symbol == "questionmark.circle")
    #expect(ShaarPageConnection.unavailable.title == "Unavailable")
    #expect(
      ShaarPageConnection.unavailable.explanation
        == "Connection security is unavailable for this page.")
    let defaults = UserDefaults(suiteName: "ShaarDevToolsSecurity.\(UUID().uuidString)")!
    let page = URL(string: "https://example.com/")!
    let target = SiteControlTarget(tabID: UUID(), profileID: UUID(), url: page)
    let shell = ShaarDevToolsModel(target: target, layoutDefaults: defaults)
    let identity = ShaarCertificateIdentity(
      subject: "localhost", issuer: "Shaar Test CA",
      notBefore: SecurityCertificateFixture.notBefore,
      notAfter: SecurityCertificateFixture.notAfter)
    shell.securitySummary = ShaarDevToolsSecuritySummary(connection: .secure, certificate: identity)
    let secure = try VisualCapture.pngOffscreen(
      ShaarDevToolsSecurityPanel(model: shell), size: NSSize(width: 520, height: 280))
    shell.securitySummary = ShaarDevToolsSecuritySummary(
      connection: .certificateError, certificate: nil)
    let missing = try VisualCapture.pngOffscreen(
      ShaarDevToolsSecurityPanel(model: shell), size: NSSize(width: 520, height: 180))
    shell.securitySummary = ShaarDevToolsSecuritySummary(connection: .unavailable, certificate: nil)
    let unavailable = try VisualCapture.pngOffscreen(
      ShaarDevToolsSecurityPanel(model: shell), size: NSSize(width: 520, height: 180))
    let httpTarget = SiteControlTarget(
      tabID: target.tabID, profileID: target.profileID, url: URL(string: "http://localhost/")!)
    shell.updateTarget(httpTarget)
    let http = try VisualCapture.pngOffscreen(
      ShaarDevToolsSecurityPanel(model: shell), size: NSSize(width: 520, height: 180))
    #expect(!secure.isEmpty)
    #expect(!http.isEmpty)
    #expect(!missing.isEmpty)
    #expect(!unavailable.isEmpty)
  }
}

private enum SecurityCertificateFixture {
  static let notBefore = utc("2026-11-07T03:15:36Z")
  static let notAfter = utc("2027-11-12T03:15:36Z")
  static let der = Data(base64Encoded: parts.joined())!

  private static let parts = [
    "MIIC0jCCAboCCQDt4pkgOk//qzANBgkqhkiG9w0BAQsFADAtMRYwFAYDVQQDDA1T",
    "aGFhciBUZXN0IENBMRMwEQYDVQQKDApTaGFhciBUZXN0MB4XDTI2MTEwNzAzMTUz",
    "NloXDTI3MTExMjAzMTUzNlowKTESMBAGA1UEAwwJbG9jYWxob3N0MRMwEQYDVQQK",
    "DApTaGFhciBUZXN0MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAp4en",
    "igwSCzwGEJ5uLVJzAGviKfdgXEqjtvycNHAd85+Q/OMgunCKVesG55CtrNJif36m",
    "wzq95DCYcKXujd5mjM53odWnFPXF5BVjgODGV59q9YppbELHkGKCcRJG6YYSLQBI",
    "/E6ie5BxFR2RXXBnlS7K5TxqpD927ucNNpd72DDdxRPcY5UzNUGLwAWR7dak/ktB",
    "5vHQfWPOvCe0kBq0VjNx7U7jx3fDKCGXmfwdI7v4EpUnptq/sHV0MjpXR79temgd",
    "Q25P5N/WWcYlbskrs7gxe3rWX4ofAr9QEv0bQ3dZmc4lfC0jAUKxg5/IOTI17WaA",
    "z2TFUpyrZahoJ5iQaQIDAQABMA0GCSqGSIb3DQEBCwUAA4IBAQBWGQ+g9YZ68H3H",
    "8xbbF0MlCRg4aOCS04B3KLK7/rsdfcyRwWyui+B5SFulLgc6b+E8b3c6fePA0Zog",
    "NY2Q4QeVzG/apAXHyj/q7osHKauLaUFEhZ1UBjr0Hbca16KUjvxabVWGT0UHBQ8q",
    "Mn2yzG0XFQxwrR4Aaef0u+4M1bDYsAG7yu1mhWosJbPEV8xrDvqAzye04rJDQx0R",
    "s8BXMMUwzf/0zPm8czAW8Av+Gv1YmaFI2KbMfe/1ba+K8bKUdkk9ESIzbAraCMXe",
    "VSmFOE140cm+5AMeUuMkV6003jKQqDik3M0djXcVi/ZlG83g6+HMqA9/D6VzFBcE",
    "GYIkJ2C8",
  ]

  private static func utc(_ text: String) -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: text)!
  }
}
