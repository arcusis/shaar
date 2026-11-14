// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import CoreGraphics
import AppKit
import ScreenCaptureKit
import SwiftUI

struct DesktopCaptureSource: Identifiable, Equatable {
  enum Kind: Equatable { case display, window, tab }
  let id: String
  let name: String
  let kind: Kind
  var isRequestingTab = false

  static func kind(forToken token: String) -> Kind? {
    let parts = token.split(separator: ":", omittingEmptySubsequences: false)
    guard parts.count == 3, parts[2] == "0" else { return nil }
    switch parts[0] {
    case "tab":
      guard let id = UUID(uuidString: String(parts[1])),
        id.uuidString.caseInsensitiveCompare(String(parts[1])) == .orderedSame
      else { return nil }
      return .tab
    case "window", "screen":
      guard let value = UInt32(parts[1]), value > 0, String(value) == String(parts[1]) else {
        return nil
      }
      return parts[0] == "window" ? .window : .display
    default: return nil
    }
  }

  static func isValidToken(_ token: String) -> Bool { kind(forToken: token) != nil }

  var systemImageName: String {
    switch kind {
    case .display: "display"
    case .window: "macwindow"
    case .tab: "rectangle.on.rectangle"
    }
  }
}

struct DesktopCaptureSettingsButton {
  let title: String
  let action: () -> Void
}

@MainActor
struct DesktopCapturePicker: View {
  let request: DesktopCaptureRequest
  let store: BrowserStore
  private let hasScreenRecordingAccess: () -> Bool
  private let requestScreenRecordingAccess: () -> Bool
  private let shareableContent: () async throws -> SCShareableContent
  private let screenSourcesProvider: (@MainActor () async throws -> [DesktopCaptureSource])?
  private let openSettings: (URL) -> Void
  @State private var sources: [DesktopCaptureSource] = []
  @State private var loading = true
  @State private var error: String?
  @State private var note: String?
  @State private var needsScreenRecordingAccess = false

  init(
    request: DesktopCaptureRequest,
    store: BrowserStore,
    hasScreenRecordingAccess: @escaping () -> Bool = { CGPreflightScreenCaptureAccess() },
    requestScreenRecordingAccess: @escaping () -> Bool = { CGRequestScreenCaptureAccess() },
    shareableContent: @escaping () async throws -> SCShareableContent = {
      try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    },
    screenSourcesProvider: (@MainActor () async throws -> [DesktopCaptureSource])? = nil,
    openSettings: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) }
  ) {
    self.request = request
    self.store = store
    self.hasScreenRecordingAccess = hasScreenRecordingAccess
    self.requestScreenRecordingAccess = requestScreenRecordingAccess
    self.shareableContent = shareableContent
    self.screenSourcesProvider = screenSourcesProvider
    self.openSettings = openSettings
  }

  func settingsButton(for needsAccess: Bool) -> DesktopCaptureSettingsButton? {
    guard needsAccess,
      let url = MacPermission.screenRecording.settingsURL
    else { return nil }
    return DesktopCaptureSettingsButton(
      title: PanelsL10n.string("Open Settings"),
      action: { openSettings(url) })
  }

  var pickerContent: DesktopCapturePickerContent {
    pickerContent(error: error, note: note)
  }

  func pickerContent(error displayedError: String?, note displayedNote: String?)
    -> DesktopCapturePickerContent
  {
    DesktopCapturePickerContent(
      request: request,
      sources: sources,
      loading: loading,
      error: displayedError,
      note: displayedNote,
      onRetry: { await reloadSources() },
      needsScreenRecordingAccess: needsScreenRecordingAccess,
      settingsButton: settingsButton(for: needsScreenRecordingAccess),
      onSelect: { store.resolveDesktopCapture(request.id, sourceID: $0) },
      onCancel: { store.resolveDesktopCapture(request.id, sourceID: nil) }
    )
  }

  var body: some View {
    pickerContent
      .padding(24)
      .frame(width: 480)
      .task { await loadSources() }
      .interactiveDismissDisabled()
  }

  func loadSources() async {
    guard !Task.isCancelled else { return }
    let tabs = DesktopCaptureCatalog.tabSources(
      session: store.session, profileID: request.profileID, requestingTabID: request.tabID
    )
    var screens: [DesktopCaptureSource] = []
    let wantsScreen = request.allows(.display) || request.allows(.window)
    let hasAccess = !wantsScreen || hasScreenRecordingAccess()
    let screenAccessFailed =
      wantsScreen && !hasAccess && !requestScreenRecordingAccess()
    var screenEnumerationFailed = false
    if wantsScreen && !screenAccessFailed {
      do {
        if let screenSourcesProvider {
          screens = try await screenSourcesProvider()
        } else {
          screens = try await screenSources(from: shareableContent())
        }
        guard !Task.isCancelled else { return }
      } catch {
        guard !Task.isCancelled else { return }
        screenEnumerationFailed = true
      }
    }
    guard !Task.isCancelled else { return }
    let listing = DesktopCaptureCatalog.listing(
      tabs: DesktopCaptureCatalog.allowedSources(tabs, for: request),
      screens: DesktopCaptureCatalog.allowedSources(screens, for: request),
      screenAccessFailed: screenAccessFailed,
      screenEnumerationFailed: screenEnumerationFailed)
    needsScreenRecordingAccess = screenAccessFailed
    sources = listing.sources
    store.setDesktopCaptureSources(listing.sources.map(\.id), for: request.id)
    error = listing.error.map(PanelsL10n.string)
    note = listing.note.map(PanelsL10n.string)
    loading = false
  }

  private func reloadSources() async {
    loading = true
    error = nil
    note = nil
    await loadSources()
  }

  private func screenSources(from content: SCShareableContent) -> [DesktopCaptureSource] {
    let windows = content.windows.compactMap { window -> DesktopCaptureSource? in
      guard window.windowID != 0, window.isOnScreen else { return nil }
      let name = DesktopCaptureCatalog.windowName(
        owner: window.owningApplication?.applicationName, title: window.title)
      return DesktopCaptureSource(id: "window:\(window.windowID):0", name: name, kind: .window)
    }
    let displays = content.displays.map { display in
      let name: String
      if display.displayID == CGMainDisplayID() {
        name = PanelsL10n.string("Main Display")
      } else {
        name = PanelsL10n.format("Display %d", .integer(Int(display.displayID)))
      }
      return DesktopCaptureSource(
        id: "screen:\(display.displayID):0", name: name, kind: .display)
    }
    return displays + windows
  }
}

