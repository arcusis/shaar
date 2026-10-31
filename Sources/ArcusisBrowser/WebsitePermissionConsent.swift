// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import SwiftUI

struct WebsitePermissionConsent: View {
  let store: BrowserStore
  let request: WebsitePermissionRequest
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      Label("Allow \(titles)?", systemImage: request.kinds.first?.symbol ?? "hand.raised")
        .font(.title2.weight(.semibold))
      Text(request.requestingOrigin.absoluteString).font(.headline).textSelection(.enabled)
      Text("This site wants to \(purposes).")
      LabeledContent("Profile", value: profileName)
      LabeledContent("Page", value: request.pageURL.host() ?? request.pageURL.absoluteString)
      Divider()
      Text(scopeNote)
        .font(.callout).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      HStack {
        Button("Not now", role: .cancel) { resolve(accepted: false) }
          .keyboardShortcut(.cancelAction)
        Spacer()
        Button(oneTime ? "Allow this time" : "Allow") { resolve(accepted: true) }
          .disabled(!request.matches(store.session))
      }
    }
    .padding(28).frame(width: 440)
    .background(Color(nsColor: .windowBackgroundColor))
    .interactiveDismissDisabled()
  }

  private var oneTime: Bool { request.kinds.allSatisfy(\.supportsOneTimeGrant) }
  private var titles: String {
    ListFormatter.localizedString(byJoining: request.kinds.map(\.title))
  }
  private var purposes: String {
    ListFormatter.localizedString(byJoining: request.kinds.map(\.purpose))
  }
  private var scopeNote: String {
    let duration =
      oneTime
      ? "Only for this visit."
      : "The site keeps this permission in this profile until you change it."
    return
      "\(duration) Other tabs and spaces sharing this profile share the permission. macOS may also ask for permission."
  }
  private var profileName: String {
    store.session.profiles.first { $0.id == request.profileID }?.name ?? "Unavailable profile"
  }
  private func resolve(accepted: Bool) {
    store.resolveWebsitePermission(request.id, accepted: accepted)
    dismiss()
  }
}

extension WebsitePermissionKind {
  var title: String {
    switch self {
    case .camera: "camera"
    case .microphone: "microphone"
    case .location: "location"
    case .notifications: "notifications"
    case .clipboard: "clipboard access"
    case .midi: "MIDI devices"
    case .multipleDownloads: "multiple downloads"
    case .windowManagement: "window management"
    case .localFonts: "local fonts"
    case .storageAccess: "cookies across sites"
    }
  }

  var purpose: String {
    switch self {
    case .camera: "use your camera"
    case .microphone: "use your microphone"
    case .location: "know your location"
    case .notifications: "show notifications"
    case .clipboard: "see text and images you copy"
    case .midi: "use and reprogram your MIDI devices"
    case .multipleDownloads: "download multiple files"
    case .windowManagement: "open and place windows on your displays"
    case .localFonts: "use fonts installed on this Mac"
    case .storageAccess: "use its cookies while embedded in other sites"
    }
  }

  var symbol: String {
    switch self {
    case .camera: "camera"
    case .microphone: "mic"
    case .location: "location"
    case .notifications: "bell.badge"
    case .clipboard: "doc.on.clipboard"
    case .midi: "pianokeys"
    case .multipleDownloads: "arrow.down.circle"
    case .windowManagement: "macwindow.on.rectangle"
    case .localFonts: "textformat"
    case .storageAccess: "network"
    }
  }
}
