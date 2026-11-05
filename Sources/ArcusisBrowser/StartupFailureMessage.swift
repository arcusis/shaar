// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import Foundation

/// Startup errors from the file system and the engine can embed paths in their descriptions, so
/// stderr only ever gets a fixed sentence for the kind of failure plus the error's domain and code.
enum StartupFailureMessage {
  static func text(for error: Error) -> String {
    text(for: error, language: .currentLaunchLanguage)
  }

  static func text(for error: Error, language: BrowserLanguage) -> String {
    let nsError = error as NSError
    let message = BrowserLocalization.format(
      "Browser startup failed: %@", table: "Shell", language: language,
      arguments: [.string(summary(of: error, language: language))])
    return "\(message) [\(nsError.domain) \(nsError.code)]"
  }

  private static func summary(of error: Error, language: BrowserLanguage) -> String {
    switch error {
    case WorkspaceLockError.inUse:
      BrowserLocalization.format(
        "Another %@ process is using this workspace.", table: "Core", language: language,
        arguments: [.string(ProductIdentity.name)])
    case WorkspaceLockError.invalidFile:
      BrowserLocalization.string(
        "The workspace lock file is invalid.", table: "Core", language: language)
    case is WorkspaceError:
      BrowserLocalization.string(
        "The saved workspace could not be opened.", table: "Shell", language: language)
    case is CocoaError, is POSIXError:
      BrowserLocalization.string(
        "The browser data folder is not accessible.", table: "Shell", language: language)
    case let error as NSError where error.domain == engineErrorDomain:
      BrowserLocalization.string(
        "The browser engine could not be loaded.", table: "Shell", language: language)
    default:
      BrowserLocalization.string(
        "An unexpected error occurred.", table: "Shell", language: language)
    }
  }

  private static let engineErrorDomain = "com.arcusis.browser.chromium"
}
