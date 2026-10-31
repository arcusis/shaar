import BrowserCore
import SwiftUI

struct ExtensionConsent: View {
  let store: BrowserStore
  let request: ExtensionInstallRequest
  @Environment(\.dismiss) private var dismiss
  @State private var acknowledgedUnknownAccess = false

  private var hasUnknownAccess: Bool {
    request.permissions.contains(ExtensionConsentPermissions.unknownAccess)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      Label("\(request.kind.actionTitle)?", systemImage: "puzzlepiece.extension")
        .font(.title2.weight(.semibold))
      VStack(alignment: .leading, spacing: 5) {
        Text(request.browserExtension.name).font(.headline)
        Text("Version \(request.browserExtension.version)").font(.caption).foregroundStyle(
          .secondary)
        Text(request.browserExtension.id).font(.caption.monospaced()).foregroundStyle(.secondary)
      }
      LabeledContent("Profile", value: profileName)
      LabeledContent(
        "Page", value: request.sourceURL.host() ?? request.sourceURL.absoluteString)
      Divider()
      Text("This extension can:").font(.headline)
      ScrollView {
        VStack(alignment: .leading, spacing: 12) {
          if request.permissions.isEmpty {
            Text("No additional permission warnings were reported by the browser engine.")
          }
          ForEach(Array(request.permissions.enumerated()), id: \.offset) { _, permission in
            Label {
              Text(permission).fixedSize(horizontal: false, vertical: true)
            } icon: {
              Image(systemName: "checkmark.shield")
            }
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .frame(minHeight: 75, maxHeight: 200)
      if hasUnknownAccess {
        VStack(alignment: .leading, spacing: 8) {
          Label("Unknown access", systemImage: "exclamationmark.triangle.fill")
            .font(.headline).foregroundStyle(.orange)
          Text(
            "Browser engine did not provide a complete site access list. Extension may access sites not listed above."
          )
          .font(.callout)
          Toggle("I understand and want to continue", isOn: $acknowledgedUnknownAccess)
            .font(.callout)
        }
        .padding(12)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
      }
      Text("Applies to all spaces sharing the \(profileName) profile.")
        .font(.caption).foregroundStyle(.secondary)
      HStack {
        Button("Cancel", role: .cancel) { resolve(accepted: false) }
          .keyboardShortcut(.cancelAction)
        Spacer()
        Button(request.kind.actionTitle) { resolve(accepted: true) }
          .disabled(
            !request.matches(store.session) || (hasUnknownAccess && !acknowledgedUnknownAccess))
      }
    }
    .padding(28)
    .frame(width: 460)
    .background(Color(nsColor: .windowBackgroundColor))
    .interactiveDismissDisabled()
    .onChange(of: request.id) { _, _ in acknowledgedUnknownAccess = false }
  }

  private var profileName: String {
    store.session.profiles.first { $0.id == request.profileID }?.name ?? "Unavailable profile"
  }

  private func resolve(accepted: Bool) {
    store.resolveInstallation(request.id, accepted: accepted)
    dismiss()
  }
}
