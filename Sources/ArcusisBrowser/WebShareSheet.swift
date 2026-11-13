// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import SwiftUI

struct WebShareSheet: View {
  let request: WebShareRequest
  let store: BrowserStore
  @State private var anchor = WebShareAnchor()

  var body: some View {
    WebShareSheetContent(
      request: request,
      onCancel: { store.resolveWebShare(request.id, outcome: .cancelled) },
      onShare: { WebShareSheet.finish(request, store: store, anchor: anchor) }
    )
    .background {
      WebShareAnchorView(anchor: anchor)
    }
  }

  /// Shows the system picker only for a visible window. A hidden window cancels.
  @MainActor
  static func finish(_ request: WebShareRequest, store: BrowserStore, anchor: WebShareAnchor) {
    guard let view = anchor.view, view.window?.isVisible == true else {
      store.resolveWebShare(request.id, outcome: .cancelled)
      return
    }
    let picker = WebShareSystemPicker(items: request.sharingItems)
    picker.outcome.onFinish = { shared in
      let outcome: WebShareOutcome = shared ? .shared : .cancelled
      store.resolveWebShare(request.id, outcome: outcome)
    }
    anchor.picker = picker
    picker.show(from: view)
  }
}

struct WebShareSheetContent: View {
  let request: WebShareRequest
  let onCancel: () -> Void
  let onShare: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(PanelsL10n.string("Share"))
        .font(.title2.weight(.semibold))
      Text(request.hostLabel)
        .font(.callout)
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
      if !request.title.isEmpty {
        Text(request.title)
          .font(.headline)
          .textSelection(.enabled)
      }
      if !request.text.isEmpty {
        Text(request.text)
          .font(.body)
          .textSelection(.enabled)
      }
      if let url = request.url {
        Text(url.absoluteString)
          .font(.callout)
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
          .lineLimit(2)
      }
      HStack {
        Spacer()
        Button(PanelsL10n.string("Cancel"), role: .cancel, action: onCancel)
          .keyboardShortcut(.cancelAction)
        Button(PanelsL10n.string("Share"), action: onShare)
          .keyboardShortcut(.defaultAction)
          .buttonStyle(.borderedProminent)
      }
    }
    .padding(24)
    .frame(width: 440)
    .background(Color(nsColor: .windowBackgroundColor))
  }
}

@MainActor
final class WebShareAnchor {
  weak var view: NSView?
  var picker: WebShareSystemPicker?
}

struct WebShareAnchorView: NSViewRepresentable {
  let anchor: WebShareAnchor

  func makeNSView(context: Context) -> NSView {
    let view = NSView()
    anchor.view = view
    return view
  }

  func updateNSView(_ nsView: NSView, context: Context) {
    anchor.view = nsView
  }
}

@MainActor
final class WebShareSystemPicker: NSObject, @MainActor NSSharingServicePickerDelegate,
  NSSharingServiceDelegate
{
  let picker: NSSharingServicePicker
  let outcome = WebShareOutcomeGate()

  init(items: [Any]) {
    picker = NSSharingServicePicker(items: items)
    super.init()
  }

  func show(from view: NSView) {
    picker.delegate = self
    picker.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
  }

  func sharingServicePicker(
    _ sharingServicePicker: NSSharingServicePicker, didChoose service: NSSharingService?
  ) {
    outcome.chooseService(available: service != nil)
  }

  func sharingServicePicker(
    _ sharingServicePicker: NSSharingServicePicker, delegateFor service: NSSharingService
  ) -> (any NSSharingServiceDelegate)? {
    self
  }

  func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {
    outcome.finish(true)
  }

  func sharingService(
    _ sharingService: NSSharingService, didFailToShareItems items: [Any], error: Error
  ) {
    outcome.finish(false)
  }
}

@MainActor
final class WebShareOutcomeGate {
  var onFinish: ((Bool) -> Void)?
  private var isFinished = false

  func chooseService(available: Bool) {
    if !available { finish(false) }
  }

  func finish(_ shared: Bool) {
    guard !isFinished else { return }
    isFinished = true
    onFinish?(shared)
    onFinish = nil
  }
}
