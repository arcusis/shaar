// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import SwiftUI

struct PrivateProtectionStatus {
  let cookiesAndStorage: Bool
  let trackers: Bool
  let httpsOnly: Bool
  let referrers: Bool
  let webRTC: Bool
  let extensions: Bool

  init(_ status: [AnyHashable: Any]) {
    let privateProfile = status["offTheRecord"] as? Bool == true && status["error"] == nil
    cookiesAndStorage =
      privateProfile
      && status["globalCookies"] as? String == "block"
    trackers =
      privateProfile
      && status["trackerProtectionEnabled"] as? Bool == true
      && (status["trackerDomainCount"] as? Int ?? 0) > 0
      && !(status["trackerRulesRevision"] as? String ?? "").isEmpty
    httpsOnly = privateProfile && status["httpsOnly"] as? Bool == true
    referrers = privateProfile && status["referrersEnabled"] as? Bool == false
    webRTC =
      privateProfile
      && status["webRTCIPHandlingPolicy"] as? String == "disable_non_proxied_udp"
      && status["webRTCPolicyExceptionCount"] as? Int == 0
      && status["localIPExceptionCount"] as? Int == 0
    extensions = privateProfile && status["extensionsDisabled"] as? Bool == true
  }

  var allEnabled: Bool {
    cookiesAndStorage && trackers && httpsOnly && referrers && webRTC && extensions
  }
}

struct PrivateStartPage: View {
  static let titleAccessibilityTraits: AccessibilityTraits = .isHeader

  let store: BrowserStore
  @State private var status: PrivateProtectionStatus?

  init(store: BrowserStore, status: PrivateProtectionStatus? = nil) {
    self.store = store
    _status = State(initialValue: status)
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 22) {
        Image(systemName: "eye.slash")
          .font(.system(size: 38, weight: .light))
          .foregroundStyle(.purple)
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 8) {
          ShellL10n.text("A little more private.")
            .font(.system(size: 30, weight: .semibold, design: .rounded))
            .accessibilityAddTraits(Self.titleAccessibilityTraits)
          ShellL10n.text(
            "Your browsing history stays out of this Mac’s saved history. Private windows for the same profile share temporary site data until the last one closes."
          )
          .foregroundStyle(.secondary)
        }
        Button {
          store.showCommand()
        } label: {
          HStack {
            Image(systemName: "magnifyingglass")
            Text(CommandPanel.searchPrompt)
            Spacer(minLength: 40)
            ShellL10n.text("⌘T").foregroundStyle(.tertiary)
          }
          .font(.system(size: 14))
          .padding(16)
          .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
          .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary))
        }
        .buttonStyle(.plain)
        .frame(maxWidth: 420)
        VStack(alignment: .leading, spacing: 12) {
          ShellL10n.text("Private protections").font(.headline)
            .accessibilityAddTraits(.isHeader)
          protection(
            "Cookies and site storage blocked by default", active: status?.cookiesAndStorage)
          protection("Trackers blocked", active: status?.trackers)
          protection("HTTPS-only browsing", active: status?.httpsOnly)
          protection("Referrers trimmed", active: status?.referrers)
          protection("WebRTC local IP exposure limited", active: status?.webRTC)
          protection("Extensions disabled", active: status?.extensions)
        }
        .font(.callout)
        Divider()
        ShellL10n.text(
          "Private browsing does not hide your IP address or activity from websites, your employer, or your internet provider. Downloads remain on disk."
        )
        .font(.callout)
        .foregroundStyle(.secondary)
      }
      .frame(maxWidth: 550, alignment: .leading)
      .padding(40)
      .frame(maxWidth: .infinity, minHeight: 540)
    }
    .task(id: store.privatePage?.contextID) {
      guard let page = store.privatePage else { return }
      let result = await page.runtime.privatePrivacyStatus(forContextID: page.contextID)
      status = PrivateProtectionStatus(result)
    }
  }

  private func protection(_ title: String, active: Bool?) -> some View {
    HStack {
      Label {
        ShellL10n.text(title)
      } icon: {
        Image(systemName: active == true ? "checkmark.shield" : "shield.slash")
      }
      Spacer()
      ShellL10n.text(statusLabel(active))
        .foregroundStyle(.secondary)
    }
    .fixedSize(horizontal: false, vertical: true)
  }

  private func statusLabel(_ active: Bool?) -> String {
    guard let active else { return "Checking…" }
    return active ? "On" : "Unavailable"
  }
}
