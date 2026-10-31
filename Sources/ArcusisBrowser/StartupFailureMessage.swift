// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import Foundation

/// Startup errors from the file system and the engine can embed paths in their descriptions, so
/// stderr only ever gets a fixed sentence for the kind of failure plus the error's domain and code.
enum StartupFailureMessage {
  static func text(for error: Error) -> String {
    let nsError = error as NSError
    return "Browser startup failed: \(summary(of: error)) [\(nsError.domain) \(nsError.code)]"
  }

  private static func summary(of error: Error) -> String {
    switch error {
    case WorkspaceLockError.inUse:
      "Another \(ProductIdentity.name) process is using this workspace."
    case WorkspaceLockError.invalidFile:
      "The workspace lock file is invalid."
    case is WorkspaceError:
      "The saved workspace could not be opened."
    case is CocoaError, is POSIXError:
      "The browser data folder is not accessible."
    case let error as NSError where error.domain == engineErrorDomain:
      "The browser engine could not be loaded."
    default:
      "An unexpected error occurred."
    }
  }

  private static let engineErrorDomain = "com.arcusis.browser.chromium"
}
