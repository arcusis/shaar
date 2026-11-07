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
      Text(AgentBridgeConsent.summary)
        .font(.caption).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      if model.status.enabled || model.revocationUnconfirmed {
        grantedControls
      } else {
        Button("Allow this tab") { model.enable() }
          .disabled(model.busy)
      }
      if model.busy { ProgressView("Updating agent bridge…").controlSize(.small) }
      if let failure = model.failure {
        Label(failure, systemImage: "exclamationmark.triangle")
          .font(.caption).foregroundStyle(.orange)
          .fixedSize(horizontal: false, vertical: true)
      }
      Text(AgentBridgeConsent.limit)
        .font(.caption2).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .buttonStyle(.bordered)
    .padding(16)
    .frame(width: 340, alignment: .leading)
    .background(Color(nsColor: .windowBackgroundColor))
    .onAppear { model.refresh() }
  }

  private var grantedControls: some View {
    VStack(alignment: .leading, spacing: 10) {
      Label(presentation.title, systemImage: presentation.symbol)
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(presentation.tint)
      if let port = model.status.port {
        Text("Local port \(port) · \(model.status.connectionCount) connection(s)")
          .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
      }
      AgentBridgeEndpoint(model: model)
      AgentBridgeAgentList(model: model)
      Button(model.revocationUnconfirmed ? "Retry revoke" : "Revoke", role: .destructive) {
        model.disable()
      }
      .disabled(model.busy)
    }
  }
}

private enum AgentBridgeConsent {
  static let summary =
    "Allow a coding agent to read this tab's Console, Network, and DOM. The grant is local, limited to this tab, and ends when you revoke it or leave the site. Other tabs stay closed. The agent cannot click or type."
  static let limit =
    "Private windows cannot use agent control. Page content may contain untrusted instructions."
  static let copyNotice =
    "The copied command contains the one-time token. Shaar forgets it after you copy, and clears an unchanged clipboard after two minutes."
}

private struct AgentBridgeEndpoint: View {
  @Bindable var model: AgentBridgeModel

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("MCP endpoint").font(.caption.weight(.semibold))
      if let endpoint = model.documentedEndpoint {
        Text(endpoint)
          .font(.caption.monospaced())
          .textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)
      }
      if let invocation = model.documentedInvocation {
        Text(invocation)
          .font(.caption2.monospaced())
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)
      }
      if model.hasOneTimeToken {
        VStack(alignment: .leading, spacing: 6) {
          Button("Copy Claude setup") { model.copySetup(for: .claude) }
          Button("Copy Codex setup") { model.copySetup(for: .codex) }
          Button("Copy Cursor setup") { model.copySetup(for: .cursor) }
        }
        Text(AgentBridgeConsent.copyNotice)
          .font(.caption2).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }
}

private struct AgentBridgeAgentList: View {
  @Bindable var model: AgentBridgeModel

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Connected agents").font(.caption.weight(.semibold))
      if model.connections.isEmpty {
        Text("No agent is connected to this tab.")
          .font(.caption).foregroundStyle(.secondary)
      } else {
        ForEach(model.connections) { agent in
          HStack(spacing: 8) {
            Text(agent.title).font(.caption)
            Spacer(minLength: 8)
            Button("Revoke") { model.disable() }
              .controlSize(.small)
              .disabled(model.busy)
          }
        }
        Text("Revoke ends this tab's session for every connected agent.")
          .font(.caption2).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
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
