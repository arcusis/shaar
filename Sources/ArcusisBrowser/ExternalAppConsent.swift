import AppKit
import BrowserCore
import SwiftUI

struct ExternalAppConsent: View {
  let store: BrowserStore
  let request: ExternalAppRequest
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        Label("Open in another app?", systemImage: "app")
          .font(.title2.weight(.semibold))
        Text(request.applicationName ?? "No app available")
          .font(.headline).fixedSize(horizontal: false, vertical: true)
        LabeledContent("Website") {
          Text(request.requestingOrigin?.absoluteString ?? "Unknown website")
            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
        LabeledContent("Profile") {
          Text(profileName).fixedSize(horizontal: false, vertical: true)
        }
        LabeledContent("Link type") {
          Text(request.scheme).fixedSize(horizontal: false, vertical: true)
        }
        Divider()
        Text(
          request.canOpen
            ? "This will open one link in the selected app. This choice applies once."
            : "No compatible app is installed for this link type."
        )
        .font(.callout).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        HStack {
          if request.canOpen {
            Button("Cancel", role: .cancel) { resolve(accepted: false) }
              .keyboardShortcut(.cancelAction)
            Spacer()
            Button("Open Once") { resolve(accepted: true) }
              .keyboardShortcut(.defaultAction)
              .disabled(!isCurrent)
          } else {
            Spacer()
            Button("Close") { resolve(accepted: false) }
              .keyboardShortcut(.defaultAction)
          }
        }
      }
      .padding(28)
    }
    .frame(width: 440)
    .frame(maxHeight: 620)
    .background(Color(nsColor: .windowBackgroundColor))
    .interactiveDismissDisabled()
  }

  private var isCurrent: Bool {
    request.matches(store.session)
      && store.rendererFailures[request.tabID] == nil
      && store.externalAppRequests.contains(request)
  }

  private var profileName: String {
    store.session.profiles.first { $0.id == request.profileID }?.name ?? "Unavailable profile"
  }

  private func resolve(accepted: Bool) {
    store.resolveExternalApp(request.id, accepted: accepted)
    dismiss()
  }
}
