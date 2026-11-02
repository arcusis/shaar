// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import BrowserCore
import SwiftUI

/// New Profile onboarding: name, icon and color, an optional Google or Microsoft sign-in, then
/// done.
struct ProfileOnboardingView: View {
  let model: ProfileOnboardingModel

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      OnboardingStepHeader(step: model.step)
        .padding([.horizontal, .top], 24)
      stepContent
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      Divider()
      OnboardingFooter(model: model)
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }
    .frame(minWidth: ProfileOnboardingView.size.width, minHeight: ProfileOnboardingView.size.height)
    .background(Color(nsColor: .windowBackgroundColor))
  }

  static let size = NSSize(width: 500, height: 560)

  @ViewBuilder private var stepContent: some View {
    switch model.step {
    case .details:
      ProfileDetailsStep(model: model)
    case .google, .microsoft:
      if let provider = model.step.provider {
        AccountConnectStep(model: model, provider: provider)
      }
    case .done:
      ProfileSummaryStep(model: model)
    }
  }
}

private struct OnboardingStepHeader: View {
  let step: ProfileOnboardingStep

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 6) {
        ForEach(ProfileOnboardingStep.allCases, id: \.self) { item in
          Capsule().fill(progressColor(reached: item.rawValue <= step.rawValue)).frame(height: 4)
        }
      }
      .accessibilityHidden(true)
      Text(
        SettingsL10n.format(
          "Step %d of %d", .integer(step.rawValue + 1),
          .integer(ProfileOnboardingStep.allCases.count))
      )
      .font(.caption)
      .foregroundStyle(.secondary)
      Text(step.title).font(.title2.weight(.semibold))
    }
  }

  private func progressColor(reached: Bool) -> Color {
    reached ? .accentColor : .secondary.opacity(0.25)
  }
}

private struct ProfileDetailsStep: View {
  @Bindable var model: ProfileOnboardingModel
  @FocusState private var nameFocused: Bool
  @State private var symbolPickerIsPresented = false

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text(
        SettingsL10n.string("A profile keeps its own sign-ins, cookies, history and extensions.")
      )
      .foregroundStyle(.secondary)
      HStack(spacing: 12) {
        SymbolPickerButton(
          symbol: $model.symbol, isPresented: $symbolPickerIsPresented,
          accessibilityLabel: SettingsL10n.string("Change Profile Icon"))
        TextField(SettingsL10n.string("Profile name"), text: $model.name)
          .textFieldStyle(.roundedBorder)
          .focused($nameFocused)
          .onSubmit { model.continueToNext() }
          .accessibilityIdentifier("onboarding.name")
      }
      ProfileColorPicker(color: $model.color)
    }
    .onAppear { nameFocused = true }
  }
}

private struct AccountConnectStep: View {
  let model: ProfileOnboardingModel
  let provider: AccountProvider

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text(provider.onboardingDescription).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      if let account = model.stepAccount {
        ConnectedAccountRow(account: account)
      } else if model.connecting == provider {
        HStack(spacing: 10) {
          ProgressView().controlSize(.small)
          Text(
            SettingsL10n.format(
              "Finish signing in to %@ in the sign-in window.", .string(provider.title))
          )
          .foregroundStyle(.secondary)
        }
      } else {
        ProviderConnectButton(provider: provider) { model.connect(provider) }
      }
      Text(
        SettingsL10n.string(
          "Optional. A profile connects one account, Google or Microsoft. You can also connect it later in Settings > Profiles."
        )
      )
      .font(.caption)
      .foregroundStyle(.secondary)
    }
  }
}

private struct ProviderConnectButton: View {
  let provider: AccountProvider
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 10) {
        if let logo = provider.logo {
          Image(nsImage: logo).resizable().frame(width: 18, height: 18)
        }
        Text(SettingsL10n.format("Connect %@", .string(provider.title)))
      }
      .padding(.horizontal, 6)
      .padding(.vertical, 2)
    }
    .controlSize(.large)
    .accessibilityIdentifier("onboarding.connect.\(provider.rawValue)")
  }
}

private struct ProfileSummaryStep: View {
  let model: ProfileOnboardingModel

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack(spacing: 12) {
        ProfileBadge(color: model.color.rgb, symbol: model.symbol, size: 36)
        Text(model.trimmedName).font(.headline).lineLimit(1)
      }
      if model.connectedAccounts.isEmpty {
        Text(
          SettingsL10n.string(
            "No account connected. You can connect one later in Settings > Profiles.")
        )
        .foregroundStyle(.secondary)
      } else {
        ForEach(model.connectedAccounts, id: \.provider) { ConnectedAccountRow(account: $0) }
      }
      if let failure = model.failure {
        Text(failure).foregroundStyle(.red)
      }
    }
  }
}

private struct OnboardingFooter: View {
  let model: ProfileOnboardingModel

  var body: some View {
    HStack {
      Button(SettingsL10n.string("Cancel")) { model.cancel() }
        .keyboardShortcut(.cancelAction)
      Spacer()
      Button(SettingsL10n.string("Back")) { model.back() }
        .disabled(!model.canGoBack)
      if model.step.provider != nil {
        Button(SettingsL10n.string("Skip")) { model.skip() }
          .disabled(!model.canSkip)
      }
      Button(primaryTitle) { model.continueToNext() }
        .keyboardShortcut(.defaultAction)
        .disabled(!model.canContinue)
    }
  }

  private var primaryTitle: String {
    SettingsL10n.string(model.step == .done ? "Create Profile" : "Continue")
  }
}

extension AccountProvider {
  fileprivate var onboardingDescription: String {
    switch self {
    case .google:
      SettingsL10n.string(
        "Sign in with a personal Google account or a Google Workspace account. If your company signs in through its own identity provider, that page opens in the same window and returns to Google."
      )
    case .microsoft:
      SettingsL10n.string(
        "Sign in with a personal Microsoft account or a work or school account. Company sign-in through Okta, Azure AD, ADFS, Ping or a similar provider opens in the same window and returns to Microsoft."
      )
    }
  }
}

/// Hosts one onboarding in its own window; closing the window cancels it.
@MainActor
final class ProfileOnboardingWindow: NSObject, NSWindowDelegate {
  let model: ProfileOnboardingModel
  let window: NSWindow

  init(model: ProfileOnboardingModel) {
    self.model = model
    window = NSWindow(
      contentRect: NSRect(origin: .zero, size: ProfileOnboardingView.size),
      styleMask: [.titled, .closable], backing: .buffered, defer: false)
    super.init()
    window.title = SettingsL10n.string("New Profile")
    window.isReleasedWhenClosed = false
    window.contentView = NSHostingView(
      rootView: ProfileOnboardingView(model: model).settingsLocalization())
    window.delegate = self
  }

  func show() {
    if !window.isVisible { window.center() }
    window.makeKeyAndOrderFront(nil)
  }

  func close() {
    window.delegate = nil
    window.orderOut(nil)
  }

  func windowShouldClose(_ sender: NSWindow) -> Bool {
    model.cancel()
    return false
  }
}
