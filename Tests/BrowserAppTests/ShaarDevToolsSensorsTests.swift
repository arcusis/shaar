// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import Foundation
import SwiftUI
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

@Test func idleCommandsUseTheEmulationMethods() {
  let active = ShaarDevToolsSensorIdle.active.command
  let idle = ShaarDevToolsSensorIdle.idle.command
  let locked = ShaarDevToolsSensorIdle.locked.command
  let cleared = ShaarDevToolsSensorIdle.system.command
  #expect(active.method == "Emulation.setIdleOverride")
  #expect(active.params["isUserActive"] as? Bool == true)
  #expect(active.params["isScreenUnlocked"] as? Bool == true)
  #expect(idle.params["isUserActive"] as? Bool == false)
  #expect(idle.params["isScreenUnlocked"] as? Bool == true)
  #expect(locked.params["isUserActive"] as? Bool == false)
  #expect(locked.params["isScreenUnlocked"] as? Bool == false)
  #expect(cleared.method == "Emulation.clearIdleOverride")
  #expect(cleared.params.isEmpty)
}

@MainActor @Test func idleIsRecordedByTheFixtureAndNotSentWhileTheEngineLacksIt() async {
  let model = sensorModel(suite: "ShaarDevToolsSensors.idle")
  var recorded: [ShaarDevToolsSensorCommand] = []
  var sent: [ShaarDevToolsSensorCommand] = []
  model.sensorFixture = { command in recorded.append(command) }
  model.sendSensorCommand = { command in sent.append(command) }
  model.selectSensorIdle(.idle)
  #expect(model.sensorIdle == .idle)
  #expect(recorded == [ShaarDevToolsSensorIdle.idle.command])
  #expect(sent.isEmpty)
  #expect(model.sensorNotice == nil)
  let delivered = await collect(model, expected: 1) {
    model.sensorIdleReady = true
    model.selectSensorIdle(.system)
  }
  #expect(delivered == [.clearIdle])
}

@Test func idleCapabilityTreatsAProtocolErrorAsPresent() {
  let unknown = SensorSampleError(errorDescription: "unknown DevTools capability or command")
  let denied = SensorSampleError(
    errorDescription: "DevTools command is not allowed for this capability")
  let bridge = SensorSampleError(errorDescription: "This DevTools command is unavailable.")
  let dropped = SensorSampleError(errorDescription: "DevTools request failed.")
  let invalid = SensorSampleError(errorDescription: "DevTools command parameters are invalid")
  let missingFields = SensorSampleError(
    errorDescription: "DevTools command is missing required parameters")
  let gone = SensorSampleError(
    errorDescription: "The developer tools target is no longer available.")
  #expect(ShaarDevToolsSensorCapability.isMissing(unknown))
  #expect(ShaarDevToolsSensorCapability.isMissing(denied))
  #expect(ShaarDevToolsSensorCapability.isMissing(bridge))
  #expect(ShaarDevToolsSensorCapability.isMissing(dropped))
  #expect(!ShaarDevToolsSensorCapability.isMissing(invalid))
  #expect(!ShaarDevToolsSensorCapability.isMissing(missingFields))
  #expect(!ShaarDevToolsSensorCapability.isMissing(gone))
  #expect(ShaarDevToolsSensorCapability.targetGone(gone))
  #expect(
    ShaarDevToolsSensorCapability.targetGone(
      SensorSampleError(errorDescription: "The page changed before the command finished.")))
  #expect(!ShaarDevToolsSensorCapability.targetGone(invalid))
}

@MainActor @Test func idleControlRendersOffscreenBeforeAndAfterTheEngineAcceptsIt() throws {
  _ = NSApplication.shared
  #expect(ShaarDevToolsSensorIdle.allCases.map(\.title) == ["System", "Active", "Idle", "Locked"])
  let model = sensorModel(suite: "ShaarDevToolsSensors.idleRender")
  let inspector = InspectorModel(target: model.target, engine: nil)
  model.open(inspector: inspector)
  model.section = .sensors
  #expect(!model.sensorIdleReady)
  let waiting = try VisualCapture.pngOffscreen(
    ShaarDevToolsSensorsPanel(model: model), size: NSSize(width: 640, height: 520))
  model.sensorIdleReady = true
  model.sensorIdle = .locked
  let ready = try VisualCapture.pngOffscreen(
    ShaarDevToolsSensorsPanel(model: model), size: NSSize(width: 640, height: 480))
  let panel = try VisualCapture.pngOffscreen(
    ShaarDevToolsPanel(model: model, inspector: inspector, openChromium: {}),
    size: NSSize(width: 850, height: 620))
  #expect(!waiting.isEmpty)
  #expect(!ready.isEmpty)
  #expect(!panel.isEmpty)
  model.close()
}

