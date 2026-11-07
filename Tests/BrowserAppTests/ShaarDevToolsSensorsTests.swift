// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing

@testable import ArcusisBrowser

@Test func typedLocationUsesTheGeolocationOverrideCommand() {
  let command = ShaarDevToolsSensorCommand.geolocation(
    latitude: 48.8566, longitude: 2.3522, accuracy: 12)
  #expect(command.method == "Emulation.setGeolocationOverride")
  #expect(command.params["latitude"] as? Double == 48.8566)
  #expect(command.params["longitude"] as? Double == 2.3522)
  #expect(command.params["accuracy"] as? Double == 12)
  #expect(
    ShaarDevToolsSensorCommands.parsedLocation(latitude: "91", longitude: "0", accuracy: "1")
      == nil)
  #expect(
    ShaarDevToolsSensorCommands.parsedLocation(latitude: " 37.5 ", longitude: "-122", accuracy: "0")
      == ShaarDevToolsSensorPosition(latitude: 37.5, longitude: -122, accuracy: 0))
}

@Test func clearedLocationMatchesTheExistingSimulationCommand() {
  let expected = simulationCommand("Emulation.clearGeolocationOverride") { _ in }
  let command = ShaarDevToolsSensorCommand.clearGeolocation
  #expect(command.method == expected.0)
  #expect(sameParams(command.params, expected.1))
}

@Test func cityPresetsMatchTheExistingSimulationCommands() {
  let sanFrancisco = simulationCommand("Emulation.setGeolocationOverride") {
    $0.location = .sanFrancisco
  }
  let london = simulationCommand("Emulation.setGeolocationOverride") { $0.location = .london }
  #expect(sameParams(ShaarDevToolsSensorCommands.sanFrancisco().params, sanFrancisco.1))
  #expect(sameParams(ShaarDevToolsSensorCommands.london().params, london.1))
}

@Test func timezoneMatchesTheExistingSimulationCommand() {
  let newYork = simulationCommand("Emulation.setTimezoneOverride") { $0.timezone = .newYork }
  let tokyo = simulationCommand("Emulation.setTimezoneOverride") { $0.timezone = .tokyo }
  let system = simulationCommand("Emulation.setTimezoneOverride") { _ in }
  #expect(sameParams(ShaarDevToolsSensorCommand.timezone("America/New_York").params, newYork.1))
  #expect(sameParams(ShaarDevToolsSensorCommand.timezone("Asia/Tokyo").params, tokyo.1))
  #expect(sameParams(ShaarDevToolsSensorCommand.timezone("").params, system.1))
}

@Test func localeMatchesTheExistingSimulationCommand() {
  let french = simulationCommand("Emulation.setLocaleOverride") { $0.language = .french }
  let hebrew = simulationCommand("Emulation.setLocaleOverride") { $0.language = .hebrew }
  let english = simulationCommand("Emulation.setLocaleOverride") { $0.language = .english }
  let system = simulationCommand("Emulation.setLocaleOverride") { _ in }
  #expect(sameParams(ShaarDevToolsSensorCommand.locale("fr-FR").params, french.1))
  #expect(sameParams(ShaarDevToolsSensorCommand.locale("he-IL").params, hebrew.1))
  #expect(sameParams(ShaarDevToolsSensorCommand.locale("en-US").params, english.1))
  #expect(sameParams(ShaarDevToolsSensorCommand.locale("").params, system.1))
}

@MainActor @Test func touchIsRecordedByTheFixtureAndNotSentWhileTheEngineLacksIt() async {
  let model = sensorModel(suite: "ShaarDevToolsSensors")
  var recorded: [ShaarDevToolsSensorCommand] = []
  var sent: [ShaarDevToolsSensorCommand] = []
  model.sensorFixture = { command in recorded.append(command) }
  model.sendSensorCommand = { command in sent.append(command) }
  model.setSensorTouch(true)
  #expect(model.sensorTouch)
  #expect(recorded == [.touch(true)])
  #expect(sent.isEmpty)
  #expect(model.sensorNotice == nil)
  let delivered = await collect(model, expected: 1) {
    model.sensorTouchReady = true
    model.setSensorTouch(false)
  }
  #expect(recorded == [.touch(true), .touch(false)])
  #expect(delivered == [.touch(false)])
}

@MainActor @Test func selectingAPresetSendsTheExistingCommand() async {
  let model = sensorModel(suite: "ShaarDevToolsSensors.send")
  let sent = await collect(model, expected: 3) {
    model.selectSensorLocation(.sanFrancisco)
    model.selectSensorTimezone(.newYork)
    model.selectSensorLocale(.french)
    model.sensorLatitude = "91"
    model.sensorLongitude = "0"
    model.sensorAccuracy = "1"
    model.applySensorLocation()
  }
  #expect(
    sent == [
      ShaarDevToolsSensorCommands.sanFrancisco(), .timezone("America/New_York"), .locale("fr-FR"),
    ])
  #expect(model.sensorNotice == .invalidLocation)
}

@MainActor private func sensorModel(suite: String) -> ShaarDevToolsModel {
  let defaults = UserDefaults(suiteName: "\(suite).\(UUID().uuidString)")!
  let target = SiteControlTarget(
    tabID: UUID(), profileID: UUID(), url: URL(string: "http://localhost:3000/")!)
  return ShaarDevToolsModel(target: target, layoutDefaults: defaults)
}

@MainActor private func collect(
  _ model: ShaarDevToolsModel, expected: Int, actions: @MainActor () -> Void
) async -> [ShaarDevToolsSensorCommand] {
  await withCheckedContinuation { continuation in
    var sent: [ShaarDevToolsSensorCommand] = []
    model.sendSensorCommand = { command in
      sent.append(command)
      if sent.count == expected { continuation.resume(returning: sent) }
    }
    actions()
  }
}

private func simulationCommand(
  _ method: String, configure: (inout DeveloperSimulation) -> Void
) -> (String, [String: Any]) {
  var simulation = DeveloperSimulation()
  configure(&simulation)
  let match = simulation.commands(userAgent: "fixture").first { $0.0 == method }
  #expect(match != nil)
  return match ?? (method, [:])
}

private func sameParams(_ actual: [String: Any], _ expected: [String: Any]) -> Bool {
  NSDictionary(dictionary: actual).isEqual(to: expected)
}
