// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import Foundation

@main
enum ShaarVerificationMain {
  @MainActor static func main() {
    if let index = CommandLine.arguments.firstIndex(of: "--probe-store-language"),
      CommandLine.arguments.indices.contains(index + 1),
      let selection = BrowserLanguage(rawValue: CommandLine.arguments[index + 1]),
      Bundle.main.bundleIdentifier?.hasPrefix("com.arcusis.localization-fixture.") == true
    {
      BrowserLanguage.selection = selection
      guard UserDefaults.standard.synchronize() else { exit(1) }
      exit(0)
    }
    if CommandLine.arguments.contains("--marketing-screenshots") {
      exit(MarketingScreenshots.run(arguments: CommandLine.arguments))
    }
    exit(EngineProbe.run(arguments: CommandLine.arguments))
  }
}
