// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import BrowserCore
import SwiftUI

enum ProfileOnboardingAccessibility {
  static func signInProgressLabel(
    provider: String, language: BrowserLanguage = .currentLaunchLanguage
  ) -> String {
    BrowserLocalization.format(
      "Finish signing in to %@ in the sign-in window.", table: "Settings", language: language,
      arguments: [.string(provider)])
  }
}

/// One choice per step, followed by an optional account and a summary.
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
    case .name, .icon, .color:
      ProfileDetailsStep(model: model)
    case .account:
      AccountConnectStep(model: model)
    case .done:
      ProfileSummaryStep(model: model)
    }
  }
}

struct OnboardingStepHeader: View {
  static let headingTraits: AccessibilityTraits = .isHeader
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
        .accessibilityAddTraits(Self.headingTraits)
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
        ProfileBadge(color: model.color.rgb, symbol: model.symbol, size: 48)
        Text(model.trimmedName).font(.headline).lineLimit(1)
      }
      switch model.step {
      case .name:
        TextField(SettingsL10n.string("Profile name"), text: $model.name)
          .textFieldStyle(.roundedBorder)
          .accessibilityLabel(SettingsL10n.string("Profile name"))
          .focused($nameFocused)
          .onSubmit { model.continueToNext() }
          .accessibilityIdentifier("onboarding.name")
      case .icon:
        SymbolPickerButton(
          symbol: $model.symbol, isPresented: $symbolPickerIsPresented,
          accessibilityLabel: SettingsL10n.string("Change Profile Icon"))
      case .color:
        ProfileColorPicker(color: $model.color)
      case .account, .done:
        EmptyView()
      }
    }
    .onAppear { nameFocused = model.step == .name }
    .onChange(of: model.step) { _, step in nameFocused = step == .name }
  }
}

private struct AccountConnectStep: View {
  let model: ProfileOnboardingModel

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text(
        SettingsL10n.string(
          "One primary account per profile. For another account, create another profile.")
      )
      .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      if let account = model.stepAccount {
        ConnectedAccountRow(account: account, color: model.color.rgb)
      } else if let provider = model.connecting {
        HStack(spacing: 10) {
          ProgressView().controlSize(.small)
            .accessibilityLabel(ProfileOnboardingAccessibility.signInProgressLabel(provider: provider.title))
          Text(
            ProfileOnboardingAccessibility.signInProgressLabel(provider: provider.title)
          )
          .foregroundStyle(.secondary)
        }
      } else {
        ForEach(AccountSignInOption.allCases) { option in
          VStack(alignment: .leading, spacing: 4) {
            ProviderConnectButton(option: option) { model.connect(option: option) }
            if option.provider != .microsoft {
              Text(option.provider.onboardingDescription).font(.caption).foregroundStyle(.secondary)
            }
          }
        }
      }
      Text(
        SettingsL10n.string(
          "Optional. Sign in on the provider’s own page, or connect later in Settings > Profiles."
        )
      )
      .font(.caption)
      .foregroundStyle(.secondary)
    }
  }
}

private struct ProviderConnectButton: View {
  let option: AccountSignInOption
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 10) {
        if let logo = option.provider.logo {
          Image(nsImage: logo).resizable().frame(width: 18, height: 18)
        }
        Text(SettingsL10n.format("Connect %@", .string(option.title)))
      }
      .padding(.horizontal, 6)
      .padding(.vertical, 2)
    }
    .controlSize(.large)
    .accessibilityIdentifier("onboarding.connect.\(option.rawValue)")
  }
}

private struct ProfileSummaryStep: View {
  let model: ProfileOnboardingModel

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack(spacing: 12) {
        ProfileIdentityBadge(
          account: model.stepAccount, color: model.color.rgb, symbol: model.symbol, size: 48)
        Text(model.trimmedName).font(.headline).lineLimit(1)
      }
      if model.connectedAccounts.isEmpty {
        Text(
          SettingsL10n.string(
            "No account connected. You can connect one later in Settings > Profiles.")
        )
        .foregroundStyle(.secondary)
      } else {
        ForEach(model.connectedAccounts, id: \.provider) {
          ConnectedAccountRow(account: $0, color: model.color.rgb)
        }
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
      Button(SettingsL10n.string("Cancel"), role: .cancel) { model.cancel() }
        .keyboardShortcut(.cancelAction)
      Spacer()
      Button(SettingsL10n.string("Back")) { model.back() }
        .disabled(!model.canGoBack)
      if model.step == .account {
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
      SettingsL10n.string("Personal or Google Workspace")
    case .microsoft:
      SettingsL10n.string("Personal, work or school")
    case .apple:
      SettingsL10n.string("Apple Account and iCloud")
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
