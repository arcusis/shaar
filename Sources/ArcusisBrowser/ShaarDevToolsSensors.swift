// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

enum ShaarDevToolsSensorLocation: String, CaseIterable, Equatable, Sendable {
  case system
  case sanFrancisco
  case london
  case custom
}

enum ShaarDevToolsSensorTimezone: String, CaseIterable, Equatable, Sendable {
  case system
  case newYork
  case tokyo

  var identifier: String {
    switch self {
    case .system: ""
    case .newYork: "America/New_York"
    case .tokyo: "Asia/Tokyo"
    }
  }

  var title: String {
    switch self {
    case .system: "System"
    case .newYork: "New York"
    case .tokyo: "Tokyo"
    }
  }
}

enum ShaarDevToolsSensorLocale: String, CaseIterable, Equatable, Sendable {
  case system
  case english
  case french
  case hebrew

  var identifier: String {
    switch self {
    case .system: ""
    case .english: "en-US"
    case .french: "fr-FR"
    case .hebrew: "he-IL"
    }
  }

  var title: String {
    switch self {
    case .system: "System"
    case .english: "English"
    case .french: "French"
    case .hebrew: "Hebrew"
    }
  }
}

enum ShaarDevToolsSensorNotice: Equatable {
  case invalidLocation
  case unavailable
  case failed(String)
}

struct ShaarDevToolsSensorPosition: Equatable, Sendable {
  var latitude: Double
  var longitude: Double
  var accuracy: Double
}

enum ShaarDevToolsSensorIdle: String, CaseIterable, Equatable, Sendable {
  case system
  case active
  case idle
  case locked

  var title: String {
    switch self {
    case .system: "System"
    case .active: "Active"
    case .idle: "Idle"
    case .locked: "Locked"
    }
  }

  var command: ShaarDevToolsSensorCommand {
    switch self {
    case .system: .clearIdle
    case .active: .idle(isUserActive: true, isScreenUnlocked: true)
    case .idle: .idle(isUserActive: false, isScreenUnlocked: true)
    case .locked: .idle(isUserActive: false, isScreenUnlocked: false)
    }
  }
}

enum ShaarDevToolsSensorCommand: Equatable, Sendable {
  case presetGeolocation(latitude: Double, longitude: Double)
  case geolocation(latitude: Double, longitude: Double, accuracy: Double)
  case clearGeolocation
  case timezone(String)
  case locale(String)
  case touch(Bool)
  case idle(isUserActive: Bool, isScreenUnlocked: Bool)
  case clearIdle

  var isTouch: Bool {
    if case .touch = self { return true }
    return false
  }

  var isIdle: Bool {
    switch self {
    case .idle, .clearIdle: true
    default: false
    }
  }

  var touchEnabled: Bool? {
    if case .touch(let enabled) = self { return enabled }
    return nil
  }

  var method: String {
    switch self {
    case .presetGeolocation, .geolocation:
      "Emulation.setGeolocationOverride"
    case .clearGeolocation:
      "Emulation.clearGeolocationOverride"
    case .timezone:
      "Emulation.setTimezoneOverride"
    case .locale:
      "Emulation.setLocaleOverride"
    case .touch:
      "Emulation.setTouchEmulationEnabled"
    case .idle:
      "Emulation.setIdleOverride"
    case .clearIdle:
      "Emulation.clearIdleOverride"
    }
  }

  var params: [String: Any] {
    switch self {
    case .presetGeolocation(let latitude, let longitude):
      ["latitude": latitude, "longitude": longitude, "accuracy": 1]
    case .geolocation(let latitude, let longitude, let accuracy):
      ["latitude": latitude, "longitude": longitude, "accuracy": accuracy]
    case .clearGeolocation:
      [:]
    case .timezone(let identifier):
      ["timezoneId": identifier]
    case .locale(let identifier):
      ["locale": identifier]
    case .touch(let enabled):
      ["enabled": enabled]
    case .idle(let isUserActive, let isScreenUnlocked):
      ["isUserActive": isUserActive, "isScreenUnlocked": isScreenUnlocked]
    case .clearIdle:
      [:]
    }
  }
}