struct DesktopCapturePickerContent: View {
  static let headingTraits: AccessibilityTraits = .isHeader
  let request: DesktopCaptureRequest
  let sources: [DesktopCaptureSource]
  let loading: Bool
  let error: String?
  var note: String? = nil
  var onRetry: () async -> Void = {}
  var needsScreenRecordingAccess = false
  var settingsButton: DesktopCaptureSettingsButton? = nil
  let onSelect: (String) -> Void
  let onCancel: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text(PanelsL10n.string("Choose what to share"))
        .font(.title2.weight(.semibold))
        .accessibilityAddTraits(Self.headingTraits)
      Text(request.displayOrigin)
        .font(.callout).foregroundStyle(.secondary)
        .textSelection(.enabled)
      if let note {
        Text(note).font(.callout).foregroundStyle(.secondary)
      }
      if error != nil || note != nil {
        Button(PanelsL10n.string("Retry")) {
          Task { await onRetry() }
        }
        .accessibilityIdentifier("desktop-capture-retry")
      }
      if needsScreenRecordingAccess, let settingsButton {
        Button(settingsButton.title, action: settingsButton.action)
      }
      if loading {
        ProgressView(PanelsL10n.string("Looking for screens, windows, and tabs…"))
          .frame(maxWidth: .infinity, minHeight: 120)
      } else if let error {
        ContentUnavailableView(error, systemImage: "rectangle.dashed.badge.record")
      } else if sources.isEmpty {
        ContentUnavailableView(
          PanelsL10n.string("No screens, windows, or tabs are available"), systemImage: "display")
      } else {
        List(sources) { source in
          Button {
            onSelect(source.id)
          } label: {
            Label(source.label, systemImage: source.systemImageName)
              .frame(maxWidth: .infinity, alignment: .leading)
              .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
        }
        .listStyle(.inset)
        .frame(minHeight: 150, maxHeight: 330)
      }
      HStack {
        Spacer()
        Button(PanelsL10n.string("Cancel"), role: .cancel) {
          onCancel()
        }
        .keyboardShortcut(.cancelAction)
      }
    }
  }
}

extension DesktopCaptureSource {
  var label: String {
    switch kind {
    case .display:
      return PanelsL10n.format("Screen: %@", .string(name))
    case .window:
      return PanelsL10n.format("Window: %@", .string(name))
    case .tab:
      if isRequestingTab { return PanelsL10n.string("This Tab") }
      return PanelsL10n.format("Tab: %@", .string(name))
    }
  }
}
