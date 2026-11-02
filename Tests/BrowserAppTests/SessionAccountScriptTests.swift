// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import Foundation
import Testing
import WebKit

@testable import ArcusisBrowser

/// Executes the production DOM readers against authored pages in an ephemeral, unpresented
/// WebKit session. No provider request, existing cookie jar, credentials or visible window.
@MainActor struct SessionAccountScriptTests {
  @Test(arguments: [AccountProvider.microsoft, .apple])
  func providerMenuExposesIdentityAndReadablePhoto(_ provider: AccountProvider) async throws {
    let photo = try AccountPhotoFixture.data().base64EncodedString()
    let apple = provider == .apple
    let view = makeView()
    let account =
      apple
      ? "<div class='header'><span class='name'>Alex Example</span><span class='email'>alex@example.test</span></div>"
      : "<span id='mectrl_currentAccount_primary'>Alex Example</span><span id='mectrl_currentAccount_secondary'>alex@example.test</span>"
    let menu = String(data: try JSONEncoder().encode(account), encoding: .utf8)!
    let html = """
      <!doctype html><meta charset="utf-8"><title>Authored account menu</title>
      <button id="\(apple ? "fixture-account" : "mectrl_main_trigger")">
        <span class="profile-photo"><img id="mectrl_currentAccount_picture" src="data:image/png;base64,\(photo)"></span>
      </button>
      <script>
        window.menuClicks=0;
        document.querySelector('button').onclick=()=>{
          window.menuClicks++;
          const menu=document.createElement('div');menu.className='account-menu';
          menu.innerHTML=\(menu);document.body.append(menu);
        };
      </script>
      """
    view.loadHTMLString(html, baseURL: URL(string: "https://example.test/fixture"))
    var snapshot: [String: Any] = [:]
    for _ in 0..<100 {
      if let text = try? await evaluate(SessionAccountPage.readScript(for: provider), in: view),
        let data = text.data(using: .utf8),
        let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
      {
        snapshot = value
        if let photo = value["photoData"] as? String,
          SessionAccountPage.photoData(from: photo) != nil
        {
          break
        }
      }
      try await Task.sleep(for: .milliseconds(50))
    }
    #expect(snapshot["email"] as? String == "alex@example.test")
    #expect(snapshot["name"] as? String == "Alex Example")
    #expect(SessionAccountPage.photoData(from: snapshot["photoData"] as? String ?? "") != nil)
    #expect(try await evaluate("String(window.menuClicks)", in: view) == "1")
    view.stopLoading()
  }

  @Test func thumbnailReadUsesTheDocumentSessionForABlobImage() async throws {
    let view = makeView()
    let photo = try AccountPhotoFixture.data().base64EncodedString()
    view.loadHTMLString(
      """
      <!doctype html><meta charset="utf-8"><script>
        const bytes=Uint8Array.from(atob('\(photo)'),c=>c.charCodeAt(0));
        window.photoURL=URL.createObjectURL(new Blob([bytes],{type:'image/png'}));
      </script>
      """, baseURL: URL(string: "https://example.test/fixture"))
    var source: URL?
    for _ in 0..<100 {
      if let value = try? await evaluate("window.photoURL || ''", in: view),
        let url = URL(string: value), url.scheme == "blob"
      {
        source = url
        break
      }
      try await Task.sleep(for: .milliseconds(50))
    }
    let url = try #require(source)
    let script = try #require(SessionAccountPage.photoScript(url: url))
    var data: Data?
    for _ in 0..<100 {
      let value = try await evaluate(script, in: view)
      data = SessionAccountPage.photoData(from: value)
      if data != nil || value == "unavailable" { break }
      try await Task.sleep(for: .milliseconds(50))
    }
    #expect(data != nil)
    _ = try await evaluate("URL.revokeObjectURL(window.photoURL); 'revoked'", in: view)
    view.stopLoading()
  }

  private func makeView() -> WKWebView {
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    return WKWebView(
      frame: NSRect(x: 0, y: 0, width: 520, height: 680), configuration: configuration)
  }

  private func evaluate(_ script: String, in view: WKWebView) async throws -> String {
    try await withCheckedThrowingContinuation { continuation in
      view.evaluateJavaScript(script) { value, error in
        if let error {
          continuation.resume(throwing: error)
        } else {
          continuation.resume(returning: value as? String ?? "")
        }
      }
    }
  }
}