enum ShaarDevToolsSensorCapability {
  static func isMissing(_ error: Error) -> Bool {
    let message = error.localizedDescription
    if message.contains("unknown DevTools") { return true }
    if message.contains("not allowed for this capability") { return true }
    if message.contains("This DevTools command is unavailable") { return true }
    if message == "DevTools request failed." { return true }
    return false
  }

  static func targetGone(_ error: Error) -> Bool {
    let message = error.localizedDescription
    if message.contains("no longer available") { return true }
    if message.contains("target changed") { return true }
    if message.contains("page changed") { return true }
    return false
  }
}

enum ShaarDevToolsSensorCommands {
  static func sanFrancisco() -> ShaarDevToolsSensorCommand {
    .presetGeolocation(latitude: 37.7749, longitude: -122.4194)
  }

  static func london() -> ShaarDevToolsSensorCommand {
    .presetGeolocation(latitude: 51.5074, longitude: -0.1278)
  }

  static func parsedLocation(latitude: String, longitude: String, accuracy: String)
    -> ShaarDevToolsSensorPosition?
  {
    let latitude = Double(latitude.trimmingCharacters(in: .whitespaces))
    let longitude = Double(longitude.trimmingCharacters(in: .whitespaces))
    let accuracy = Double(accuracy.trimmingCharacters(in: .whitespaces))
    guard let latitude, let longitude, let accuracy else { return nil }
    guard latitude.isFinite, longitude.isFinite, accuracy.isFinite else { return nil }
    guard latitude >= -90, latitude <= 90 else { return nil }
    guard longitude >= -180, longitude <= 180 else { return nil }
    guard accuracy >= 0 else { return nil }
    return ShaarDevToolsSensorPosition(
      latitude: latitude, longitude: longitude, accuracy: accuracy)
  }
}

extension ShaarDevToolsModel {
  func selectSensorLocation(_ choice: ShaarDevToolsSensorLocation) {
    sensorLocation = choice
    switch choice {
    case .system:
      deliver(ShaarDevToolsSensorCommand.clearGeolocation)
    case .sanFrancisco:
      deliver(ShaarDevToolsSensorCommands.sanFrancisco())
    case .london:
      deliver(ShaarDevToolsSensorCommands.london())
    case .custom:
      sensorNotice = nil
    }
  }

  func applySensorLocation() {
    guard
      let position = ShaarDevToolsSensorCommands.parsedLocation(
        latitude: sensorLatitude, longitude: sensorLongitude, accuracy: sensorAccuracy)
    else {
      sensorNotice = .invalidLocation
      return
    }
    sensorLocation = .custom
    deliver(
      .geolocation(
        latitude: position.latitude, longitude: position.longitude, accuracy: position.accuracy))
  }

  func selectSensorTimezone(_ choice: ShaarDevToolsSensorTimezone) {
    sensorTimezone = choice
    deliver(.timezone(choice.identifier))
  }

  func selectSensorLocale(_ choice: ShaarDevToolsSensorLocale) {
    sensorLocale = choice
    deliver(.locale(choice.identifier))
  }

  func setSensorTouch(_ enabled: Bool) {
    sensorTouch = enabled
    deliver(.touch(enabled))
  }

  func selectSensorIdle(_ choice: ShaarDevToolsSensorIdle) {
    sensorIdle = choice
    deliver(choice.command)
  }

  func probeIdleState() async {
    guard !idleProbeFinished, !idleProbeInFlight else { return }
    guard let engine = sensorEngine else { return }
    idleProbeInFlight = true
    defer { idleProbeInFlight = false }
    let page = engine.developerModel(for: target)
    do {
      try page.retainDeveloperSession()
      _ = try await page.call("Emulation.clearIdleOverride")
      sensorIdleReady = true
      idleProbeFinished = true
    } catch {
      if ShaarDevToolsSensorCapability.targetGone(error) { return }
      sensorIdleReady = !ShaarDevToolsSensorCapability.isMissing(error)
      idleProbeFinished = true
    }
  }

