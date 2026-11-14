// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import BrowserCore
import Testing

@testable import ArcusisBrowser

@MainActor struct ProfileIdentityBadgeTests {
  @Test func remotePhotosRejectStoredCredentialsAndInvalidPorts() {
    let secureURL = URL(string: "https://images.example.test/avatar.png")!
    let secure = ConnectedAccount(
      provider: .google, email: "alex@example.test", photoURL: secureURL)
    #expect(ProfileIdentityBadge.remotePhotoURL(for: secure) == secureURL)
    #expect(
      AccountPhotoURLPolicy.allowsRedirect(
        from: secureURL, to: URL(string: "https://images.example.test/redirected.png")!))
    #expect(
      !AccountPhotoURLPolicy.allowsRedirect(
        from: secureURL, to: URL(string: "https://other.example.test/avatar.png")!))
    #expect(
      !AccountPhotoURLPolicy.allowsRedirect(
        from: secureURL, to: URL(string: "http://images.example.test/avatar.png")!))
    #expect(
      !AccountPhotoURLPolicy.allowsRedirect(
        from: secureURL,
        to: URL(string: "https://user:secret@images.example.test/avatar.png")!))
    #expect(
      AccountPhotoURLPolicy.allowsRedirect(
        from: URL(string: "https://images.example.test:443/avatar.png")!, to: secureURL))
    #expect(
      !AccountPhotoURLPolicy.allowsRedirect(
        from: URL(string: "https://images.example.test:8443/avatar.png")!, to: secureURL))

    for address in [
      "http://images.example.test/avatar.png",
      "https://user:secret@images.example.test/avatar.png",
      "https://images.example.test:65536/avatar.png",
    ] {
      let account = ConnectedAccount(
        provider: .google, email: "alex@example.test", photoURL: URL(string: address))
      #expect(ProfileIdentityBadge.remotePhotoURL(for: account) == nil, "\(address)")
    }
  }

  @Test func cachedPhotosRejectOversizedBytesAndDimensions() throws {
    var account = ConnectedAccount(provider: .apple, email: "alex@example.test")
    #expect(account.cachedPhoto == nil)
    account.photoData = try AccountPhotoFixture.data(width: 512, height: 1)
    #expect(account.cachedPhoto != nil)
    account.photoData = try AccountPhotoFixture.data(width: 513, height: 1)
    #expect(account.cachedPhoto == nil)
    account.photoData = try AccountPhotoFixture.data(width: 1, height: 513)
    #expect(account.cachedPhoto == nil)
    account.photoData = Data(repeating: 0, count: 262_145)
    #expect(account.cachedPhoto == nil)
  }

  @Test func accountPhotoPolicyRejectsPortZero() {
    let secureURL = URL(string: "https://images.example.test/avatar.png")!
    let invalidURL = URL(string: "https://images.example.test:0/avatar.png")!
    let account = ConnectedAccount(
      provider: .google, email: "alex@example.test", photoURL: invalidURL)

    #expect(ProfileIdentityBadge.remotePhotoURL(for: account) == nil)
    #expect(!AccountPhotoURLPolicy.allowsRedirect(from: secureURL, to: invalidURL))
  }

  @Test func unreadablePhotoFallsBackToInitialsInProfileColor() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "badge-fallback-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let color = SpaceRGBColor(red: 12, green: 34, blue: 56)
    let account = ConnectedAccount(
      provider: .apple, email: "alex@example.test", name: "Alex Example",
      photoData: Data("unreadable fixture".utf8))
    let image = try VisualCapture.renderOffscreen(
      ProfileIdentityBadge(account: account, color: color, size: 64),
      size: NSSize(width: 64, height: 64), appearance: .aqua,
      to: root.appending(path: "initials.png"))
    // Inside the circle, away from the initials and provider mark.
    let background = try #require(image.colorAt(x: 8, y: 32)?.usingColorSpace(.deviceRGB))
    #expect(abs(background.redComponent - 12.0 / 255) < 0.02)
    #expect(abs(background.greenComponent - 34.0 / 255) < 0.02)
    #expect(abs(background.blueComponent - 56.0 / 255) < 0.02)
    #expect(account.initials == "AE")
    #expect(ConnectedAccount(provider: .google, email: "alex@example.test").initials == "A")
    #expect(
      ConnectedAccount(provider: .microsoft, email: "alex@example.test", name: "").initials
        == "A")
  }

  @Test func whitespaceOnlyAccountNameUsesEmailFallback() {
    let account = ConnectedAccount(
      provider: .google, email: "alex@example.test", name: " \n ")
    #expect(account.displayName == "alex@example.test")
    #expect(account.initials == "A")
  }

  @Test func menuWithoutConnectedAccountUsesProfileSymbolAndTint() throws {
    let profile = BrowserProfile(name: "Fixture", tint: .ocean, symbol: "star.fill")
    let image = try #require(ProfileIdentityLabel.image(profile: profile, account: nil))
    #expect(image.size.width == 22 && image.size.height == 22)
    let bitmap = try #require(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
    let center = try #require(
      bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2))
    #expect(center.alphaComponent > 0.9)
  }
}
