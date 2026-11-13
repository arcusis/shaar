// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import SwiftUI

struct WebsitePermissionConsent: View {
  static let headingTraits: AccessibilityTraits = .isHeader
  let store: BrowserStore
  let request: WebsitePermissionRequest
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      Label(
        PanelsL10n.format("Allow %@?", .string(titles)),
        systemImage: request.kinds.first?.symbol ?? "hand.raised"
      )
      .font(.title2.weight(.semibold))
      .accessibilityAddTraits(Self.headingTraits)
      Text(request.requestingOrigin.absoluteString).font(.headline).textSelection(.enabled)
        .environment(\.layoutDirection, .leftToRight)
      Text(PanelsL10n.format("This site wants to %@.", .string(purposes)))
      LabeledContent(PanelsL10n.string("Profile"), value: profileName)
      LabeledContent(
        PanelsL10n.string("Page")
      ) {
        Text(request.pageURL.host() ?? request.pageURL.absoluteString)
          .environment(\.layoutDirection, .leftToRight)
      }
      Divider()
      Text(scopeNote)
        .font(.callout).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      HStack {
        Button(PanelsL10n.string("Not now"), role: .cancel) { resolve(accepted: false) }
          .keyboardShortcut(.cancelAction)
        Spacer()
        Button(WebsitePermissionSheetCopy.allowButton(isPrivate: store.isPrivate, oneTime: oneTime))
        {
          resolve(accepted: true)
        }
        .disabled(!store.websitePermissionIsCurrent(request))
      }
    }
    .padding(28).frame(width: 440)
    .background(Color(nsColor: .windowBackgroundColor))
    .interactiveDismissDisabled()
  }

  private var oneTime: Bool { request.kinds.allSatisfy(\.supportsOneTimeGrant) }
  private var titles: String {
    localizedList(request.kinds.map(\.title))
  }
  private var purposes: String {
    localizedList(request.kinds.map(\.purpose))
  }
  private var scopeNote: String {
    let duration = WebsitePermissionSheetCopy.duration(isPrivate: store.isPrivate, oneTime: oneTime)
    return PanelsL10n.format(
      "%@ %@", .string(duration),
      .string(
        PanelsL10n.string(
          "Other tabs and spaces sharing this profile share the permission. macOS may also ask for permission."
        )))
  }
  private var profileName: String {
    store.session.profiles.first { $0.id == request.profileID }?.name
      ?? PanelsL10n.string("Unavailable profile")
  }

  private func localizedList(_ values: [String]) -> String {
    let formatter = ListFormatter()
    formatter.locale = PanelsL10n.formattingLocale()
    return formatter.string(from: values) ?? values.joined(separator: ", ")
  }
  private func resolve(accepted: Bool) {
    store.resolveWebsitePermission(request.id, accepted: accepted)
    dismiss()
  }
}

enum WebsitePermissionSheetCopy {
  static func allowButton(isPrivate: Bool, oneTime: Bool) -> String {
    if isPrivate { return PanelsL10n.string("this visit only") }
    if oneTime { return PanelsL10n.string("Allow this time") }
    return PanelsL10n.string("Allow")
  }

  static func duration(isPrivate: Bool, oneTime: Bool) -> String {
    if isPrivate || oneTime { return PanelsL10n.string("Only for this visit.") }
    return PanelsL10n.string("The site keeps this permission in this profile until you change it.")
  }
}

extension WebsitePermissionKind {
  var title: String {
    switch self {
    case .camera: PanelsL10n.string("camera")
    case .microphone: PanelsL10n.string("microphone")
    case .location: PanelsL10n.string("location")
    case .notifications: PanelsL10n.string("notifications")
    case .clipboard: PanelsL10n.string("clipboard access")
    case .midi: PanelsL10n.string("MIDI devices")
    case .multipleDownloads: PanelsL10n.string("multiple downloads")
    case .windowManagement: PanelsL10n.string("window management")
    case .localFonts: PanelsL10n.string("local fonts")
    case .storageAccess: PanelsL10n.string("cookies across sites")
    case .protocolHandler: PanelsL10n.string("this protocol")
    }
  }

  var purpose: String {
    switch self {
    case .camera: PanelsL10n.string("use your camera")
    case .microphone: PanelsL10n.string("use your microphone")
    case .location: PanelsL10n.string("know your location")
    case .notifications: PanelsL10n.string("show notifications")
    case .clipboard: PanelsL10n.string("see text and images you copy")
    case .midi: PanelsL10n.string("use and reprogram your MIDI devices")
    case .multipleDownloads: PanelsL10n.string("download multiple files")
    case .windowManagement: PanelsL10n.string("open and place windows on your displays")
    case .localFonts: PanelsL10n.string("use fonts installed on this Mac")
    case .storageAccess: PanelsL10n.string("use its cookies while embedded in other sites")
    case .protocolHandler: PanelsL10n.string("open links that use this protocol")
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
    case .protocolHandler: "link"
    }
  }
}
