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
    #expect(
      SessionAccountPage.photoScript(
        url: URL(string: "https://user:secret@example.test/photo")!) == nil)
    #expect(
      SessionAccountPage.photoScript(
        url: URL(string: "blob:https://user:secret@example.test/photo")!) == nil)
  }

  @Test func photoSourcesRequireAccountEvidenceAndKeepBlobImagesOnTheirOrigin() throws {
    let page = "https://www.icloud.com/"
    let sameOrigin = "blob:https://www.icloud.com/fixture-photo"
    let remote = "https://images.example.test/avatar.png"
    for source in [sameOrigin, remote] {
      let body = try snapshot(url: page, email: "alex@example.test", photo: source)
      #expect(
        SessionAccountPage.photoSource(from: body, provider: .apple)?.absoluteString == source)
      #expect(SessionAccountPage.photoScript(url: URL(string: source)!) != nil)
    }
    for source in [
      "blob:https://other.example.test/fixture-photo", "blob:http://www.icloud.com/fixture-photo",
      "blob:https://user:secret@www.icloud.com/fixture-photo",
      "http://images.example.test/avatar.png", "data:image/png;base64,AAAA", "relative-photo.png",
    ] {
      let body = try snapshot(url: page, email: "alex@example.test", photo: source)
      #expect(SessionAccountPage.photoSource(from: body, provider: .apple) == nil, "\(source)")
    }
    for body in [
      try snapshot(url: page, email: "", photo: sameOrigin),
      try snapshot(
        url: "https://www.icloud.com.evil.test/", email: "alex@example.test", photo: remote),
      try snapshot(url: page, email: "alex@example.test", photo: nil),
      "not json",
    ] {
      #expect(SessionAccountPage.photoSource(from: body, provider: .apple) == nil)
    }
    #expect(
      SessionAccountPage.photoScript(url: URL(string: "blob:http://www.icloud.com/fixture")!) == nil
    )
  }

  @Test func secureSchemeRelativeAccountPhotoCanBeCached() throws {
    let body = try snapshot(
      url: "https://www.icloud.com/", email: "alex@example.test",
      photo: "//images.example.test/avatar.png")
    let account = try #require(SessionAccountPage.account(from: body, provider: .apple))
    let source = SessionAccountPage.photoSource(from: body, provider: .apple)

    #expect(account.photoURL?.absoluteString == "https://images.example.test/avatar.png")
    #expect(source?.absoluteString == account.photoURL?.absoluteString)
    #expect(source.flatMap(SessionAccountPage.photoScript(url:)) != nil)
  }

  @Test func metadataTrimsAccountFieldsAndKeepsSessionPhotoBytes() throws {
    let photo = try AccountPhotoFixture.data()
    let body = try snapshot(
      url: "https://www.icloud.com/", email: " \n alex@example.test \t", name: "  Alex Example \n",
      photo: "http://images.example.test/avatar.png",
      photoData: "data:image/png;base64," + photo.base64EncodedString())
    let account = try #require(SessionAccountPage.account(from: body, provider: .apple))
    #expect(account.email == "alex@example.test" && account.name == "Alex Example")
    #expect(account.photoURL == nil && account.photoData == photo)
    for name in [nil, " \n "] as [String?] {
      let unnamed = try snapshot(url: "https://www.icloud.com/", email: account.email, name: name)
      #expect(SessionAccountPage.account(from: unnamed, provider: .apple)?.name == nil)
    }
  }

  @Test func redirectHintCannotReplaceTheAccountShownByProviderUI() throws {
    let body = try snapshot(
      url: "https://www.icloud.com/?login_hint=other%40example.test", email: "alex@example.test")
    #expect(SessionAccountPage.account(from: body, provider: .apple) == nil)
  }

  @Test func accountPageRejectsOversizedMetadataSnapshot() throws {
    let body = try snapshot(
      url: "https://www.icloud.com/", email: "alex@example.test",
      name: String(repeating: "A", count: 600 * 1_024))
    #expect(body.utf8.count > 512 * 1_024)
    #expect(SessionAccountPage.account(from: body, provider: .apple) == nil)
  }

  private func snapshot(
    url: String, email: String, name: String? = "Alex Example",
    photo: String? = "https://example.test/photo.png", photoData: String? = nil
  ) throws -> String {
    var value: [String: Any] = ["url": url, "email": email]
    value["name"] = name
    value["photo"] = photo
    value["photoData"] = photoData
    return String(data: try JSONSerialization.data(withJSONObject: value), encoding: .utf8)!
  }
}

enum AccountPhotoFixture {
  /// Authored red thumbnail: no external account, credentials or network request.
  static func data(width: Int = 32, height: Int = 32) throws -> Data {
    let bitmap = NSBitmapImageRep(
      bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
      samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
      bytesPerRow: 0, bitsPerPixel: 0)!
    let red = NSColor(deviceRed: 1, green: 0, blue: 0, alpha: 1)
    for x in 0..<width { for y in 0..<height { bitmap.setColor(red, atX: x, y: y) } }
    return try #require(bitmap.representation(using: .png, properties: [:]))
  }
}
