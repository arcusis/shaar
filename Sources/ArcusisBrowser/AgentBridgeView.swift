// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

struct AgentBridgeControls: View {
  @Bindable var model: AgentBridgeModel

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Agent bridge").font(.headline)
      Text(
        "Allow a coding agent to inspect this tab. The connection is local and expires when you disconnect or leave this site."
      )
      .font(.caption).foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
      if model.status.enabled || model.revocationUnconfirmed {
        Label(statusTitle, systemImage: model.isConnected ? "circle.fill" : "circle.dotted")
          .foregroundStyle(model.isConnected ? .orange : .secondary)
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
      if model.busy { ProgressView().controlSize(.small) }
      if let failure = model.failure {
        Text(failure).font(.caption).foregroundStyle(.secondary)
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

  private var statusTitle: String {
    if model.revocationUnconfirmed { return "Disconnect not confirmed" }
    if model.isConnected { return "Agent connected" }
    return "Waiting for agent"
  }
}

struct AgentBridgeBanner: View {
  @Bindable var model: AgentBridgeModel

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: "network")
      Text(
        model.revocationUnconfirmed
          ? "Agent disconnect not confirmed" : "Agent connected to this tab"
      )
      .fontWeight(.medium)
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
