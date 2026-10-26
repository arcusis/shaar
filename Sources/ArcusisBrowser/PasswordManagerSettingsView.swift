import BrowserCore
import SwiftUI

struct PasswordManagerSettingsView: View {
  @Bindable var controller: NativeBitwardenController
  @State private var customBaseURL: String

  init(controller: NativeBitwardenController) {
    self.controller = controller
    _customBaseURL = State(initialValue: controller.serverConfiguration.customBaseURL ?? "")
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack {
        Text("Native Bitwarden")
          .font(.headline)
        Spacer()
        Toggle(
          "Enable for this Profile",
          isOn: Binding(
            get: { controller.isEnabled }, set: { controller.setEnabled($0) })
        )
        .labelsHidden()
        .toggleStyle(.switch)
        .accessibilityLabel("Enable Native Bitwarden for this Profile")
      }

      Picker(
        "Server",
        selection: Binding(
          get: { controller.serverConfiguration.region },
          set: {
            controller.setServer(
              BitwardenServerConfiguration(
                region: $0, customBaseURL: controller.serverConfiguration.customBaseURL))
          })
      ) {
        Text("United States").tag(BitwardenServerRegion.us)
        Text("European Union").tag(BitwardenServerRegion.eu)
        Text("Custom server").tag(BitwardenServerRegion.custom)
      }
      .accessibilityIdentifier("settings.nativeBitwarden.server")

      if controller.serverConfiguration.region == .custom {
        HStack(spacing: 8) {
          TextField("https://vault.example", text: $customBaseURL)
            .textFieldStyle(.roundedBorder)
            .accessibilityLabel("Custom Bitwarden service URL")
          Button("Apply") {
            controller.setServer(
              BitwardenServerConfiguration(region: .custom, customBaseURL: customBaseURL))
          }
          .disabled(customBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        Text("Enter the HTTPS service base URL. API and identity paths are derived from it.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      TextField("Email", text: $controller.email)
        .textContentType(.username)
        .textFieldStyle(.roundedBorder)
        .disabled(!controller.isEnabled)
        .accessibilityIdentifier("settings.nativeBitwarden.email")
      SecureField("Master password", text: $controller.masterPassword)
        .textContentType(.password)
        .textFieldStyle(.roundedBorder)
        .disabled(!controller.isEnabled)
        .accessibilityIdentifier("settings.nativeBitwarden.password")

      if !controller.supportedMFAProviders.isEmpty {
        Picker("Verification method", selection: $controller.selectedMFAProvider) {
          ForEach(controller.supportedMFAProviders) { provider in
            Text(provider.title).tag(provider)
          }
        }
        SecureField("Verification response", text: $controller.mfaToken)
          .textFieldStyle(.roundedBorder)
          .accessibilityIdentifier("settings.nativeBitwarden.mfa")
      }

      HStack(spacing: 10) {
        Button("Connect / Unlock") { controller.connect() }
          .buttonStyle(.borderedProminent)
          .disabled(!controller.isEnabled || !controller.sdkAvailable || controller.isLoading)
          .accessibilityIdentifier("settings.nativeBitwarden.connect")
        Button("Lock") { controller.lock() }
          .disabled(!controller.hasConnectedSession || controller.isLoading)
        Button("Disconnect") { controller.disconnect() }
          .disabled(!controller.hasOwnedCredentials && !controller.hasConnectedSession)
      }

      HStack(spacing: 8) {
        if controller.isLoading { ProgressView().controlSize(.small) }
        Text(controller.status)
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("settings.nativeBitwarden.status")
      }
      Text("Vault sessions belong to this Profile and are shared by its Spaces.")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .padding(14)
    .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
    .onChange(of: controller.selectedProfileID) { _, _ in
      customBaseURL = controller.serverConfiguration.customBaseURL ?? ""
    }
  }
}
