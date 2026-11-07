// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import SwiftUI

enum ShaarDevToolsAccessibility {
  static let openHelp = ShellL10n.string(
    "Open Shaar DevTools with F12 or Option-Command-I. Open Chromium DevTools with Option-Shift-Command-I."
  )
  static let closeHelp = ShellL10n.string("Close Shaar DevTools with Escape.")

  static func sectionLabel(_ section: ShaarDevToolsSection) -> String {
    ShellL10n.string(section.rawValue)
  }

  static func sectionHelp(_ section: ShaarDevToolsSection) -> String {
    "\(sectionLabel(section)). "
      + ShellL10n.string("Use Left and Right Arrow to switch panels.")
  }

  static func applyMotionPreference(to transaction: inout Transaction, reduceMotion: Bool) {
    guard reduceMotion else { return }
    transaction.animation = nil
    transaction.disablesAnimations = true
  }
}

extension ShaarDevToolsSection {
  fileprivate var symbol: String {
    switch self {
    case .elements: "square.dashed.inset.filled"
    case .components: "square.stack.3d.up"
    case .console: "terminal"
    case .issues: "exclamationmark.triangle"
    case .network: "network"
    case .application: "externaldrive"
    case .performance: "speedometer"
    case .audits: "checkmark.shield"
    case .sources: "curlybraces"
    case .security: "lock"
    case .sensors: "location"
    case .repro: "record.circle"
    case .viewports: "rectangle.on.rectangle"
    case .rendering: "paintbrush"
    case .comparison: "square.split.2x1"
    }
  }

  fileprivate var shortLabel: String {
    switch self {
    case .elements: "Elements"
    case .components: "Comps"
    case .console: "Console"
    case .issues: "Issues"
    case .network: "Network"
    case .application: "App"
    case .performance: "Perf"
    case .audits: "Audits"
    case .sources: "Sources"
    case .security: "Security"
    case .sensors: "Sensors"
    case .repro: "Repro"
    case .viewports: "Views"
    case .rendering: "Render"
    case .comparison: "WebKit"
    }
  }
}

