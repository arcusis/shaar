// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import BrowserCore
import SwiftUI

struct DevelopmentModeButton: View {
  let engine: BrowserEngine
  @AppStorage(DevelopmentModePreference.key) private var enabled = true
  @State private var clearTarget: SiteControlTarget?

  var body: some View {
    if enabled, let target = engine.siteControlTarget,
      let page = engine.selectedDevelopmentPage
    {
      Menu {
        Button(ShellL10n.string("Developer Tools")) {
          engine.togglePublicDeveloperTools()
        }
        Button(ShellL10n.string("Open Inspector")) {
          engine.toggleInspector(for: target)
        }
        Divider()
        Button(ShellL10n.string("Hard Reload")) {
          run(.hardReload, for: target)
        }
        Button(ShellL10n.string("Clear Site Data")) {
          clearTarget = target
        }
        Button(ShellL10n.string("Copy URL")) {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(target.url.absoluteString, forType: .string)
        }
      } label: {
        DevelopmentModeLabel(
          page: page, budget: ShaarPerformanceBudgetStatusRegistry.shared.result(for: target.tabID))
      }
      .menuStyle(.borderlessButton)
      .fixedSize()
      .help(ShellL10n.string("Development page actions"))
      .accessibilityLabel(ShellL10n.string("Development page actions"))
      .accessibilityIdentifier("browser.developmentMode")
      .confirmationDialog(
        ShellL10n.string("Clear site data for this page?"),
        isPresented: Binding(
          get: { clearTarget != nil },
          set: { if !$0 { clearTarget = nil } })
      ) {
        Button(ShellL10n.string("Clear Site Data"), role: .destructive) {
          if let clearTarget { run(.clearSiteData, for: clearTarget) }
          clearTarget = nil
        }
        Button(ShellL10n.string("Cancel"), role: .cancel) { clearTarget = nil }
      }
    }
  }

  private func run(_ action: SiteAction, for target: SiteControlTarget) {
    Task {
      do { try await engine.perform(action, for: target) } catch {
        engine.reportNotice(action.failureNotice())
      }
    }
  }
}

struct DevelopmentModeLabel: View {
  let page: DevelopmentPage
  var budget: ShaarPerformanceBudgetResult? = nil

  var body: some View {
    HStack(spacing: 3) {
      Image(systemName: "chevron.left.forwardslash.chevron.right")
      Text(page.detectedFramework?.rawValue ?? ShellL10n.string("Dev Mode"))
      if let port = page.port { Text(verbatim: ":\(port)") }
      if let budget {
        Image(systemName: budget.badgeSymbol)
          .foregroundStyle(budget.badgeColor)
          .help(budget.accessibilityDescription())
          .accessibilityLabel(budget.accessibilityDescription())
      }
    }
    .font(.system(size: 11, weight: .semibold))
    .foregroundStyle(.primary)
    .padding(.horizontal, 7)
    .frame(height: 28)
    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 5))
    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.primary.opacity(0.12)))
  }
}

extension ShaarPerformanceBudgetResult {
  func accessibilityDescription(
    language: BrowserLanguage = .currentLaunchLanguage
  ) -> String {
    BrowserLocalization.format(
      "Route budget: %1$d passed, %2$d over, %3$d unavailable", table: "Shell",
      language: language,
      arguments: [.integer(passed), .integer(failed), .integer(unavailable)])
  }

  fileprivate var badgeSymbol: String {
    if failed > 0 { return "exclamationmark.circle.fill" }
    if unavailable > 0 { return "questionmark.circle.fill" }
    return "checkmark.circle.fill"
  }

  fileprivate var badgeColor: Color {
    if failed > 0 { return .red }
    if unavailable > 0 { return .secondary }
    return .green
  }
}
