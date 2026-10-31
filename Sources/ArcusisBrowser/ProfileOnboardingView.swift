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
      Text("Step \(step.rawValue + 1) of \(ProfileOnboardingStep.allCases.count)")
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
      Text("A profile keeps its own sign-ins, cookies, history and extensions.")
        .foregroundStyle(.secondary)
      HStack(spacing: 12) {
        SymbolPickerButton(
          symbol: $model.symbol, isPresented: $symbolPickerIsPresented,
          accessibilityLabel: "Change Profile Icon")
        TextField("Profile name", text: $model.name)
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
          Text("Finish signing in to \(provider.title) in the sign-in window.")
            .foregroundStyle(.secondary)
        }
      } else {
        ProviderConnectButton(provider: provider) { model.connect(provider) }
      }
      Text(
        "Optional. A profile connects one account, Google or Microsoft. You can also connect it later in Settings > Profiles."
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
        Text("Connect \(provider.title)")
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
        Text("No account connected. You can connect one later in Settings > Profiles.")
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
      Button("Cancel") { model.cancel() }
        .keyboardShortcut(.cancelAction)
      Spacer()
      Button("Back") { model.back() }
        .disabled(!model.canGoBack)
      if model.step.provider != nil {
        Button("Skip") { model.skip() }
          .disabled(!model.canSkip)
      }
      Button(primaryTitle) { model.continueToNext() }
        .keyboardShortcut(.defaultAction)
        .disabled(!model.canContinue)
    }
  }

  private var primaryTitle: String {
    model.step == .done ? "Create Profile" : "Continue"
  }
}

extension AccountProvider {
  fileprivate var onboardingDescription: String {
    switch self {
    case .google:
      "Sign in with a personal Google account or a Google Workspace account. If your company signs in through its own identity provider, that page opens in the same window and returns to Google."
    case .microsoft:
      "Sign in with a personal Microsoft account or a work or school account. Company sign-in through Okta, Azure AD, ADFS, Ping or a similar provider opens in the same window and returns to Microsoft."
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
    window.title = "New Profile"
    window.isReleasedWhenClosed = false
    window.contentView = NSHostingView(rootView: ProfileOnboardingView(model: model))
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
