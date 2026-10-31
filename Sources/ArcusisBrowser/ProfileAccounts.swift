// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import BrowserCore
import Foundation

/// Web accounts a profile can be signed in to. Sign-in runs on the provider's own page inside the
/// profile, so its cookies stay in that profile; no OAuth client or sync is involved.
enum AccountProvider: String, Codable, CaseIterable, Identifiable, Sendable {
  case google, microsoft

  var id: String { rawValue }

  var title: String {
    switch self {
    case .google: "Google"
    case .microsoft: "Microsoft"
    }
  }

  var signInURL: URL {
    switch self {
    case .google:
      URL(
        string:
          "https://accounts.google.com/AddSession?continue=https%3A%2F%2Fmyaccount.google.com%2F")!
    case .microsoft: URL(string: "https://www.microsoft365.com/login")!
    }
  }

  var signOutURL: URL {
    switch self {
    case .google: URL(string: "https://accounts.google.com/Logout")!
    case .microsoft: URL(string: "https://login.microsoftonline.com/common/oauth2/v2.0/logout")!
    }
  }

  /// The provider redirects here once sign-in has finished. Google may land on any of its pages
  /// (for example www.google.com after an error), so anything off the sign-in host counts.
  func isSignedInPage(_ url: URL) -> Bool {
    let host = url.host()?.lowercased() ?? ""
    switch self {
    case .google: return host.hasSuffix(".google.com") && host != "accounts.google.com"
    case .microsoft:
      return [
        "www.microsoft365.com", "m365.cloud.microsoft", "www.office.com", "outlook.live.com",
        "outlook.office.com",
      ].contains(host) && !url.path().hasPrefix("/login")
    }
  }

  var logo: NSImage? { NSImage(data: Data(logoSVG.utf8)) }

  /// Official provider marks, used unmodified on the connect buttons.
  private var logoSVG: String {
    switch self {
    case .google:
      """
      <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 18 18" width="18" height="18">
      <path fill="#EA4335" d="M9 3.48c1.69 0 2.83.73 3.48 1.34l2.54-2.48C13.46.89 11.43 0 9 0 5.48 0 2.44 2.02.96 4.96l2.91 2.26C4.6 5.05 6.62 3.48 9 3.48z"/>
      <path fill="#4285F4" d="M17.64 9.2c0-.74-.06-1.28-.19-1.84H9v3.34h4.96c-.1.83-.64 2.08-1.84 2.92l2.84 2.2c1.7-1.57 2.68-3.88 2.68-6.62z"/>
      <path fill="#FBBC05" d="M3.88 10.78A5.54 5.54 0 0 1 3.58 9c0-.62.11-1.22.29-1.78L.96 4.96A9 9 0 0 0 0 9c0 1.45.35 2.82.96 4.04l2.92-2.26z"/>
      <path fill="#34A853" d="M9 18c2.43 0 4.47-.8 5.96-2.18l-2.84-2.2c-.76.53-1.78.9-3.12.9-2.38 0-4.4-1.57-5.12-3.74L.97 13.04C2.45 15.98 5.48 18 9 18z"/>
      </svg>
      """
    case .microsoft:
      """
      <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 21 21" width="21" height="21">
      <rect x="1" y="1" width="9" height="9" fill="#F25022"/><rect x="11" y="1" width="9" height="9" fill="#7FBA00"/>
      <rect x="1" y="11" width="9" height="9" fill="#00A4EF"/><rect x="11" y="11" width="9" height="9" fill="#FFB900"/>
      </svg>
      """
    }
  }
}

struct ConnectedAccount: Codable, Equatable, Sendable {
  let provider: AccountProvider
  let email: String
  var name: String?
  var photoURL: URL?
}

/// Google's signed-in account list for the profile's cookies, as Chromium's own sign-in reads it.
enum GoogleAccountList {
  static let url = URL(
    string: "https://accounts.google.com/ListAccounts?gpsia=1&source=ChromiumBrowser&json=standard")!

  /// Google answers the list only to POST; a plain visit shows a 400 page. Opening the URL puts
  /// the page on the accounts origin, and this same-origin POST then reads the list with its
  /// cookies.
  static let readScript = """
    (() => {
      const request = new XMLHttpRequest();
      request.open('POST', location.href, false);
      request.send('');
      return request.status === 200 ? request.responseText : '';
    })()
    """

  /// Entries look like `["gaia.l.a", 1, name, email, photo, …]`; the first is the primary account.
  /// Returns nil until the body is the account list, and an empty array when no one is signed in.
  static func accounts(fromBody text: String) -> [ConnectedAccount]? {
    guard
      let root = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [Any],
      root.count > 1, let entries = root[1] as? [[Any]]
    else { return nil }
    return entries.compactMap { entry in
      guard entry.count > 4, let email = entry[3] as? String, email.contains("@") else {
        return nil
      }
      let photo = (entry[4] as? String).flatMap(URL.init(string:))
      return ConnectedAccount(
        provider: .google, email: email, name: entry[2] as? String,
        photoURL: photo?.scheme == "https" ? photo : nil)
    }
  }
}

/// Reads the account email while a Microsoft sign-in runs: on Microsoft's own pages, on a
/// company identity provider (Okta, ADFS, Ping and similar) it redirects to, and in the account
/// menu of the landing page.
enum MicrosoftSignInPage {
  static let emailScript = """
    (() => {
      const selectors = [
        'input[type=email]', 'input[name=loginfmt]', 'input[name=login]', 'input[name=username]',
        'input[name=identifier]', '#userNameInput', 'input[autocomplete=username]',
        '[data-bind*="userPrincipalName"]', '#userName', '#displayName',
        '#mectrl_currentAccount_secondary'
      ];
      return selectors
        .map(selector => document.querySelector(selector))
        .map(element => (element?.value || element?.textContent || '').trim())
        .find(value => value.includes('@')) || '';
    })()
    """

  private static let microsoftDomains = [
    "microsoftonline.com", "live.com", "microsoft.com", "microsoft365.com", "cloud.microsoft",
    "office.com", "office365.com",
  ]

  static func isSignInPage(_ url: URL) -> Bool {
    ["login.microsoftonline.com", "login.live.com"].contains(url.host()?.lowercased() ?? "")
  }

  /// A secure page outside Microsoft during sign-in is the organization's identity provider.
  static func isIdentityProviderPage(_ url: URL) -> Bool {
    guard let host = url.host()?.lowercased(), url.scheme?.lowercased() == "https" else {
      return false
    }
    return !microsoftDomains.contains(where: { host == $0 || host.hasSuffix("." + $0) })
  }

  static func mayShowAccountEmail(_ url: URL) -> Bool {
    isSignInPage(url) || isIdentityProviderPage(url)
  }

  /// Prefers the hint Microsoft passes along in the address over text read from the page.
  static func email(in url: URL, pageText: String? = nil) -> String? {
    let queryEmail = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
      .first(where: { ["login_hint", "username", "email"].contains($0.name.lowercased()) })?.value
    return [queryEmail, pageText].compactMap { $0 }
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .first(where: isEmail)
  }

  private static func isEmail(_ value: String) -> Bool {
    let parts = value.split(separator: "@", omittingEmptySubsequences: false)
    return parts.count == 2 && !parts[0].isEmpty && parts[1].contains(".")
  }
}
