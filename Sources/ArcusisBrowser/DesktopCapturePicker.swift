// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import CoreGraphics
import ScreenCaptureKit
import SwiftUI

struct DesktopCaptureSource: Identifiable, Equatable {
  enum Kind: Equatable { case display, window, tab }
  let id: String
  let name: String
  let kind: Kind
  var isRequestingTab = false

  var systemImageName: String {
    switch kind {
    case .display: "display"
    case .window: "macwindow"
    case .tab: "rectangle.on.rectangle"
    }
  }
}

@MainActor
struct DesktopCapturePicker: View {
  let request: DesktopCaptureRequest
  let store: BrowserStore
  private let hasScreenRecordingAccess: () -> Bool
  private let shareableContent: () async throws -> SCShareableContent
  @State private var sources: [DesktopCaptureSource] = []
  @State private var loading = true
  @State private var error: String?
  @State private var note: String?

  init(
    request: DesktopCaptureRequest,
    store: BrowserStore,
    hasScreenRecordingAccess: @escaping () -> Bool = { CGPreflightScreenCaptureAccess() },
    shareableContent: @escaping () async throws -> SCShareableContent = {
      try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    }
  ) {
    self.request = request
    self.store = store
    self.hasScreenRecordingAccess = hasScreenRecordingAccess
    self.shareableContent = shareableContent
  }

  var body: some View {
    DesktopCapturePickerContent(
      request: request,
      sources: sources,
      loading: loading,
      error: error,
      note: note,
      onSelect: { store.resolveDesktopCapture(request.id, sourceID: $0) },
      onCancel: { store.resolveDesktopCapture(request.id, sourceID: nil) }
    )
    .padding(24)
    .frame(width: 480)
    .task { await loadSources() }
    .interactiveDismissDisabled()
  }

  func loadSources() async {
    let tabs = DesktopCaptureCatalog.tabSources(
      session: store.session, profileID: request.profileID, requestingTabID: request.tabID
    ).filter { request.allows($0.kind) }
    var screens: [DesktopCaptureSource] = []
    let wantsScreen = request.allows(.display) || request.allows(.window)
    var screenAccessFailed = wantsScreen && !hasScreenRecordingAccess()
    if wantsScreen && !screenAccessFailed {
      do {
        screens = try await screenSources(from: shareableContent())
        screens = screens.filter { request.allows($0.kind) }
      } catch {
        screenAccessFailed = true
      }
    }
    let listing = DesktopCaptureCatalog.listing(
      tabs: tabs, screens: screens, screenAccessFailed: screenAccessFailed)
    sources = listing.sources
    error = listing.error.map(PanelsL10n.string)
    note = listing.note.map(PanelsL10n.string)
    loading = false
  }

  private func screenSources(from content: SCShareableContent) -> [DesktopCaptureSource] {
    let windows = content.windows.compactMap { window -> DesktopCaptureSource? in
      guard window.windowID != 0, window.isOnScreen else { return nil }
      let owner = window.owningApplication?.applicationName ?? PanelsL10n.string("Window")
      let title = window.title?.trimmingCharacters(in: .whitespacesAndNewlines)
      let name: String
      if let title, !title.isEmpty {
        name = "\(owner) — \(title)"
      } else {
        name = owner
      }
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
  let request: DesktopCaptureRequest
  let sources: [DesktopCaptureSource]
  let loading: Bool
  let error: String?
  var note: String? = nil
  let onSelect: (String) -> Void
  let onCancel: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text(PanelsL10n.string("Choose what to share"))
        .font(.title2.weight(.semibold))
      Text(
        request.requestingOrigin.host() ?? request.pageURL.host()
          ?? request.pageURL.absoluteString
      )
      .font(.callout).foregroundStyle(.secondary)
      .textSelection(.enabled)
      if let note {
        Text(note).font(.callout).foregroundStyle(.secondary)
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
