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
    .onDisappear { anchor.cancel() }
  }

  /// Shows the system picker only for a visible window. A hidden window cancels.
  @MainActor
  static func finish(_ request: WebShareRequest, store: BrowserStore, anchor: WebShareAnchor) {
    guard anchor.presentationGate.begin() else { return }
    guard store.canPresentWebShare(request) else {
      anchor.presentationGate.finish()
      store.resolveWebShare(request.id, outcome: .cancelled)
      return
    }
    guard let view = anchor.view, view.window?.isVisible == true else {
      anchor.presentationGate.finish()
      store.resolveWebShare(request.id, outcome: .cancelled)
      return
    }
    let picker = WebShareSystemPicker(items: request.sharingItems)
    picker.outcome.onFinish = { shared in
      anchor.presentationGate.finish()
      let outcome: WebShareOutcome = shared ? .shared : .cancelled
      store.resolveWebShare(request.id, outcome: outcome)
    }
    anchor.picker = picker
    picker.show(from: view)
  }
}

struct WebShareSheetContent: View {
  static let headingTraits: AccessibilityTraits = .isHeader
  let request: WebShareRequest
  let onCancel: () -> Void
  let onShare: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(PanelsL10n.string("Share"))
        .font(.title2.weight(.semibold))
        .accessibilityAddTraits(Self.headingTraits)
      Text(request.originLabel)
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
  let presentationGate = WebSharePresentationGate()

  func cancel() {
    picker?.close()
    picker = nil
    presentationGate.finish()
  }
}

@MainActor
final class WebSharePresentationGate {
  private(set) var isActive = false

  func begin() -> Bool {
    guard !isActive else { return false }
    isActive = true
    return true
  }

  func finish() {
    isActive = false
  }
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
  private(set) var isClosed = false

  init(items: [Any]) {
    picker = NSSharingServicePicker(items: items)
    super.init()
  }

  func show(from view: NSView) {
    picker.delegate = self
    picker.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
  }

  func close() {
    guard !isClosed else { return }
    isClosed = true
    picker.close()
    outcome.finish(false)
  }

  func sharingServicePicker(
    _ sharingServicePicker: NSSharingServicePicker, didChoose service: NSSharingService?
  ) {
    outcome.chooseService(available: service != nil)
  }

  func sharingServicePicker(
    _ sharingServicePicker: NSSharingServicePicker, delegateFor service: NSSharingService
  ) -> NSSharingServiceDelegate? {
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
