// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import BrowserCore
import SwiftUI

enum FirstRunLocation: Equatable {
  case installed, diskImage, downloads

  init(application: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) {
    let path = application.standardizedFileURL.path
    if path.hasPrefix("/Volumes/") || path.contains("/AppTranslocation/") {
      self = .diskImage
    } else if path.hasPrefix(home.appending(path: "Downloads").path + "/") {
      self = .downloads
    } else {
      self = .installed
    }
  }

  var needsInstallation: Bool { self != .installed }
}

enum FirstRunState {
  static func pendingMarker(in directory: URL) throws -> URL? {
    let marker = directory.appending(path: "first-run-pending")
    let workspace = directory.appending(path: "workspace.json")
    let legacySession = directory.appending(path: "session.json")
    if !FileManager.default.fileExists(atPath: workspace.path),
      !FileManager.default.fileExists(atPath: legacySession.path),
      !FileManager.default.fileExists(atPath: marker.path)
    {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try Data().write(to: marker, options: .atomic)
    }
    return FileManager.default.fileExists(atPath: marker.path) ? marker : nil
  }

  static func complete(_ marker: URL) throws {
    try FileManager.default.removeItem(at: marker)
  }
}

enum FirstRunBrand {
  static var name: String { name(language: .currentLaunchLanguage) }

  static func name(language: BrowserLanguage) -> String {
    language == .hebrew ? "שער" : ProductIdentity.name
  }
}

enum FirstRunStep: Int, CaseIterable {
  case welcome, importData, defaultBrowser, space, keychain, ready

  var title: String {
    switch self {
    case .welcome: SettingsL10n.format("Welcome to %@", .string(FirstRunBrand.name))
    case .importData: SettingsL10n.string("Bring your bookmarks")
    case .defaultBrowser: SettingsL10n.format("Make %@ your default", .string(FirstRunBrand.name))
    case .space: SettingsL10n.string("Make your first Space yours")
    case .keychain: SettingsL10n.string("Your passwords stay protected")
    case .ready: SettingsL10n.string("Ready to browse")
    }
  }
}

struct FirstRunSetupView: View {
  static func progressAccessibilityLabel(for step: FirstRunStep) -> String {
    SettingsL10n.format(
      "Step %d of %d", .integer(step.rawValue + 1), .integer(FirstRunStep.allCases.count))
  }

  let store: BrowserStore
  let location: FirstRunLocation
  let onFinish: () -> Void
  @State private var step = FirstRunStep.welcome
  @State private var showImport = false
  @State private var defaultStatus = false
  @State private var defaultError: String?

  @State private var spaceName: String
  @State private var spaceError: String?

  init(
    store: BrowserStore, location: FirstRunLocation, initialStep: FirstRunStep = .welcome,
    onFinish: @escaping () -> Void
  ) {
    self.store = store
    self.location = location
    self.onFinish = onFinish
    _step = State(initialValue: initialStep)
    _spaceName = State(initialValue: store.session.selectedSpace.name)
  }

  static func defaultBrowserFailure(language: BrowserLanguage = .currentLaunchLanguage) -> String {
    BrowserLocalization.string(
      "Could not set the default browser.", table: "Settings", language: language)
  }

