// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import BrowserCore
import SwiftUI

/// Shared by onboarding, Settings cards and profile menus. Cached session photos also work
/// offline; public legacy photo URLs remain compatible with older preferences.
struct ProfileIdentityBadge: View {
  var account: ConnectedAccount?
  var color: SpaceRGBColor?
  var symbol = BrowserProfile.defaultSymbol
  var size: CGFloat = 28

  static func remotePhotoURL(for account: ConnectedAccount) -> URL? {
    guard let url = account.photoURL, url.scheme?.lowercased() == "https",
      url.host() != nil, url.user == nil, url.password == nil,
      url.port.map({ (0...65535).contains($0) }) ?? true
    else { return nil }
    return url
  }

  var body: some View {
    Group {
      if let account {
        if let image = account.cachedPhoto {
          Image(nsImage: image).resizable().scaledToFill()
        } else if let url = Self.remotePhotoURL(for: account) {
          AsyncImage(url: url) { phase in
            if let image = phase.image {
              image.resizable().scaledToFill()
            } else {
              initials(account)
            }
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
