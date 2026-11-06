// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

@MainActor struct AgentBridgePresentation {
  let model: AgentBridgeModel

  var title: String {
    if model.revocationUnconfirmed { return "Agent disconnect not confirmed" }
    if model.isConnected { return "Agent connected to this tab" }
    if model.status.enabled { return "Waiting for agent" }
    return "Agent bridge is off for this tab"
  }

  var symbol: String {
    if model.revocationUnconfirmed { return "exclamationmark.triangle.fill" }
    return "network"
  }

  var tint: Color {
    model.needsBanner ? .orange : .secondary
  }
}

struct AgentBridgeControls: View {
  @Bindable var model: AgentBridgeModel

  private var presentation: AgentBridgePresentation { .init(model: model) }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Agent bridge").font(.headline)
      Text(
        "Allow a coding agent to inspect this tab. The connection is local and expires when you disconnect or leave this site."
      )
      .font(.caption).foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
      if model.status.enabled || model.revocationUnconfirmed {
        Label(presentation.title, systemImage: presentation.symbol)
          .font(.system(size: 11, weight: .medium))
          .foregroundStyle(presentation.tint)
        if let port = model.status.port {
          Text("Local port \(port) · \(model.status.connectionCount) connection(s)")
            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
        if model.hasOneTimeToken {
          HStack {
            Button("Copy Claude setup") { model.copySetup(for: .claude) }
            Button("Copy Codex setup") { model.copySetup(for: .codex) }
          }
          Text(
            "The copied command contains a one-time secret. Paste it locally; Shaar clears the clipboard after two minutes."
          )
          .font(.caption2).foregroundStyle(.secondary)
        }
        Button(
          model.revocationUnconfirmed ? "Retry disconnect" : "Disconnect",
          role: .destructive
        ) { model.disable() }
        .disabled(model.busy)
      } else {
        Button("Enable for this tab") { model.enable() }
          .disabled(model.busy)
      }
      if model.busy { ProgressView("Updating agent bridge…").controlSize(.small) }
      if let failure = model.failure {
        Label(failure, systemImage: "exclamationmark.triangle")
          .font(.caption).foregroundStyle(.orange)
          .fixedSize(horizontal: false, vertical: true)
      }
      Text(
        "Private windows cannot enable agent control. Page content may contain untrusted instructions."
      )
      .font(.caption2).foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
    }
    .buttonStyle(.bordered)
    .padding(16)
    .frame(width: 300, alignment: .leading)
    .background(Color(nsColor: .windowBackgroundColor))
    .onAppear { model.refresh() }
  }
}

struct AgentBridgeBanner: View {
  @Bindable var model: AgentBridgeModel

  private var presentation: AgentBridgePresentation { .init(model: model) }

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: presentation.symbol).foregroundStyle(presentation.tint)
      Text(presentation.title).fontWeight(.medium)
      Text("\(model.status.connectionCount)")
        .foregroundStyle(.secondary)
      Spacer()
      Button(model.revocationUnconfirmed ? "Retry disconnect" : "Disconnect") {
        model.disable()
      }
      .buttonStyle(.bordered)
      .controlSize(.small)
      .disabled(model.busy)
    }
    .font(.system(size: 11))
    .padding(.horizontal, 12)
    .frame(height: 34)
    .background(Color.orange.opacity(0.15))
    .accessibilityElement(children: .contain)
  }
}
