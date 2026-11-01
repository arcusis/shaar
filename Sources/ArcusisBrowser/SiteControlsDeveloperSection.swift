// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

struct SiteControlsDeveloperSection: View {
  let model: SiteControlsDeveloperModel

  @State var expanded = false

  var body: some View {
    DisclosureGroup("Developer", isExpanded: $expanded) {
      VStack(alignment: .leading, spacing: 8) {
        choice("Device", \.device, DeveloperSimulation.Device.allCases) {
          switch $0 {
          case .desktop: "Desktop"
          case .phone: "Phone · 390 × 844"
          case .tablet: "Tablet · 820 × 1180"
          }
        }
        choice("Network", \.network, DeveloperSimulation.Network.allCases) {
          switch $0 {
          case .normal: "Normal"
          case .slow3G: "Slow 3G"
          case .offline: "Offline"
          }
        }
        choice("CPU", \.cpu, DeveloperSimulation.CPU.allCases) {
          $0 == .normal ? "Normal" : "\($0.rawValue)× slowdown"
        }
        choice("Location", \.location, DeveloperSimulation.Location.allCases) {
          switch $0 {
          case .actual: "Actual"
          case .sanFrancisco: "San Francisco"
          case .london: "London"
          }
        }
        choice("Timezone", \.timezone, DeveloperSimulation.Timezone.allCases) {
          switch $0 {
          case .system: "System"
          case .newYork: "New York"
          case .tokyo: "Tokyo"
          }
        }
        choice("Language", \.language, DeveloperSimulation.Language.allCases) {
          switch $0 {
          case .system: "System"
          case .english: "English (US)"
          case .french: "French"
          case .hebrew: "Hebrew"
          }
        }
        Toggle("Dark mode", isOn: binding(\.darkMode))
        Toggle("Reduced motion", isOn: binding(\.reducedMotion))
        Text("Saved for this site in this profile. Language changes may require a reload.")
          .font(.caption).foregroundStyle(.secondary)
        Button("Reset Simulations") { model.set(DeveloperSimulation()) }
          .disabled(!model.hasActiveSimulation)
        if model.applying { ProgressView().controlSize(.small) }
        if let failure = model.failure { Text(failure).font(.caption).foregroundStyle(.red) }
      }
      .controlSize(.small)
      .padding(.top, 8)
    }
    .padding(12)
  }

  private func binding<T>(_ key: WritableKeyPath<DeveloperSimulation, T>) -> Binding<T> {
    Binding(
      get: { model.simulation[keyPath: key] },
      set: {
        var value = model.simulation
        value[keyPath: key] = $0
        model.set(value)
      })
  }

  private func choice<T: Hashable>(
    _ title: String, _ key: WritableKeyPath<DeveloperSimulation, T>,
    _ values: [T], label: @escaping (T) -> String
  ) -> some View {
    Picker(title, selection: binding(key)) {
      ForEach(values, id: \.self) { Text(label($0)).tag($0) }
    }
  }
}

struct DeveloperSimulationBadge: View {
  let model: SiteControlsDeveloperModel
  var body: some View {
    if model.hasActiveSimulation {
      Button {
        model.set(DeveloperSimulation())
      } label: {
        Label("Simulation", systemImage: "testtube.2").font(.caption)
      }
      .help("Reset all active simulations for this site")
      .accessibilityLabel("Reset active simulations")
    }
  }
}