  func attachSensorSender(_ inspector: InspectorModel) {
    sensorEngine = inspector.engine
    guard sensorEngine != nil else {
      sendSensorCommand = nil
      return
    }
    sendSensorCommand = { [weak self] command in
      guard let self, let engine = self.sensorEngine else {
        throw DeveloperModeFailure(ShellL10n.string("Sensors need a page to override."))
      }
      let page = engine.developerModel(for: self.target)
      try page.retainDeveloperSession()
      _ = try await page.call(command.method, params: command.params)
    }
  }

  func resetSensorForm() {
    sensorGeneration += 1
    sensorLocation = .system
    sensorLatitude = ""
    sensorLongitude = ""
    sensorAccuracy = ""
    sensorTimezone = .system
    sensorLocale = .system
    sensorTouch = false
    sensorIdle = .system
    sensorNotice = nil
  }

  func resetSensors() {
    resetSensorForm()
    sensorEngine = nil
    sendSensorCommand = nil
  }

  private func deliver(_ command: ShaarDevToolsSensorCommand) {
    sensorFixture?(command)
    if command.isTouch && !sensorTouchReady {
      sensorNotice = nil
      return
    }
    if command.isIdle && !sensorIdleReady {
      sensorNotice = nil
      return
    }
    sensorGeneration += 1
    let generation = sensorGeneration
    guard let send = sendSensorCommand else {
      sensorNotice = .unavailable
      return
    }
    sensorNotice = nil
    Task { @MainActor in
      do {
        try await send(command)
      } catch {
        guard generation == self.sensorGeneration else { return }
        self.sensorNotice = .failed(error.localizedDescription)
      }
    }
  }
}

