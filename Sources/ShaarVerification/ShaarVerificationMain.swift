// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import Foundation

@main
enum ShaarVerificationMain {
  @MainActor static func main() {
    if CommandLine.arguments.contains("--browsing-qa") {
      exit(ShaarBrowsingQA.run(arguments: CommandLine.arguments))
    }
    if CommandLine.arguments.contains("--devtools-f12-route") {
      exit(ShaarDevToolsF12RouteSmoke.run(arguments: CommandLine.arguments))
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
