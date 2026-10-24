import BrowserCore
import SwiftUI

struct WebsiteMediaConsent: View {
  let store: BrowserStore
  let request: WebsiteMediaRequest
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      Label("Allow \(resources)?", systemImage: request.kinds.contains(.camera) ? "camera" : "mic")
        .font(.title2.weight(.semibold))
      Text(request.requestingOrigin.absoluteString).font(.headline).textSelection(.enabled)
      Text("This site wants to use your \(resources).")
      LabeledContent("Profile", value: profileName)
      LabeledContent("Page", value: request.pageURL.host() ?? request.pageURL.absoluteString)
      Divider()
      Text(
        "Only for this visit. Other tabs and spaces sharing this profile may share the permission while you use the site. macOS may also ask for permission."
      )
      .font(.callout).foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
      HStack {
        Button("Not now", role: .cancel) { resolve(accepted: false) }
          .keyboardShortcut(.cancelAction)
        Spacer()
        Button("Allow this time") { resolve(accepted: true) }
          .disabled(!request.matches(store.session))
      }
    }
    .padding(28).frame(width: 440)
    .background(Color(nsColor: .windowBackgroundColor))
    .interactiveDismissDisabled()
  }

  private var resources: String { request.kinds.map(\.rawValue).joined(separator: " and ") }
  private var profileName: String {
    store.session.profiles.first { $0.id == request.profileID }?.name ?? "Unavailable profile"
  }
  private func resolve(accepted: Bool) {
    store.resolveWebsiteMedia(request.id, accepted: accepted)
    dismiss()
  }
}