struct ShaarDevToolsSensorsPanel: View {
  @Bindable var model: ShaarDevToolsModel

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        location
        Divider()
        choiceRow(
          "Timezone",
          selection: timezoneChoice,
          options: ShaarDevToolsSensorTimezone.allCases.map { ($0.title, $0) },
          identifier: "shaar.devtools.sensorTimezone"
        )
        Divider()
        choiceRow(
          "Locale",
          selection: localeChoice,
          options: ShaarDevToolsSensorLocale.allCases.map { ($0.title, $0) },
          identifier: "shaar.devtools.sensorLocale"
        )
        Divider()
        touch
        Divider()
        idle
        notice
      }
      .padding(16)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .accessibilityIdentifier("shaar.devtools.sensors")
    .task { await model.probeIdleState() }
  }

  private var location: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 12) {
        fieldLabel("Location")
        Picker(selection: locationChoice) {
          Text(ShellL10n.string("System")).tag(ShaarDevToolsSensorLocation.system)
          Text(ShellL10n.string("San Francisco")).tag(ShaarDevToolsSensorLocation.sanFrancisco)
          Text(ShellL10n.string("London")).tag(ShaarDevToolsSensorLocation.london)
          Text(ShellL10n.string("Custom")).tag(ShaarDevToolsSensorLocation.custom)
        } label: {
          Text(ShellL10n.string("Location"))
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .accessibilityIdentifier("shaar.devtools.sensorLocation")
        Spacer(minLength: 0)
        Button(ShellL10n.string("Clear location")) {
          model.selectSensorLocation(.system)
        }
        .controlSize(.small)
        .accessibilityIdentifier("shaar.devtools.sensorClear")
      }
      if model.sensorLocation == .custom {
        customLocation
      }
    }
  }

  private var customLocation: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 8) {
        sensorField(
          "Latitude", text: $model.sensorLatitude, identifier: "shaar.devtools.sensorLatitude")
        sensorField(
          "Longitude", text: $model.sensorLongitude, identifier: "shaar.devtools.sensorLongitude")
        sensorField(
          "Accuracy", text: $model.sensorAccuracy, identifier: "shaar.devtools.sensorAccuracy")
      }
      Button(ShellL10n.string("Apply")) {
        model.applySensorLocation()
      }
      .controlSize(.small)
      .accessibilityIdentifier("shaar.devtools.sensorApply")
    }
  }

  private var touch: some View {
    VStack(alignment: .leading, spacing: 6) {
      Toggle(isOn: touchChoice) {
        Text(ShellL10n.string("Touch"))
          .font(.system(size: 12, weight: .medium))
      }
      .toggleStyle(.switch)
      .disabled(!model.sensorTouchReady)
      .accessibilityIdentifier("shaar.devtools.sensorTouch")
      if !model.sensorTouchReady {
        Text(ShellL10n.string("Touch emulation waits for the next engine build."))
          .font(.system(size: 11))
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private var idle: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 12) {
        fieldLabel("Idle")
        Picker(selection: idleChoice) {
          ForEach(ShaarDevToolsSensorIdle.allCases, id: \.self) { option in
            Text(ShellL10n.string(option.title)).tag(option)
          }
        } label: {
          Text(ShellL10n.string("Idle"))
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .disabled(!model.sensorIdleReady)
        .accessibilityIdentifier("shaar.devtools.sensorIdle")
        Spacer(minLength: 0)
      }
      if !model.sensorIdleReady {
        Text(ShellL10n.string("Idle state waits for the next engine build."))
          .font(.system(size: 11))
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("shaar.devtools.sensorIdleNote")
      }
    }
  }

  @ViewBuilder private var notice: some View {
    switch model.sensorNotice {
    case .invalidLocation:
      Text(
        ShellL10n.string(
          "Enter a latitude from -90 to 90, a longitude from -180 to 180, and an accuracy of at least 0."
        )
      )
      .font(.system(size: 12))
      .foregroundStyle(.orange)
      .fixedSize(horizontal: false, vertical: true)
    case .unavailable:
      Text(ShellL10n.string("Sensors need a page to override."))
        .font(.system(size: 12))
        .foregroundStyle(.orange)
        .fixedSize(horizontal: false, vertical: true)
    case .failed(let message):
      Text(verbatim: message)
        .font(.system(size: 12))
        .foregroundStyle(.orange)
        .fixedSize(horizontal: false, vertical: true)
    case nil:
      EmptyView()
    }
  }

  private var locationChoice: Binding<ShaarDevToolsSensorLocation> {
    Binding(
      get: { model.sensorLocation },
      set: { choice in model.selectSensorLocation(choice) }
    )
  }

  private var timezoneChoice: Binding<ShaarDevToolsSensorTimezone> {
    Binding(
      get: { model.sensorTimezone },
      set: { choice in model.selectSensorTimezone(choice) }
    )
  }

  private var localeChoice: Binding<ShaarDevToolsSensorLocale> {
    Binding(
      get: { model.sensorLocale },
      set: { choice in model.selectSensorLocale(choice) }
    )
  }

  private var touchChoice: Binding<Bool> {
    Binding(
      get: { model.sensorTouch },
      set: { enabled in model.setSensorTouch(enabled) }
    )
  }

  private var idleChoice: Binding<ShaarDevToolsSensorIdle> {
    Binding(
      get: { model.sensorIdle },
      set: { choice in model.selectSensorIdle(choice) }
    )
  }

  private func choiceRow<Option: Hashable>(
    _ title: String, selection: Binding<Option>, options: [(String, Option)], identifier: String
  ) -> some View {
    HStack(spacing: 12) {
      fieldLabel(title)
      Picker(selection: selection) {
        ForEach(options, id: \.1) { option in
          Text(ShellL10n.string(option.0)).tag(option.1)
        }
      } label: {
        Text(ShellL10n.string(title))
      }
      .labelsHidden()
      .pickerStyle(.segmented)
      .accessibilityIdentifier(identifier)
    }
  }

  private func fieldLabel(_ title: String) -> some View {
    Text(ShellL10n.string(title))
      .font(.system(size: 12, weight: .medium))
      .frame(width: 88, alignment: .leading)
  }

  private func sensorField(_ title: String, text: Binding<String>, identifier: String) -> some View
  {
    VStack(alignment: .leading, spacing: 4) {
      Text(ShellL10n.string(title))
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(.secondary)
      TextField(ShellL10n.string(title), text: text)
        .textFieldStyle(.roundedBorder)
        .font(.system(size: 12, design: .monospaced))
        .accessibilityIdentifier(identifier)
    }
  }
}