  var body: some View {
    HStack(spacing: 0) {
      brandPanel
      VStack(alignment: .leading, spacing: 0) {
        progress
        VStack(alignment: .leading, spacing: 16) {
          Text(step.title).font(.largeTitle.weight(.semibold))
          stepContent
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(36)
        Divider()
        footer.padding(24)
      }
      .frame(width: 480)
    }
    .frame(width: 760, height: 500)
    .background(Color(nsColor: .windowBackgroundColor))
    .sheet(isPresented: $showImport) {
      LibraryPanel(
        store: store, profileID: store.session.selectedSpace.profileID, section: .bookmarks)
    }
    .onAppear { defaultStatus = DefaultBrowserService.isDefault() }
  }

  private var brandPanel: some View {
    VStack(alignment: .leading, spacing: 24) {
      Image(nsImage: Self.brandIcon)
        .resizable().frame(width: 72, height: 72)
        .accessibilityHidden(true)
      Spacer()
      Text(verbatim: "שער").font(.system(size: 48, weight: .medium, design: .rounded))
        .foregroundStyle(.white)
      Text(SettingsL10n.string("A gateway to your web."))
        .font(.title3).foregroundStyle(.white.opacity(0.8))
    }
    .padding(28)
    .frame(width: 280)
    .frame(maxHeight: .infinity, alignment: .leading)
    .background(
      LinearGradient(
        colors: [
          Color(red: 0.01, green: 0.4, blue: 0.28), Color(red: 0.03, green: 0.10, blue: 0.07),
        ],
        startPoint: .topLeading, endPoint: .bottomTrailing))
  }

  private var progress: some View {
    HStack(spacing: 5) {
      ForEach(FirstRunStep.allCases, id: \.self) { item in
        Capsule()
          .fill(item.rawValue <= step.rawValue ? Color.accentColor : Color.secondary.opacity(0.2))
          .frame(height: 3)
      }
    }
    .padding(.horizontal, 36).padding(.top, 30)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(Self.progressAccessibilityLabel(for: step))
    .accessibilityAddTraits(.updatesFrequently)
  }

  private static var brandIcon: NSImage {
    let bundled = Bundle.main.url(forResource: "Shaar", withExtension: "icns")
    let preview = URL(filePath: "Resources/Branding/Shaar.icns")
    return NSImage(contentsOf: bundled ?? preview) ?? NSImage()
  }

  @ViewBuilder private var stepContent: some View {
    switch step {
    case .welcome:
      VStack(alignment: .leading, spacing: 16) {
        Text(SettingsL10n.string("A calm place for your tabs, bookmarks, and Spaces."))
        if location.needsInstallation { installationGuidance }
      }
    case .importData:
      Text(
        SettingsL10n.string(
          "Open your Library to import bookmarks and history from another browser. You can do this later, too."
        ))
      Button(SettingsL10n.string("Open Library Import…")) { showImport = true }
    case .defaultBrowser:
      Text(
        SettingsL10n.format(
          "Choose %@ for links opened from other apps. You can change this in macOS Settings anytime.",
          .string(FirstRunBrand.name)))
      if location.needsInstallation {
        Text(
          SettingsL10n.format(
            "Move %@ to Applications before setting it as your default browser.",
            .string(FirstRunBrand.name))
        )
        .foregroundStyle(.secondary)
      } else if defaultStatus {
        Label(
          SettingsL10n.format("%@ is your default browser", .string(FirstRunBrand.name)),
          systemImage: "checkmark.circle.fill")
      } else {
        Button(SettingsL10n.string("Set as Default Browser")) { setDefault() }
      }
      if let defaultError { Text(defaultError).foregroundStyle(.red) }
    case .space:
      Text(
        SettingsL10n.string(
          "Spaces keep different parts of your web in reach. Start with a name you recognize."))
      TextField(SettingsL10n.string("Space name"), text: $spaceName)
        .textFieldStyle(.roundedBorder)
        .accessibilityLabel(SettingsL10n.string("Space name"))
        .accessibilityIdentifier("firstRun.spaceName")
      if let spaceError { Text(spaceError).foregroundStyle(.red) }
    case .keychain:
      Text(
        SettingsL10n.format(
          "%@ uses macOS Keychain to protect saved website passwords. macOS may ask for Keychain access when a saved password is needed. You can manage passwords in Settings later.",
          .string(FirstRunBrand.name)))
    case .ready:
      Text(
        SettingsL10n.string(
          "Your browser is ready. You can revisit import, default browser, and Spaces anytime."))
    }
  }

  private var installationGuidance: some View {
    VStack(alignment: .leading, spacing: 10) {
      Label(
        SettingsL10n.format("Finish installing %@", .string(FirstRunBrand.name)),
        systemImage: "folder"
      )
      .font(.headline)
      Text(
        SettingsL10n.format(
          "Drag %@ to Applications, then open it there. Your setup will resume on the next launch.",
          .string(FirstRunBrand.name))
      )
      .foregroundStyle(.secondary)
      Button(SettingsL10n.string("Show Applications Folder")) {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications", isDirectory: true))
      }
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
  }

  private var footer: some View {
    HStack {
      Button(SettingsL10n.string("Skip Setup"), action: onFinish)
      Spacer()
      Button(SettingsL10n.string("Back")) {
        if let previous = FirstRunStep(rawValue: step.rawValue - 1) { step = previous }
      }
      .disabled(step == .welcome)
      Button(SettingsL10n.string(step == .ready ? "Start Browsing" : "Continue")) {
        advance()
      }
      .keyboardShortcut(.defaultAction)
    }
  }

  private func advance() {
    if step == .ready {
      onFinish()
      return
    }
    if step == .space && !saveSpaceName() { return }
    if let next = FirstRunStep(rawValue: step.rawValue + 1) { step = next }
  }

  private func saveSpaceName() -> Bool {
    let name = spaceName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else { return true }
    let space = store.session.selectedSpace
    if !store.updateSpace(
      space.id, name: name, tint: space.tint, customRGB: space.customRGB, symbol: space.symbol)
    {
      spaceError = SettingsL10n.string("This Space could not be saved. Check its name and Profile.")
      return false
    } else {
      spaceError = nil
      return true
    }
  }

  private func setDefault() {
    Task {
      do {
        try await DefaultBrowserService.makeDefault()
        defaultError = nil
      } catch { defaultError = Self.defaultBrowserFailure() }
      defaultStatus = DefaultBrowserService.isDefault()
    }
  }
}

@MainActor
final class FirstRunSetupWindow: NSObject, NSWindowDelegate {
  let window: NSWindow
  var onClose: (() -> Void)?
  private let marker: URL

  init(store: BrowserStore, marker: URL, location: FirstRunLocation) {
    self.marker = marker
    window = NSWindow(
      contentRect: NSRect(origin: .zero, size: NSSize(width: 760, height: 500)),
      styleMask: [.titled, .closable], backing: .buffered, defer: false)
    super.init()
    window.title = SettingsL10n.format("Welcome to %@", .string(FirstRunBrand.name))
    window.isReleasedWhenClosed = false
    window.contentView = NSHostingView(
      rootView: FirstRunSetupView(store: store, location: location) { [weak self] in
        self?.finish()
      }.settingsLocalization())
    window.delegate = self
  }

  func show() {
    window.center()
    window.makeKeyAndOrderFront(nil)
  }

  private func finish() {
    do {
      try FirstRunState.complete(marker)
      window.close()
    } catch {
      NSSound.beep()
    }
  }

  func windowWillClose(_ notification: Notification) {
    onClose?()
  }
}
