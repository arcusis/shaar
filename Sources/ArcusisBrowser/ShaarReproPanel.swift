// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ShaarReproPanel: View {
  @Bindable var model: ShaarReproModel
  let directory: URL?
  let onSaved: (URL) -> Void
  @State private var importing = false

  var body: some View {
    HStack(spacing: 0) {
      VStack(alignment: .leading, spacing: 13) {
        Text(ShellL10n.string("REPRO BUNDLE"))
          .font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
        Text(ShellL10n.string("Capture the last 30 seconds"))
          .font(.system(size: 16, weight: .semibold))
        Text(
          ShellL10n.string(
            "Page video, console, network, DOM and environment in one local file.")
        )
        .font(.system(size: 12)).foregroundStyle(.secondary)
        capability
        HStack(spacing: 12) {
          Button {
            guard let directory else { return }
            Task {
              if let file = await model.capture(to: directory) { onSaved(file) }
            }
          } label: {
            if model.busy { ProgressView().controlSize(.mini) }
            Text(ShellL10n.string("Create .shaarrepro"))
          }
          .disabled(!model.available || model.busy || directory == nil)
          Button(ShellL10n.string("Open bundle…")) { importing = true }
        }
        .controlSize(.small)
        if let failure = model.failure {
          Text(failure).font(.system(size: 11)).foregroundStyle(.red)
        }
        Spacer(minLength: 4)
        Text(
          ShellL10n.string(
            "Cookies, auth headers and DOM form values are redacted. Video and console may show sensitive text. No upload."
          )
        )
        .font(.system(size: 10)).foregroundStyle(.secondary)
      }
      .padding(20).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      Divider()
      contents.frame(width: 270).frame(maxHeight: .infinity, alignment: .topLeading)
    }
    .fileImporter(
      isPresented: $importing,
      allowedContentTypes: [UTType(filenameExtension: "shaarrepro", conformingTo: .data) ?? .data]
    ) { result in
      guard case .success(let url) = result else { return }
      let access = url.startAccessingSecurityScopedResource()
      Task {
        await model.open(url)
        if access { url.stopAccessingSecurityScopedResource() }
      }
    }
    .accessibilityIdentifier("shaar.devtools.reproPanel")
  }

  private var capability: some View {
    HStack(spacing: 10) {
      Image(systemName: model.available ? "record.circle" : "record.circle.slash")
        .foregroundStyle(model.available ? Color.red : Color.secondary)
      Text(
        ShellL10n.string(
          model.available ? "Recording this tab" : "Recording needs engine support"))
      Spacer()
      Text("30 s").foregroundStyle(.secondary)
    }
    .font(.system(size: 11)).padding(10)
    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
  }

  private var contents: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(ShellL10n.string("BUNDLE CONTENTS"))
        .font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
      if let manifest = model.viewerManifest {
        row("Page video", "\(manifest.durationSeconds) s")
        row("Console", "\(manifest.consoleCount) entries")
        row("Network", "\(manifest.networkCount) requests")
        row("DOM", "1 snapshot")
        row("Environment", manifest.environment.operatingSystem)
        Divider()
        Button(ShellL10n.string("Copy for agent")) {
          copySummary(manifest)
        }.buttonStyle(.link).font(.system(size: 11))
        if let url = model.savedURL {
          Text(url.lastPathComponent).font(.system(size: 10))
            .foregroundStyle(.secondary).lineLimit(2)
        }
      } else {
        Text(ShellL10n.string("Open a local bundle to inspect its summary."))
          .font(.system(size: 11)).foregroundStyle(.secondary)
      }
      Spacer()
    }
    .padding(20)
  }

  private func row(_ label: String, _ value: String) -> some View {
    HStack {
      Text(ShellL10n.string(label))
      Spacer()
      Text(value).foregroundStyle(.secondary)
    }.font(.system(size: 11, design: .monospaced))
  }

  private func copySummary(_ manifest: ShaarReproManifest) {
    let summary = """
      Shaar repro bundle: \(model.savedURL?.lastPathComponent ?? "")
      URL: \(manifest.environment.url)
      Duration: \(manifest.durationSeconds) seconds
      Console: \(manifest.consoleCount) entries
      Network: \(manifest.networkCount) requests
      """
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(summary, forType: .string)
  }
}
