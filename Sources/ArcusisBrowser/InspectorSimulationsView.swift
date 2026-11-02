// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

struct InspectorSimulationsView: View {
  @Bindable var model: DeveloperPageModel

  var body: some View {
    InspectorSection(InspectorToolsL10n.string("Environment")) {
      VStack(alignment: .leading, spacing: 12) {
        row(
          InspectorToolsL10n.string("Viewport"), path: \.device,
          choices: DeveloperSimulation.Device.allCases
        ) {
          switch $0 {
          case .desktop: InspectorToolsL10n.string("Desktop")
          case .phone: InspectorToolsL10n.string("Phone · 390 × 844")
          case .tablet: InspectorToolsL10n.string("Tablet · 820 × 1180")
          }
        }
        row(
          InspectorToolsL10n.string("Network"), path: \.network,
          choices: DeveloperSimulation.Network.allCases
        ) {
          switch $0 {
          case .normal: InspectorToolsL10n.string("Normal")
          case .slow3G: InspectorToolsL10n.string("Slow 3G")
          case .offline: InspectorToolsL10n.string("Offline")
          }
        }
        row("CPU", path: \.cpu, choices: DeveloperSimulation.CPU.allCases) {
          $0 == .normal
            ? InspectorToolsL10n.string("Normal")
            : InspectorToolsL10n.format(
              "%d× slower", arguments: [.integer($0.rawValue)])
        }
        Divider()
        Toggle(InspectorToolsL10n.string("Dark appearance"), isOn: binding(\.darkMode))
        Toggle(InspectorToolsL10n.string("Reduced motion"), isOn: binding(\.reducedMotion))
        Divider()
        row(
          InspectorToolsL10n.string("Location"), path: \.location,
          choices: DeveloperSimulation.Location.allCases
        ) {
          switch $0 {
          case .actual: InspectorToolsL10n.string("Actual")
          case .sanFrancisco: InspectorToolsL10n.string("San Francisco")
          case .london: InspectorToolsL10n.string("London")
          }
        }
        row(
          InspectorToolsL10n.string("Timezone"), path: \.timezone,
          choices: DeveloperSimulation.Timezone.allCases
        ) {
          switch $0 {
          case .system: InspectorToolsL10n.string("System")
          case .newYork: InspectorToolsL10n.string("New York")
          case .tokyo: InspectorToolsL10n.string("Tokyo")
          }
        }
        row(
          InspectorToolsL10n.string("Language"), path: \.language,
          choices: DeveloperSimulation.Language.allCases
        ) {
          switch $0 {
          case .system: InspectorToolsL10n.string("System")
          case .english: InspectorToolsL10n.string("English")
          case .french: InspectorToolsL10n.string("French")
          case .hebrew: InspectorToolsL10n.string("Hebrew")
          }
        }
        Text(
          InspectorToolsL10n.string(
            "Saved for this site and profile. Location still requires site permission. Reload may be needed for page code that cached language or media values."
          )
        )
        .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(
          horizontal: false, vertical: true)
        HStack {
          if model.applying {
            ProgressView().controlSize(.mini)
            Text(InspectorToolsL10n.string("Applying…")).foregroundStyle(.secondary)
          }
          Spacer()
          Button(InspectorToolsL10n.string("Reset all")) { model.set(DeveloperSimulation()) }
            .disabled(
              !model.hasActiveSimulation)
        }
        if let failure = model.failure { Text(failure).foregroundStyle(.secondary) }
      }.font(.system(size: 11)).controlSize(.small).toggleStyle(.switch)
    }
  }

  private func binding<Value>(_ path: WritableKeyPath<DeveloperSimulation, Value>) -> Binding<Value>
  {
    Binding(
      get: { model.simulation[keyPath: path] },
      set: { value in
        var next = model.simulation
        next[keyPath: path] = value
        model.set(next)
      })
  }

  private func row<Value: Hashable>(
    _ label: String, path: WritableKeyPath<DeveloperSimulation, Value>, choices: [Value],
    title: @escaping (Value) -> String
  ) -> some View {
    HStack {
      Text(label).foregroundStyle(.secondary).frame(width: 66, alignment: .leading)
      Picker(label, selection: binding(path)) {
        ForEach(choices, id: \.self) { Text(title($0)).tag($0) }
      }.labelsHidden().frame(maxWidth: .infinity)
    }
  }
}

struct DeveloperSimulationBadge: View {
  let engine: BrowserEngine
  var body: some View {
    if let target = engine.siteControlTarget, let model = engine.developerModels[target.tabID],
      model.hasActiveSimulation
    {
      Button {
        model.set(DeveloperSimulation())
      } label: {
        Image(systemName: "slider.horizontal.3").font(.system(size: 12, weight: .semibold))
          .foregroundStyle(Color.accentColor).frame(width: 28, height: 28)
          .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 5))
      }.buttonStyle(.plain).help(InspectorToolsL10n.string("Simulations active — reset all"))
        .accessibilityLabel(InspectorToolsL10n.string("Reset active simulations"))
    }
  }
}
