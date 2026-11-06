// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AVKit
import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ShaarReproPanel: View {
  @Bindable var model: ShaarReproModel
  let directory: URL?
  let onSaved: (URL) -> Void
  @State private var importing = false
  @State private var viewerTab = ViewerTab.console

  private enum ViewerTab: String, CaseIterable {
    case video = "Video"
    case console = "Console"
    case network = "Network"
    case dom = "DOM"
    case environment = "Environment"
  }

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
        if let contents = model.viewerContents {
          Picker(ShellL10n.string("Bundle viewer"), selection: $viewerTab) {
            ForEach(ViewerTab.allCases, id: \.self) { tab in
              Text(ShellL10n.string(tab.rawValue)).tag(tab)
            }
          }
          .labelsHidden().pickerStyle(.segmented).controlSize(.small)
          viewer(contents).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
          Spacer(minLength: 4)
        }
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

  @ViewBuilder private func viewer(_ contents: ShaarReproContents) -> some View {
    switch viewerTab {
    case .video:
      if let videoURL = model.videoURL {
        VideoPlayer(player: AVPlayer(url: videoURL))
          .accessibilityIdentifier("shaar.devtools.reproVideo")
      }
    case .console:
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 0) {
          ForEach(contents.console.indices, id: \.self) { index in
            let row = contents.console[index]
            HStack(alignment: .top, spacing: 8) {
              Text(row.level.uppercased()).frame(width: 60, alignment: .leading)
                .foregroundStyle(.secondary)
              Text(row.message).frame(maxWidth: .infinity, alignment: .leading)
              Text(row.source).foregroundStyle(.secondary)
            }
            .font(.system(size: 10, design: .monospaced))
            .padding(.vertical, 6)
            Divider()
          }
        }
      }
      .accessibilityIdentifier("shaar.devtools.reproConsole")
    case .network:
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 0) {
          ForEach(contents.network.indices, id: \.self) { index in
            let row = contents.network[index]
            HStack(spacing: 8) {
              Text(row.request.method).frame(width: 48, alignment: .leading)
              Text(row.request.url).lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
              Text(String(row.response.status))
            }
            .font(.system(size: 10, design: .monospaced))
            .padding(.vertical, 6)
            Divider()
          }
        }
      }
      .accessibilityIdentifier("shaar.devtools.reproNetwork")
    case .dom:
      ScrollView {
        Text(Self.domText(contents.dom))
          .font(.system(size: 10, design: .monospaced))
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .accessibilityIdentifier("shaar.devtools.reproDOM")
    case .environment:
      ScrollView {
        VStack(alignment: .leading, spacing: 8) {
          environmentRow("URL", contents.manifest.environment.url)
          environmentRow("Shaar", contents.manifest.environment.shaarVersion)
          environmentRow("Engine", contents.manifest.environment.engineVersion)
          environmentRow("OS", contents.manifest.environment.operatingSystem)
          environmentRow(
            "Viewport",
            "\(contents.manifest.environment.viewportWidth) × \(contents.manifest.environment.viewportHeight)"
          )
          environmentRow("User agent", contents.manifest.environment.userAgent)
        }
      }
      .accessibilityIdentifier("shaar.devtools.reproEnvironment")
    }
  }

  private func environmentRow(_ name: String, _ value: String) -> some View {
    HStack(alignment: .top, spacing: 8) {
      Text(ShellL10n.string(name)).foregroundStyle(.secondary)
        .frame(width: 75, alignment: .leading)
      Text(value).textSelection(.enabled)
    }.font(.system(size: 10, design: .monospaced))
  }

  private static func domText(_ root: ShaarReproDOMNode) -> String {
    var lines: [String] = []
    func append(_ node: ShaarReproDOMNode, depth: Int) {
      guard lines.count < 2_000 else { return }
      let indent = String(repeating: "  ", count: min(depth, 32))
      lines.append(indent + "<" + node.tag + "> " + node.text)
      for child in node.children { append(child, depth: depth + 1) }
    }
    append(root, depth: 0)
    return lines.joined(separator: "\n")
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
