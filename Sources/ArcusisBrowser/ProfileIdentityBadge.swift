// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import BrowserCore
import Foundation
import SwiftUI

/// Shared by onboarding, Settings cards and profile menus. Cached session photos also work
/// offline; public legacy photo URLs remain compatible with older preferences.
struct ProfileIdentityBadge: View {
  var account: ConnectedAccount?
  var color: SpaceRGBColor?
  var symbol = BrowserProfile.defaultSymbol
  var size: CGFloat = 28

  static func remotePhotoURL(for account: ConnectedAccount) -> URL? {
    account.photoURL.flatMap { AccountPhotoURLPolicy.accepts($0) ? $0 : nil }
  }

  var body: some View {
    Group {
      if let account {
        if let image = account.cachedPhoto {
          Image(nsImage: image).resizable().scaledToFill()
        } else if let url = Self.remotePhotoURL(for: account) {
          RemoteAccountPhoto(url: url) {
            initials(account)
          }
        } else {
          initials(account)
        }
      } else {
        ProfileBadge(color: color, symbol: symbol, size: size)
      }
    }
    .frame(width: size, height: size)
    .clipShape(Circle())
    .overlay(alignment: .bottomTrailing) {
      if let logo = account?.provider.logo {
        Image(nsImage: logo).resizable().scaledToFit()
          .frame(width: size * 0.3, height: size * 0.3)
          .padding(2)
          .background(Color(nsColor: .windowBackgroundColor), in: Circle())
      }
    }
    .accessibilityLabel(account.map { "\($0.provider.title): \($0.displayName)" } ?? "")
  }

  private func initials(_ account: ConnectedAccount) -> some View {
    Text(account.initials)
      .font(.system(size: size * 0.38, weight: .semibold))
      .foregroundStyle(.white)
      .frame(width: size, height: size)
      .background(color.map(Color.init(spaceRGB:)) ?? .accentColor, in: Circle())
  }
}

enum AccountPhotoURLPolicy {
  static func accepts(_ url: URL) -> Bool {
    guard url.scheme?.lowercased() == "https", url.host() != nil,
      url.user == nil, url.password == nil,
      url.port.map({ (0...65535).contains($0) }) ?? true
    else { return false }
    return true
  }

  static func allowsRedirect(from source: URL, to destination: URL) -> Bool {
    guard accepts(source), accepts(destination),
      source.scheme?.lowercased() == destination.scheme?.lowercased(),
      source.host()?.lowercased() == destination.host()?.lowercased()
    else { return false }
    return (source.port ?? 443) == (destination.port ?? 443)
  }
}

private struct RemoteAccountPhoto<Placeholder: View>: View {
  let url: URL
  private let placeholder: () -> Placeholder
  @State private var image: NSImage?

  init(url: URL, @ViewBuilder placeholder: @escaping () -> Placeholder) {
    self.url = url
    self.placeholder = placeholder
  }

  var body: some View {
    Group {
      if let image {
        Image(nsImage: image).resizable().scaledToFill()
      } else {
        placeholder()
      }
    }
    .task(id: url) {
      image = await AccountPhotoLoader.load(url)
    }
  }
}

private enum AccountPhotoLoader {
  static func load(_ url: URL) async -> NSImage? {
    guard AccountPhotoURLPolicy.accepts(url) else { return nil }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpCookieStorage = nil
    configuration.httpShouldSetCookies = false
    configuration.urlCredentialStorage = nil
    configuration.timeoutIntervalForRequest = 5
    configuration.timeoutIntervalForResource = 5
    let delegate = AccountPhotoRedirectDelegate(source: url)
    let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    defer { session.invalidateAndCancel() }
    do {
      let (bytes, response) = try await session.bytes(from: url)
      guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
        let finalURL = http.url, AccountPhotoURLPolicy.allowsRedirect(from: url, to: finalURL)
      else { return nil }
      var data = Data()
      for try await byte in bytes {
        guard data.count < 1_048_576 else { return nil }
        data.append(byte)
      }
      return NSImage(data: data)
    } catch {
      return nil
    }
  }
}

private final class AccountPhotoRedirectDelegate: NSObject, URLSessionTaskDelegate,
  @unchecked Sendable
{
  let source: URL

  init(source: URL) { self.source = source }

  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    guard let destination = request.url,
      AccountPhotoURLPolicy.allowsRedirect(from: source, to: destination)
    else {
      completionHandler(nil)
      return
    }
    completionHandler(request)
  }
}

extension ConnectedAccount {
  var cachedPhoto: NSImage? {
    guard let photoData, photoData.count <= 262_144,
      let bitmap = NSBitmapImageRep(data: photoData),
      bitmap.pixelsWide > 0, bitmap.pixelsHigh > 0,
      bitmap.pixelsWide <= 512, bitmap.pixelsHigh <= 512
    else { return nil }
    return NSImage(data: photoData)
  }
}

/// Native menus use Label's image rather than trying to embed a custom SwiftUI row.
struct ProfileIdentityLabel: View {
  let profile: BrowserProfile
  var account: ConnectedAccount?

  var body: some View {
    Label {
      Text(verbatim: account.map { "\(profile.name) · \($0.displayName)" } ?? profile.name)
    } icon: {
      if let image = Self.image(profile: profile, account: account) {
        Image(nsImage: image)
      } else {
        Image(systemName: "person.crop.circle")
      }
    }
  }

  @MainActor static func image(profile: BrowserProfile, account: ConnectedAccount?) -> NSImage? {
    let renderer = ImageRenderer(
      content: ProfileIdentityBadge(
        account: account, color: ProfileColorChoice(profile: profile).rgb,
        symbol: profile.displaySymbol, size: 22))
    renderer.scale = 2
    return renderer.nsImage
  }
}
