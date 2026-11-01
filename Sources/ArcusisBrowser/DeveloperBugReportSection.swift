// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

struct DeveloperBugReportSection: View {
  let model: SiteControlsDeveloperModel
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Button {
        Task { if await model.createBugReport() != nil { dismiss() } }
      } label: {
        HStack {
          Label("Create Bug Report", systemImage: "ladybug")
          if model.creatingBugReport { ProgressView().controlSize(.small) }
        }
      }
      .disabled(model.creatingBugReport || model.applying)
      Toggle(
        "Include cookie and authorization headers",
        isOn: Binding(
          get: { model.includeSensitiveHeaders }, set: { model.includeSensitiveHeaders = $0 }))
      Text(
        "Saves screenshot, console logs and network timings to Downloads. Nothing is uploaded. Only headers exposed by the page can be included."
      )
      .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      if model.reportURL != nil {
        Label("Saved to Downloads and Library", systemImage: "checkmark.circle").font(.caption)
      }
      if let failure = model.reportFailure {
        Text(failure).font(.caption).foregroundStyle(.red).fixedSize(
          horizontal: false, vertical: true)
      }
    }
  }
}
