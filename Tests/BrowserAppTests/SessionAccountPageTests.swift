// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import BrowserCore
import Foundation
import SwiftUI
import Testing

@testable import ArcusisBrowser

struct SessionAccountPageTests {
  @Test func providerChoicesUseFirstPartyPagesAndShareOneMicrosoftIdentity() {
    #expect(
      AccountSignInOption.allCases.map(\.provider) == [.google, .microsoft, .microsoft, .apple])
    #expect(AccountSignInOption.microsoftPersonal.signInURL.host == "login.live.com")
    #expect(AccountSignInOption.microsoftWork.signInURL.host == "www.microsoft365.com")
    for option in AccountSignInOption.allCases {
      #expect(option.signInURL.scheme == "https" && !option.title.isEmpty)
      #expect(AccountSignInOption.standard(for: option.provider).provider == option.provider)
    }
    #expect(AccountProvider.apple.signInURL.host == "www.icloud.com")
    #expect(!AccountProvider.apple.isSignedInPage(URL(string: "http://www.icloud.com/")!))
  }
  @Test(arguments: [AccountProvider.microsoft, .apple])
  func signedInMetadataRequiresProviderOriginAndAccountUI(_ provider: AccountProvider) throws {
    let url = provider == .apple ? "https://www.icloud.com/" : "https://m365.cloud.microsoft/"
    let body = try snapshot(url: url, email: "alex@example.test")
    let account = try #require(SessionAccountPage.account(from: body, provider: provider))
    #expect(account.email == "alex@example.test" && account.name == "Alex Example")
    #expect(account.provider == provider)
    #expect(account.photoURL?.absoluteString == "https://example.test/photo.png")
    for address in [
      "http://www.icloud.com/", "https://www.icloud.com.evil.test/", "https://sso.example.test/",
    ] {
      #expect(
        SessionAccountPage.account(
          from: try snapshot(url: address, email: "alex@example.test"), provider: provider) == nil)
    }
    #expect(
      SessionAccountPage.account(
        from: try snapshot(url: url + "?login_hint=alex%40example.test", email: ""),
        provider: provider) == nil)
    #expect(SessionAccountPage.account(from: "not json", provider: provider) == nil)
  }

  @Test @MainActor func cachedSessionPhotoSurvivesPreferencesReloadAndRenders() throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "shaar-account-photo-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let data = try AccountPhotoFixture.data()
    let account = ConnectedAccount(
      provider: .apple, email: "alex@example.test", name: "Alex Example", photoData: data)
    let id = UUID()
    let file = root.appending(path: "preferences.json")
    BrowserPreferencesStore(fileURL: file).setAccount(account, for: id)
    let restored = try #require(BrowserPreferencesStore(fileURL: file).accounts(for: id).first)
    #expect(restored == account && restored.cachedPhoto != nil)
    let image = try VisualCapture.renderOffscreen(
      ProfileIdentityBadge(account: restored, color: SpaceTintRGB.color(for: .ocean), size: 64),
      size: NSSize(width: 64, height: 64), appearance: .aqua, to: root.appending(path: "badge.png"))
    let center = try #require(image.colorAt(x: 32, y: 32)?.usingColorSpace(.deviceRGB))
    #expect(
      center.redComponent > 0.9 && center.greenComponent < 0.15 && center.blueComponent < 0.15)
    #expect(restored.initials == "AE")
    let menuImage = try #require(
      ProfileIdentityLabel.image(
        profile: BrowserProfile(id: id, name: "Fixture", tint: .ocean), account: restored))
    let menuBitmap = try #require(
      menuImage.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
    let menuCenter = try #require(
      menuBitmap.colorAt(x: menuBitmap.pixelsWide / 2, y: menuBitmap.pixelsHigh / 2)?
        .usingColorSpace(.deviceRGB))
    #expect(menuCenter.redComponent > 0.9 && menuCenter.greenComponent < 0.15)
    var invalid = restored
    invalid.photoData = Data("not an image".utf8)
    #expect(invalid.cachedPhoto == nil)
    let legacy = Data(#"{"provider":"google","email":"legacy@example.test"}"#.utf8)
    #expect(try JSONDecoder().decode(ConnectedAccount.self, from: legacy).photoData == nil)
  }

  @Test func sessionThumbnailInputIsBoundedAndRequiresPNG() {
    #expect(SessionAccountPage.photoData(from: "data:image/png;base64,bm90IHBob3Rv") == nil)
    #expect(SessionAccountPage.photoData(from: "data:text/html;base64,AAAA") == nil)
    #expect(
      SessionAccountPage.photoData(
        from: "data:image/png;base64," + String(repeating: "A", count: 350_000)) == nil)
    #expect(SessionAccountPage.photoScript(url: URL(string: "http://example.test/photo")!) == nil)
  }

  private func snapshot(url: String, email: String) throws -> String {
    String(
      data: try JSONSerialization.data(withJSONObject: [
        "url": url, "email": email, "name": "Alex Example",
        "photo": "https://example.test/photo.png",
      ]), encoding: .utf8)!
  }
}

enum AccountPhotoFixture {
  /// Authored red thumbnail: no external account, credentials or network request.
  static func data() throws -> Data {
    let bitmap = NSBitmapImageRep(
      bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32, bitsPerSample: 8,
      samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
      bytesPerRow: 0, bitsPerPixel: 0)!
    let red = NSColor(deviceRed: 1, green: 0, blue: 0, alpha: 1)
    for x in 0..<32 { for y in 0..<32 { bitmap.setColor(red, atX: x, y: y) } }
    return try #require(bitmap.representation(using: .png, properties: [:]))
  }
}
