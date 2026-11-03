// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import CoreGraphics
import ScreenCaptureKit
import SwiftUI

struct DesktopCaptureSource: Identifiable {
  enum Kind: Equatable { case display, window }
  let id: String
  let name: String
  let kind: Kind
}

@MainActor
struct DesktopCapturePicker: View {
  let request: DesktopCaptureRequest
  let store: BrowserStore
  @State private var sources: [DesktopCaptureSource] = []
  @State private var loading = true
  @State private var error: String?

  var body: some View {
    DesktopCapturePickerContent(
      request: request,
      sources: sources,
      loading: loading,
      error: error,
      onSelect: { store.resolveDesktopCapture(request.id, sourceID: $0) },
      onCancel: { store.resolveDesktopCapture(request.id, sourceID: nil) }
    )
    .padding(24)
    .frame(width: 480)
    .task { await loadSources() }
    .interactiveDismissDisabled()
  }

  private func loadSources() async {
    if !CGPreflightScreenCaptureAccess(), !CGRequestScreenCaptureAccess() {
      error = PanelsL10n.string(
        "Screen Recording access is unavailable. Check Privacy & Security settings.")
      loading = false
      return
    }
    do {
      let content = try await SCShareableContent.excludingDesktopWindows(
        false, onScreenWindowsOnly: true)
      let windows = content.windows.compactMap { window -> DesktopCaptureSource? in
        guard window.windowID != 0, window.isOnScreen
        else { return nil }
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
      sources =
        content.displays.map { display in
          let name: String
          if display.displayID == CGMainDisplayID() {
            name = PanelsL10n.string("Main Display")
          } else {
            name = PanelsL10n.format("Display %d", .integer(Int(display.displayID)))
          }
          return DesktopCaptureSource(
            id: "screen:\(display.displayID):0", name: name, kind: .display)
        } + windows
    } catch {
      self.error = PanelsL10n.string(
        "Screen Recording access is unavailable. Check Privacy & Security settings.")
    }
    loading = false
  }
}

struct DesktopCapturePickerContent: View {
  let request: DesktopCaptureRequest
  let sources: [DesktopCaptureSource]
  let loading: Bool
  let error: String?
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
      if loading {
        ProgressView(PanelsL10n.string("Looking for screens and windows…"))
          .frame(maxWidth: .infinity, minHeight: 120)
      } else if let error {
        ContentUnavailableView(error, systemImage: "rectangle.dashed.badge.record")
      } else if sources.isEmpty {
        ContentUnavailableView(
          PanelsL10n.string("No screens or windows are available"), systemImage: "display")
      } else {
        List(sources) { source in
          Button {
            onSelect(source.id)
          } label: {
            Label(source.label, systemImage: source.kind == .display ? "display" : "macwindow")
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
    case .display: PanelsL10n.format("Screen: %@", .string(name))
    case .window: PanelsL10n.format("Window: %@", .string(name))
    }
  }
}
