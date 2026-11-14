// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

struct PrintConsentSheet: View {
  let request: PrintRequest
  let store: BrowserStore

  var body: some View {
    PrintConsentContent(
      request: request,
      onCancel: cancel,
      onPrint: continueToPrint
    )
  }

  func cancel() {
    store.resolvePrint(request.id, accepted: false)
  }

  func continueToPrint() {
    store.resolvePrint(request.id, accepted: true)
  }
}

struct PrintConsentContent: View {
  static let headingTraits: AccessibilityTraits = .isHeader
  let request: PrintRequest
  let onCancel: () -> Void
  let onPrint: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(PanelsL10n.string("Print this page?"))
        .font(.title2.weight(.semibold))
        .accessibilityAddTraits(Self.headingTraits)
      Text(request.hostLabel)
        .font(.callout)
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
      if !request.title.isEmpty {
        Text(request.title)
          .font(.headline)
          .textSelection(.enabled)
      }
      Text(request.pageURL.absoluteString)
        .font(.callout)
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
        .lineLimit(2)
      HStack {
        Spacer()
        Button(PanelsL10n.string("Cancel"), role: .cancel, action: onCancel)
          .keyboardShortcut(.cancelAction)
        Button(PanelsL10n.string("Continue to Print"), action: onPrint)
          .keyboardShortcut(.defaultAction)
          .buttonStyle(.borderedProminent)
      }
    }
    .padding(24)
    .frame(width: 440)
  }
}