struct ShaarDevToolsPanel: View {
  @Bindable var model: ShaarDevToolsModel
  let inspector: InspectorModel?
  let openChromium: () -> Void
  var cookieStore: (any ShaarCookieStore)? = nil
  var reproDirectory: URL? = nil
  @FocusState private var focusedSection: ShaarDevToolsSection?
  @Environment(\.colorSchemeContrast) private var colorSchemeContrast
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    VStack(spacing: 0) {
      toolbar
      Divider()
      content.frame(maxWidth: .infinity, maxHeight: .infinity)
      Divider()
      commandLine
    }
    .background(Color(nsColor: .windowBackgroundColor))
    .transaction { transaction in
      ShaarDevToolsAccessibility.applyMotionPreference(
        to: &transaction, reduceMotion: reduceMotion)
    }
    .onExitCommand(perform: handleExitCommand)
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
    .overlay(alignment: .top) { commandMenuOverlay }
    .overlay { settingsOverlay }
  }

  private var toolbar: some View {
    GeometryReader { geometry in
      let showsLabels = geometry.size.width >= 700
      let visible = visibleSections(width: geometry.size.width, showsLabels: showsLabels)
      let issueCount = model.issues.count
      HStack(spacing: 3) {
        ForEach(visible, id: \.self) { section in
          sectionButton(section, showsLabel: showsLabels, issueCount: issueCount)
        }
        if visible.count < model.sections.count {
          Menu {
            ForEach(model.sections.filter { !visible.contains($0) }, id: \.self) {
              section in
              Button(ShellL10n.string(section.rawValue)) { model.section = section }
            }
          } label: {
            Image(systemName: "chevron.down")
              .frame(width: 27, height: 28)
          }
          .menuStyle(.borderlessButton)
          .help(ShellL10n.string("More panels"))
          .accessibilityLabel(ShellL10n.string("More panels"))
        }
        Spacer(minLength: 0)
        commandMenuButton
        optionsMenu
        Button {
          model.close()
        } label: {
          Image(systemName: "xmark")
            .font(.system(size: 10, weight: .semibold))
            .frame(width: 27, height: 28)
        }
        .buttonStyle(.plain)
        .help(ShaarDevToolsAccessibility.closeHelp)
        .accessibilityLabel(ShellL10n.string("Close DevTools"))
      }
      .padding(.horizontal, 7)
    }
    .frame(height: 36)
    .onMoveCommand(perform: moveSection)
  }

  private func visibleSections(width: CGFloat, showsLabels: Bool) -> [ShaarDevToolsSection] {
    let tabWidth: CGFloat = showsLabels ? 73 : 33
    let room = max(0, width - 112)
    let all = model.sections
    let fit = min(all.count, max(1, Int(room / tabWidth)))
    if fit == all.count { return all }
    let count = max(1, Int((room - 30) / tabWidth))
    let first = Array(all.prefix(count))
    if first.contains(model.section) { return first }
    return Array(first.dropLast()) + [model.section]
  }

  private func sectionButton(
    _ section: ShaarDevToolsSection, showsLabel: Bool, issueCount: Int
  ) -> some View {
    Button {
      model.section = section
      focusedSection = section
    } label: {
      HStack(spacing: 5) {
        Image(systemName: section.symbol)
          .font(.system(size: 12, weight: .medium))
        if showsLabel {
          Text(ShellL10n.string(section.shortLabel))
            .font(.system(size: 10, weight: .medium))
            .lineLimit(1)
          if section == .issues, issueCount > 0 {
            Text(verbatim: ShaarDevToolsIssues.countText(issueCount))
              .font(.system(size: 10, weight: .semibold))
              .lineLimit(1)
          }
        }
      }
      .foregroundStyle(.primary)
      .frame(width: showsLabel ? 73 : 33, height: 28)
      .background {
        if model.section == section {
          RoundedRectangle(cornerRadius: 6)
            .fill(Color.primary.opacity(colorSchemeContrast == .increased ? 0.16 : 0.08))
        }
      }
      .overlay {
        if focusedSection == section {
          RoundedRectangle(cornerRadius: 6)
            .strokeBorder(
              Color.primary, lineWidth: colorSchemeContrast == .increased ? 2 : 1)
        }
      }
    }
    .buttonStyle(.plain)
    .focusable()
    .focused($focusedSection, equals: section)
    .help(ShaarDevToolsAccessibility.sectionHelp(section))
    .accessibilityLabel(ShaarDevToolsAccessibility.sectionLabel(section))
    .accessibilityValue(sectionValue(section, issueCount: issueCount))
    .accessibilityAddTraits(model.section == section ? .isSelected : [])
    .accessibilityIdentifier("shaar.devtools.\(section.rawValue.lowercased())")
  }

  private func sectionValue(_ section: ShaarDevToolsSection, issueCount: Int) -> String {
    var parts: [String] = []
    if model.section == section { parts.append(ShellL10n.string("Selected")) }
    if section == .issues, issueCount > 0 {
      parts.append(ShaarDevToolsIssues.countText(issueCount))
    }
    return parts.joined(separator: ", ")
  }

  private var commandMenuButton: some View {
    Button(action: model.toggleCommandMenu) {
      Image(systemName: "magnifyingglass")
        .font(.system(size: 12, weight: .medium))
        .frame(width: 27, height: 28)
    }
    .buttonStyle(.plain)
    .help(ShellL10n.string("Open the command menu. Command-Shift-P."))
    .accessibilityLabel(ShellL10n.string("Command menu"))
    .accessibilityIdentifier("shaar.devtools.commandMenuButton")
  }

  @ViewBuilder private var commandMenuOverlay: some View {
    if model.commandMenuOpen {
      ZStack(alignment: .top) {
        Color.clear
          .contentShape(Rectangle())
          .onTapGesture(perform: model.closeCommandMenu)
          .accessibilityIdentifier("shaar.devtools.commandMenuDismiss")
        ShaarDevToolsCommandMenu(model: model)
          .padding(.top, 44)
          .padding(.horizontal, 16)
      }
    }
  }

  @ViewBuilder private var settingsOverlay: some View {
    if model.settingsOpen {
      ZStack {
        Color.primary.opacity(0.04)
          .contentShape(Rectangle())
          .onTapGesture(perform: model.closeSettings)
          .accessibilityIdentifier("shaar.devtools.settingsDismiss")
        ShaarDevToolsSettings(model: model)
      }
    }
  }

  private var optionsMenu: some View {
    Menu {
      Button(ShellL10n.string("Settings"), action: model.showSettings)
        .accessibilityIdentifier("shaar.devtools.settingsButton")
      Divider()
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
        .help(ShellL10n.string("Open Chromium DevTools with Option-Shift-Command-I"))
    } label: {
      Image(systemName: "ellipsis")
        .frame(width: 27, height: 28)
    }
    .menuStyle(.borderlessButton)
    .help(ShellL10n.string("DevTools options") + ". " + ShaarDevToolsAccessibility.openHelp)
    .accessibilityLabel(ShellL10n.string("DevTools options"))
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
    case .components:
      if let inspector, inspector.isOpen {
        ShaarFrameworkComponentsPanel(model: model.framework, openChromium: openChromium)
      } else {
        unavailablePanel
      }
    case .console:
      if model.consoleAvailable {
        ShaarConsolePanel(
          model: model.console, events: model.consoleEvents,
          droppedCount: model.droppedConsoleCount, inspector: inspector)
      } else {
        unavailablePanel
      }
    case .issues:
      ShaarDevToolsIssuesPanel(model: model)
    case .network:
      if model.streamAvailable {
        ShaarNetworkPanel(
          model: model.network, rules: model.rules, events: model.events,
          droppedCount: model.droppedNetworkCount,
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
        ShaarPerformancePanel(
          model: model.performance, phase2: model.phase2,
          developer: inspector?.engine?.developerModel(for: model.target))
      } else {
        unavailablePanel
      }
    case .audits:
      ShaarDevToolsAuditsPanel(model: model, inspector: inspector)
    case .sources:
      if model.phase2.available {
        ShaarSourcesPanel(model: model.sources, inspector: inspector)
      } else {
        unavailablePanel
      }
    case .security:
      ShaarDevToolsSecurityPanel(model: model)
    case .sensors:
      ShaarDevToolsSensorsPanel(model: model)
    case .repro:
      ShaarReproPanel(
        model: model.repro,
        directory: reproDirectory
          ?? inspector?.engine?.runtime.downloadsDirectory(
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
    case .rendering:
      ShaarRenderingPanel(model: model.rendering)
    case .comparison:
      if model.allowsWebKitComparison {
        ShaarWebKitComparisonPanel(
          model: model.comparison, chromiumEvents: model.consoleEvents)
      } else {
        unavailablePanel
      }
    }
  }

  private var unavailablePanel: some View {
    VStack(spacing: 10) {
      Image(systemName: "bolt.slash")
        .font(.system(size: 22, weight: .ultraLight))
        .foregroundStyle(.primary)
      Text(ShellL10n.string(unavailableMessage))
        .font(.system(size: 12, weight: .medium))
      Text(ShellL10n.string("Use Chromium DevTools until the live stream is available."))
        .font(.system(size: 11))
        .foregroundStyle(.primary)
      Button(ShellL10n.string("Open Chromium DevTools"), action: openChromium)
        .help(ShellL10n.string("Open Chromium DevTools with Option-Shift-Command-I"))
        .controlSize(.small)
        .padding(.top, 3)
      if let failure = nativeFailure {
        DisclosureGroup(ShellL10n.string("Technical details")) {
          Text(failure)
            .font(.system(size: 10, design: .monospaced))
            .textSelection(.enabled)
        }
        .frame(maxWidth: 360)
      }
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
    if model.section == .elements { return "Live DOM tree is unavailable for this tab" }
    if model.section == .components { return "Live component tree is unavailable for this tab" }
    if model.section == .application { return "Live Application is unavailable for this tab" }
    if model.section == .performance { return "Live Performance is unavailable for this tab" }
    if model.section == .sources { return "Live Sources are unavailable for this tab" }
    if model.section == .repro { return "Repro capture needs engine support" }
    if model.section == .viewports { return "Live Viewports need engine support" }
    if model.section == .comparison { return "WebKit comparison is unavailable for this tab" }
    return "Live console and network are unavailable for this tab"
  }

  private var nativeFailure: String? {
    switch model.section {
    case .application, .performance, .sources:
      return model.nativePhase2Failure ?? model.nativeStreamFailure
    default:
      return model.nativeStreamFailure
    }
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
          .foregroundStyle(.primary)
        Text(
          ShellL10n.string(
            footerMessage)
        )
        .font(.system(size: 11, design: .monospaced))
        .foregroundStyle(.primary)
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
    if model.section == .components {
      return model.framework.allowed
        ? "Components are scoped to this tab"
        : "Component tools read only localhost until you turn them on for a site."
    }
    if model.section == .issues { return "Issues are scoped to this tab" }
    if model.section == .application {
      if model.application.area == .cookies { return "Cookies are scoped to this page" }
      return model.phase2.available
        ? "Application data is scoped to this tab"
        : "Application data is unavailable for this tab"
    }
    if model.section == .performance {
      return model.phase2.available
        ? "Performance data is scoped to this tab"
        : "Performance data is unavailable for this tab"
    }
    if model.section == .audits { return "Audits are scoped to this tab" }
    if model.section == .sources {
      return model.phase2.available
        ? "Source resources are scoped to this tab"
        : "Sources are unavailable for this tab"
    }
    if model.section == .security { return "Security details are scoped to this tab" }
    if model.section == .sensors { return "Sensors are scoped to this tab" }
    if model.section == .repro { return "Repro data is scoped to this tab" }
    if model.section == .viewports {
      return model.viewports.available
        ? "Viewports are scoped to this tab"
        : "Viewports need engine support"
    }
    if model.section == .rendering { return "Rendering changes are scoped to this tab" }
    if model.section == .comparison { return "WebKit comparison is scoped to this tab" }
    guard model.streamAvailable else { return "Console commands are unavailable for this tab" }
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
      let index = model.sections.firstIndex(of: model.section)
    else { return }
    let next: Int
    switch direction {
    case .left: next = max(0, index - 1)
    case .right: next = min(model.sections.count - 1, index + 1)
    default: return
    }
    model.section = model.sections[next]
    focusedSection = model.section
  }

  private func handleExitCommand() {
    if model.settingsOpen {
      model.closeSettings()
      return
    }
    if model.commandMenuOpen {
      model.closeCommandMenu()
      return
    }
    switch model.section {
    case .elements where !model.dom.search.isEmpty:
      model.dom.search = ""
      return
    case .console where !model.console.search.isEmpty:
      model.console.search = ""
      return
    case .network where !model.network.search.isEmpty:
      model.network.search = ""
      return
    case .application where model.application.area == .cookies && !model.cookies.search.isEmpty:
      model.cookies.search = ""
      return
    case .application where !model.application.search.isEmpty:
      model.application.search = ""
      return
    case .sources where !model.sources.search.isEmpty:
      model.sources.search = ""
      return
    default:
      model.close()
    }
  }
}
