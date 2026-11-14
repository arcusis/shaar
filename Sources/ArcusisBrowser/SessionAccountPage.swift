// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Best-effort metadata from the provider's rendered account UI. An email typed into a login
/// form or a redirect hint alone never proves that authentication succeeded.
enum SessionAccountPage {
  static func readScript(for provider: AccountProvider) -> String {
    let selectors: (email: String, name: String, photo: String)
    switch provider {
    case .microsoft:
      selectors = (
        "#mectrl_currentAccount_secondary, #O365_MainLink_Me, [data-bind*=userPrincipalName]",
        "#mectrl_currentAccount_primary, #mectrl_currentAccount_name, #O365_MainLink_Me",
        "#mectrl_currentAccount_picture, #O365_MainLink_MePhoto, .mectrl_profilepic img"
      )
    case .apple:
      selectors = (
        ".account-menu .header .email, .account-menu-compact .header .email",
        ".account-menu .header .name, .account-menu-compact .header .name",
        ".profile-photo img"
      )
    case .google:
      selectors = ("", "", "")
    }
    let encoded = [selectors.email, selectors.name, selectors.photo].map {
      String(data: try! JSONEncoder().encode($0), encoding: .utf8)!
    }
    return """
      (() => {
        const text = selector => {
          if (!selector) return '';
          const element = document.querySelector(selector);
          const content = (element?.textContent || '').trim();
          const label = (element?.getAttribute('aria-label') || '').trim();
          return selector === \(encoded[0]) && !content.includes('@') ? label || content : content || label;
        };
        const openMenu = element => {
          if (element && element.dataset.shaarProfileMenuOpened !== '1') {
            element.dataset.shaarProfileMenuOpened = '1';
            element.click();
          }
        };
        // iCloud mounts identity in its own signed-in account menu. Never touch its login iframe.
        if (\(provider == .apple ? "true" : "false") && !document.querySelector('.account-menu .header .email, .account-menu-compact .header .email')) {
          openMenu(document.querySelector('.profile-photo')?.closest('button'));
        }
        if (\(provider == .microsoft ? "true" : "false") && !text(\(encoded[0])).includes('@')) {
          openMenu(document.querySelector('#mectrl_main_trigger, #O365_MainLink_Me'));
        }
        const email = text(\(encoded[0])).match(/[^\\s<>(),:;]+@[^\\s<>(),:;]+\\.[^\\s<>(),:;]+/u)?.[0] || '';
        const element = document.querySelector(\(encoded[2]) || 'img[data-no-account-photo]');
        const background = element ? getComputedStyle(element).backgroundImage : '';
        const photo = element?.currentSrc || element?.src || background.match(/^url\\(["']?(.*?)["']?\\)$/)?.[1] || '';
        let photoData = '';
        if (element?.complete && element.naturalWidth > 0) {
          try {
            const canvas = document.createElement('canvas');
            canvas.width = canvas.height = 128;
            canvas.getContext('2d').drawImage(element, 0, 0, 128, 128);
            photoData = canvas.toDataURL('image/png');
          } catch {}
        }
        return JSON.stringify({url:location.href, email, name:text(\(encoded[1])), photo, photoData});
      })()
      """
  }

  static func account(from text: String, provider: AccountProvider) -> ConnectedAccount? {
    guard text.utf8.count <= 512 * 1_024, let data = text.data(using: .utf8),
      let value = try? JSONDecoder().decode(Snapshot.self, from: data),
      let url = URL(string: value.url), provider.isSignedInPage(url),
      let email = MicrosoftSignInPage.email(in: url, pageText: value.email),
      // Metadata must come from account UI, never a URL's login_hint.
      email == value.email.trimmingCharacters(in: .whitespacesAndNewlines)
    else { return nil }
    let name = value.name?.trimmingCharacters(in: .whitespacesAndNewlines)
    return ConnectedAccount(
      provider: provider, email: email, name: name?.isEmpty == false ? name : nil,
      photoURL: value.photo.flatMap(GoogleAccountList.photoURL(from:)),
      photoData: value.photoData.flatMap(photoData(from:)))
  }

  /// Starts one asynchronous, cookie-aware image read, then subsequent polls collect it.
  /// Canvas enforces origin/CORS rules. Failure leaves initials rather than copying credentials.
  static func photoScript(url: URL) -> String? {
    let secure = url.scheme == "https" && url.host != nil && url.user == nil && url.password == nil
    let blobOrigin =
      url.scheme == "blob" ? URL(string: String(url.absoluteString.dropFirst(5))) : nil
    guard
      secure
        || (blobOrigin?.scheme == "https" && blobOrigin?.host != nil
          && blobOrigin?.user == nil && blobOrigin?.password == nil),
      let encoded = try? JSONEncoder().encode(url.absoluteString),
      let literal = String(data: encoded, encoding: .utf8)
    else { return nil }
    return """
      (() => {
        const url = \(literal);
        const key = '__shaarAccountThumbnail';
        let state = window[key];
        if (!state || state.url !== url) {
          state = window[key] = {url, result:''};
          const image = new Image();
          image.crossOrigin = new URL(url).origin === location.origin ? 'use-credentials' : 'anonymous';
          image.onload = () => {
            try {
              const canvas = document.createElement('canvas');
              canvas.width = canvas.height = 128;
              canvas.getContext('2d').drawImage(image, 0, 0, 128, 128);
              state.result = canvas.toDataURL('image/png');
            } catch { state.result = 'unavailable'; }
          };
          image.onerror = () => { state.result = 'unavailable'; };
          image.src = url;
        }
        return state.result;
      })()
      """
  }

  static func photoSource(from text: String, provider: AccountProvider) -> URL? {
    guard account(from: text, provider: provider) != nil, let data = text.data(using: .utf8),
      let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data),
      let source = snapshot.photo.flatMap(URL.init(string:))
    else { return nil }
    if let secure = snapshot.photo.flatMap(GoogleAccountList.photoURL(from:)) {
      return secure
    }
    if source.scheme == "blob",
      let origin = URL(string: String(source.absoluteString.dropFirst(5))),
      origin.scheme == "https", origin.host == URL(string: snapshot.url)?.host,
      origin.user == nil, origin.password == nil
    {
      return source
    }
    return nil
  }

  static func photoData(from value: String) -> Data? {
    let prefix = "data:image/png;base64,"
    guard value.hasPrefix(prefix), value.utf8.count <= 350_000,
      let data = Data(base64Encoded: String(value.dropFirst(prefix.count))),
      data.count <= 262_144, data.starts(with: [137, 80, 78, 71, 13, 10, 26, 10])
    else { return nil }
    return data
  }

  private struct Snapshot: Decodable {
    let url: String
    let email: String
    let name: String?
    let photo: String?
    let photoData: String?
  }
}
