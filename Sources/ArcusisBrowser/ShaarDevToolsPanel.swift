// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import SwiftUI

struct ShaarDevToolsPanel: View {
  @Bindable var model: ShaarDevToolsModel
  let inspector: InspectorModel?
  let openChromium: () -> Void
  var cookieStore: (any ShaarCookieStore)? = nil
  var reproDirectory: URL? = nil
  @FocusState private var focusedSection: ShaarDevToolsSection?

  var body: some View {
    VStack(spacing: 0) {
      toolbar
      Divider()
      content.frame(maxWidth: .infinity, maxHeight: .infinity)
      Divider()
      commandLine
    }
    .background(Color(nsColor: .windowBackgroundColor))
    .onExitCommand { model.close() }
    .onChange(of: inspector?.isOpen) { _, open in
      if open == false && model.isOpen { model.close() }
    }
    .onChange(of: model.sources.localRoot) { _, root in
      Task {
        do { try await model.rules.useProjectRoot(root) } catch {
          model.rules.failure = error.localizedDescription
        }
      }
    }
    .accessibilityIdentifier("shaar.devtools.shell")
  }

  private var toolbar: some View {
    HStack(spacing: 4) {
      Image(systemName: "chevron.left.forwardslash.chevron.right")
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(.secondary)
        .frame(width: 28)
      ForEach(ShaarDevToolsSection.allCases, id: \.self) { section in
        Button {
          model.section = section
          focusedSection = section
        } label: {
          Text(ShellL10n.string(section.rawValue))
            .font(.system(size: 11, weight: model.section == section ? .semibold : .regular))
            .foregroundStyle(model.section == section ? .primary : .secondary)
            .padding(.horizontal, 11)
            .frame(height: 29)
            .background {
              if model.section == section {
                RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.08))
              }
            }
        }
        .buttonStyle(.plain)
        .focusable()
        .focused($focusedSection, equals: section)
        .accessibilityAddTraits(model.section == section ? .isSelected : [])
        .accessibilityIdentifier("shaar.devtools.\(section.rawValue.lowercased())")
      }
      Spacer(minLength: 8)
      Menu {
        ForEach(ShaarDevToolsDock.allCases, id: \.self) { dock in
          Button(ShellL10n.string(dock.rawValue)) { model.dock = dock }
        }
        Divider()
        if model.canTapLocalLogs {
          if model.hasLogTap {
            Button(ShellL10n.string("Disconnect server log")) { model.disconnectLogTap() }
          } else {
            Button(ShellL10n.string("Connect server log file…"), action: chooseLogFile)
          }
          Divider()
        }
        Button(ShellL10n.string("Open Chromium DevTools"), action: openChromium)
      } label: {
        Image(systemName: "ellipsis")
          .frame(width: 28, height: 28)
      }
      .menuStyle(.borderlessButton)
      .help(ShellL10n.string("DevTools options"))
      .accessibilityLabel(ShellL10n.string("DevTools options"))
      Button {
        model.close()
      } label: {
        Image(systemName: "xmark")
          .font(.system(size: 10, weight: .semibold))
          .frame(width: 28, height: 28)
      }
      .buttonStyle(.plain)
      .help(ShellL10n.string("Close DevTools"))
      .accessibilityLabel(ShellL10n.string("Close DevTools"))
    }
    .padding(.horizontal, 7)
    .frame(height: 36)
    .onMoveCommand(perform: moveSection)
  }

  @ViewBuilder private var content: some View {
    switch model.section {
    case .elements:
      if let inspector, inspector.isOpen {
        ShaarDOMTreePanel(
          model: model.dom, inspector: inspector, openChromium: openChromium)
      } else {
        unavailablePanel
      }
    case .console:
      if model.consoleAvailable {
        ShaarConsolePanel(model: model.console, events: model.consoleEvents, inspector: inspector)
      } else {
        unavailablePanel
      }
    case .network:
      if model.streamAvailable {
        ShaarNetworkPanel(
          model: model.network, rules: model.rules, events: model.events,
          openChromium: openChromium)
      } else {
        unavailablePanel
      }
    case .application:
      ShaarApplicationPanel(
        model: model.application, cookies: model.cookies, phase2: model.phase2,
        target: model.target, cookieStore: cookieStore ?? inspector?.engine,
        openChromium: openChromium,
        clearCookies: siteAction(.clearCookiesAndReload),
        clearSiteData: siteAction(.clearSiteData))
    case .performance:
      if model.phase2.available {
        ShaarPerformancePanel(model: model.performance, phase2: model.phase2)
      } else {
        unavailablePanel
      }
    case .sources:
      if model.phase2.available {
        ShaarSourcesPanel(model: model.sources, inspector: inspector)
      } else {
        unavailablePanel
      }
    case .repro:
      ShaarReproPanel(
        model: model.repro,
        directory: reproDirectory ?? inspector?.engine?.runtime.downloadsDirectory(
          forProfileID: model.target.profileID.uuidString),
        onSaved: { file in
          inspector?.engine?.downloads.registerGeneratedFile(
            file, profileID: model.target.profileID)
        })
    case .viewports:
      if model.viewports.available {
        ShaarViewportsPanel(model: model.viewports)
      } else {
        unavailablePanel
      }
    }
  }

  private var unavailablePanel: some View {
    VStack(spacing: 10) {
      Image(systemName: "bolt.slash")
        .font(.system(size: 22, weight: .ultraLight))
        .foregroundStyle(.tertiary)
      Text(ShellL10n.string(unavailableMessage))
        .font(.system(size: 12, weight: .medium))
      Text(ShellL10n.string("Use Chromium DevTools until the live stream is available."))
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
      Button(ShellL10n.string("Open Chromium DevTools"), action: openChromium)
        .controlSize(.small)
        .padding(.top, 3)
      if model.section == .console && model.canTapLocalLogs {
        Button(ShellL10n.string("Connect server log file…"), action: chooseLogFile)
          .controlSize(.small)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .multilineTextAlignment(.center)
    .padding(24)
    .accessibilityIdentifier("shaar.devtools.streamUnavailable")
  }

  private var unavailableMessage: String {
    if model.section == .elements { return "Live DOM tree needs a newer Shaar engine" }
    if model.section == .application { return "Live Application needs engine shaar.17" }
    if model.section == .performance { return "Live Performance needs engine shaar.17" }
    if model.section == .sources { return "Live Sources need engine shaar.17" }
    if model.section == .repro { return "Repro capture needs engine support" }
    if model.section == .viewports { return "Live Viewports need engine support" }
    return "Live console and network need engine shaar.17"
  }

  private func chooseLogFile() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.begin { response in
      guard response == .OK, let file = panel.url else { return }
      Task { @MainActor in _ = model.connectLogTap(file) }
    }
  }

  @ViewBuilder private var commandLine: some View {
    if model.streamAvailable && model.section == .console {
      ShaarConsoleCommandLine(model: model.console, inspector: inspector)
    } else {
      HStack(spacing: 8) {
        Text(">")
          .font(.system(size: 12, weight: .medium, design: .monospaced))
          .foregroundStyle(.secondary)
        Text(
          ShellL10n.string(
            footerMessage)
        )
        .font(.system(size: 11, design: .monospaced))
        .foregroundStyle(.tertiary)
        Spacer()
      }
      .padding(.horizontal, 12)
      .frame(height: 34)
    }
  }

  private var footerMessage: String {
    if model.section == .elements {
      return model.dom.available
        ? "DOM tree is scoped to this tab" : "DOM tree needs engine support"
    }
    if model.section == .application {
      if model.application.area == .cookies { return "Cookies are scoped to this page" }
      return model.phase2.available
        ? "Application data is scoped to this tab"
        : "Application data needs engine shaar.17"
    }
    if model.section == .performance {
      return model.phase2.available
        ? "Performance data is scoped to this tab"
        : "Performance data needs engine shaar.17"
    }
    if model.section == .sources {
      return model.phase2.available
        ? "Source resources are scoped to this tab"
        : "Sources need engine shaar.17"
    }
    if model.section == .repro { return "Repro data is scoped to this tab" }
    if model.section == .viewports {
      return model.viewports.available
        ? "Viewports are scoped to this tab"
        : "Viewports need engine support"
    }
    guard model.streamAvailable else { return "Console commands need engine shaar.17" }
    if model.section == .network { return "Network requests are scoped to this tab" }
    return "Open Console to evaluate JavaScript"
  }

  private func siteAction(_ action: SiteAction) -> (() async throws -> Void)? {
    guard let engine = inspector?.engine else { return nil }
    let target = model.target
    return { try await engine.perform(action, for: target) }
  }

  private func moveSection(_ direction: MoveCommandDirection) {
    guard focusedSection != nil,
      let index = ShaarDevToolsSection.allCases.firstIndex(of: model.section)
    else { return }
    let next: Int
    switch direction {
    case .left: next = max(0, index - 1)
    case .right: next = min(ShaarDevToolsSection.allCases.count - 1, index + 1)
    default: return
    }
    model.section = ShaarDevToolsSection.allCases[next]
    focusedSection = model.section
  }
}