@MainActor @Test func touchProbeEnablesTheSwitchWhenThePageAcceptsIt() async {
  let model = sensorModel(suite: "ShaarDevToolsSensors.touchProbe")
  var sent: [ShaarDevToolsSensorCommand] = []
  model.sendSensorCommand = { command in sent.append(command) }
  await model.probeTouchState()
  #expect(model.sensorTouchReady)
  #expect(sent == [.touch(false)])
  await model.probeTouchState()
  #expect(sent == [.touch(false)])
}

@MainActor @Test func touchProbeStaysDisabledWhenTheEngineRejectsIt() async {
  let model = sensorModel(suite: "ShaarDevToolsSensors.touchMissing")
  model.sendSensorCommand = { _ in
    throw DeveloperModeFailure("unknown DevTools capability or command")
  }
  await model.probeTouchState()
  #expect(!model.sensorTouchReady)
  model.setSensorTouch(true)
  #expect(model.sensorTouch)
  #expect(model.sensorNotice == nil)
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

@Test func sensorTitlesIdentifiersAndTouchCommand() {
  #expect(ShaarDevToolsSensorTimezone.allCases.map(\.title) == ["System", "New York", "Tokyo"])
  #expect(
    ShaarDevToolsSensorTimezone.allCases.map(\.identifier) == [
      "", "America/New_York", "Asia/Tokyo",
    ])
  #expect(
    ShaarDevToolsSensorLocale.allCases.map(\.title) == ["System", "English", "French", "Hebrew"])
  #expect(ShaarDevToolsSensorLocale.allCases.map(\.identifier) == ["", "en-US", "fr-FR", "he-IL"])
  let touch = ShaarDevToolsSensorCommand.touch(true)
  #expect(touch.isTouch)
  #expect(touch.touchEnabled == true)
  #expect(touch.method == "Emulation.setTouchEmulationEnabled")
  #expect(touch.params["enabled"] as? Bool == true)
  #expect(ShaarDevToolsSensorCommand.clearGeolocation.isTouch == false)
  #expect(ShaarDevToolsSensorCommand.clearGeolocation.touchEnabled == nil)
}

@MainActor @Test func sensorsPanelRendersOffscreenForEachState() async throws {
  _ = NSApplication.shared
  let model = sensorModel(suite: "ShaarDevToolsSensors.render")
  let target = model.target
  let inspector = InspectorModel(target: target, engine: nil)
  model.open(inspector: inspector)
  model.section = .sensors
  let waiting = try VisualCapture.pngOffscreen(
    ShaarDevToolsSensorsPanel(model: model), size: NSSize(width: 640, height: 420))
  model.sensorLocation = .custom
  model.sensorLatitude = "91"
  model.sensorLongitude = "0"
  model.sensorAccuracy = "1"
  model.applySensorLocation()
  #expect(model.sensorNotice == .invalidLocation)
  let invalid = try VisualCapture.pngOffscreen(
    ShaarDevToolsSensorsPanel(model: model), size: NSSize(width: 640, height: 480))
  model.sendSensorCommand = nil
  model.selectSensorLocation(.system)
  model.selectSensorTimezone(.system)
  model.selectSensorLocale(.system)
  #expect(model.sensorNotice == .unavailable)
  let unavailable = try VisualCapture.pngOffscreen(
    ShaarDevToolsSensorsPanel(model: model), size: NSSize(width: 640, height: 420))
  model.sendSensorCommand = { _ in throw DeveloperModeFailure("Sensors failed.") }
  model.selectSensorLocale(.english)
  for _ in 0..<40 where model.sensorNotice != .failed("Sensors failed.") {
    await Task.yield()
  }
  #expect(model.sensorNotice == .failed("Sensors failed."))
  let failed = try VisualCapture.pngOffscreen(
    ShaarDevToolsSensorsPanel(model: model), size: NSSize(width: 640, height: 420))
  model.sensorTouchReady = true
  model.sensorTouch = true
  model.sensorNotice = nil
  let ready = try VisualCapture.pngOffscreen(
    ShaarDevToolsSensorsPanel(model: model), size: NSSize(width: 640, height: 420))
  let nextTab = SiteControlTarget(tabID: UUID(), profileID: target.profileID, url: target.url)
  model.sensorLocation = .london
  model.updateTarget(nextTab)
  #expect(model.sensorLocation == .system)
  let panel = try VisualCapture.pngOffscreen(
    ShaarDevToolsPanel(model: model, inspector: inspector, openChromium: {}),
    size: NSSize(width: 850, height: 620))
  #expect(!waiting.isEmpty)
  #expect(!invalid.isEmpty)
  #expect(!unavailable.isEmpty)
  #expect(!failed.isEmpty)
  #expect(!ready.isEmpty)
  #expect(!panel.isEmpty)
  model.close()
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

private struct SensorSampleError: LocalizedError {
  var errorDescription: String?
  init(errorDescription: String) { self.errorDescription = errorDescription }
}
