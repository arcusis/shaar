// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import Foundation

@main
enum ShaarVerificationMain {
  @MainActor static func main() {
    if let code = harnessExitCode(CommandLine.arguments) {
      exit(code)
    }
    if CommandLine.arguments.contains("--browsing-qa") {
      exit(ShaarBrowsingQA.run(arguments: CommandLine.arguments))
    }
    if CommandLine.arguments.contains("--devtools-f12-route") {
      exit(ShaarDevToolsF12RouteSmoke.run(arguments: CommandLine.arguments))
    }
    if let index = CommandLine.arguments.firstIndex(of: "--platform-parity-probe"),
      CommandLine.arguments.indices.contains(index + 3),
      let frameworks = Bundle.main.privateFrameworksURL
    {
      let framework = frameworks.appending(path: "Chromium Framework.framework")
      let output = URL(fileURLWithPath: CommandLine.arguments[index + 1])
      exit(
        PlatformParityProbe.run(
          frameworkURL: framework, outputURL: output,
          httpBase: URL(string: CommandLine.arguments[index + 2]),
          httpsBase: URL(string: CommandLine.arguments[index + 3])))
    }
    if CommandLine.arguments.contains("--probe-shaar-preview") {
      exit(ShaarPreviewProbe.run(arguments: CommandLine.arguments))
    }
    if CommandLine.arguments.contains("--probe-shaar-first-tab") {
      exit(ShaarFirstTabProbe.run(arguments: CommandLine.arguments))
    }
    if CommandLine.arguments.contains("--probe-website-permission") {
      exit(WebsitePermissionPromptProbe.run(arguments: CommandLine.arguments))
    }
    if let result = storeLanguage(
      arguments: CommandLine.arguments, bundleIdentifier: Bundle.main.bundleIdentifier)
    {
      exit(result)
    }
    if CommandLine.arguments.contains("--probe-profile-providers")
      || CommandLine.arguments.contains("--probe-profile-fixture")
    {
      exit(ProfileOnboardingProbe.runStandalone(arguments: CommandLine.arguments))
    }
    if CommandLine.arguments.contains("--marketing-screenshots") {
      exit(MarketingScreenshots.run(arguments: CommandLine.arguments))
    }
    if CommandLine.arguments.contains("--inspector-idle-smoke") {
      let arguments = CommandLine.arguments
      guard let index = arguments.firstIndex(of: "--inspector-idle-smoke"),
        arguments.indices.contains(index + 2),
        let frameworks = Bundle.main.privateFrameworksURL
      else {
        exit(2)
      }
      let framework = frameworks.appending(path: "Chromium Framework.framework")
      let output = URL(fileURLWithPath: arguments[index + 1])
      let page = URL(string: arguments[index + 2])
      exit(InspectorIdleSmoke.run(frameworkURL: framework, outputURL: output, pageURL: page))
    }
    if let index = CommandLine.arguments.firstIndex(of: "--browsing-edge-probe"),
      CommandLine.arguments.indices.contains(index + 2),
      let frameworks = Bundle.main.privateFrameworksURL
    {
      let framework = frameworks.appending(path: "Chromium Framework.framework")
      let output = URL(fileURLWithPath: CommandLine.arguments[index + 1])
      let page = URL(string: CommandLine.arguments[index + 2])
      exit(ShaarBrowsingEdgeProbe.run(frameworkURL: framework, outputURL: output, pageURL: page))
    }
    exit(EngineProbe.run(arguments: CommandLine.arguments))
  }

  private struct HarnessLaunch {
    var framework: URL
    var output: URL
    var page: URL?
    var remainder: String?
  }

  /// Launch arguments for one moved smoke or probe. Nil when the flag is absent or incomplete.
  private static func harnessLaunch(_ flag: String, _ arguments: [String]) -> HarnessLaunch? {
    guard let index = arguments.firstIndex(of: flag),
      arguments.indices.contains(index + 2),
      let frameworks = Bundle.main.privateFrameworksURL
    else { return nil }
    let remainder = arguments.indices.contains(index + 3) ? arguments[index + 3] : nil
    return HarnessLaunch(
      framework: frameworks.appending(path: "Chromium Framework.framework"),
      output: URL(fileURLWithPath: arguments[index + 1]),
      page: URL(string: arguments[index + 2]),
      remainder: remainder)
  }

  /// Runs a harness that used to dispatch from the shipping executable.
  @MainActor private static func harnessExitCode(_ arguments: [String]) -> Int32? {
    if let launch = harnessLaunch("--tab-adoption-smoke", arguments) {
      return ShaarTabAdoptionSmoke.run(
        frameworkURL: launch.framework, outputURL: launch.output, pageURL: launch.page)
    }
    if let launch = harnessLaunch("--devtools-smoke", arguments) {
      let mode = launch.remainder ?? "fixture"
      let spaOnly = mode == "spa-only"
      let roundTwo = mode == "round-two"
      return ShaarDevToolsSmoke.run(
        frameworkURL: launch.framework, outputURL: launch.output, pageURL: launch.page,
        realWorld: mode == "real-world" || spaOnly || roundTwo,
        spaOnly: spaOnly, roundTwo: roundTwo)
    }
    if let launch = harnessLaunch("--devtools-capability-probe", arguments) {
      return NativeDevToolsCapabilityProbe.run(
        frameworkURL: launch.framework, outputURL: launch.output, pageURL: launch.page)
    }
    if let launch = harnessLaunch("--rendering-probe", arguments) {
      return ShaarRenderingProbe.run(
        frameworkURL: launch.framework, outputURL: launch.output, pageURL: launch.page)
    }
    if let launch = harnessLaunch("--recorder-probe", arguments) {
      return ShaarRecorderProbe.run(
        frameworkURL: launch.framework, outputURL: launch.output, pageURL: launch.page)
    }
    if let launch = harnessLaunch("--sensors-probe", arguments) {
      return ShaarSensorsProbe.run(
        frameworkURL: launch.framework, outputURL: launch.output, pageURL: launch.page)
    }
    if let launch = harnessLaunch("--event-listeners-probe", arguments) {
      return ShaarEventListenersProbe.run(
        frameworkURL: launch.framework, outputURL: launch.output, pageURL: launch.page)
    }
    if let launch = harnessLaunch("--audits-probe", arguments) {
      return InspectorAuditProbe.run(
        frameworkURL: launch.framework, outputURL: launch.output, pageURL: launch.page)
    }
    return nil
  }

  static func storeLanguage(
    arguments: [String], bundleIdentifier: String?, defaults: UserDefaults = .standard,
    domainName: String = Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName
  ) -> Int32? {
    guard let index = arguments.firstIndex(of: "--probe-store-language"),
      arguments.indices.contains(index + 1),
      let selection = BrowserLanguage(rawValue: arguments[index + 1]),
      bundleIdentifier?.hasPrefix("com.arcusis.localization-fixture.") == true
    else { return nil }
    BrowserLanguage.store(selection, defaults: defaults, domainName: domainName)
    return defaults.synchronize() ? 0 : 1
  }
}
