// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import Foundation

@main
enum ShaarVerificationMain {
  @MainActor static func main() {
    if let result = storeLanguage(
      arguments: CommandLine.arguments, bundleIdentifier: Bundle.main.bundleIdentifier)
    {
      exit(result)
    }
    if CommandLine.arguments.contains("--marketing-screenshots") {
      exit(MarketingScreenshots.run(arguments: CommandLine.arguments))
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
