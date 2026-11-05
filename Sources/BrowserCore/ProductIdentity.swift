// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// The browser is Shaar (Hebrew שער, "gateway"); Arcusis is the company that makes it.
public enum ProductIdentity {
  public static let enginePreviewBundleIdentifier = "com.arcusis.browser.engine-preview"
  public static var isEnginePreviewBundle: Bool {
    Bundle.main.bundleIdentifier == enginePreviewBundleIdentifier
  }
  public static var name: String {
    isEnginePreviewBundle ? "Shaar Engine Preview" : "Shaar"
  }
  public static var meaning: String {
    "שער — " + BrowserLocalization.string("the gateway to the internet", table: "Core")
  }
  /// The installed engine Preview must never load the regular browser's workspace or profiles.
  public static var dataFolderName: String {
    if isEnginePreviewBundle {
      return Bundle.main.object(forInfoDictionaryKey: "ShaarDataFolderName") as? String
        ?? "Shaar Engine Preview"
    }
    return "Arcusis Browser"
  }
  public static var cacheFolderName: String {
    if isEnginePreviewBundle {
      return Bundle.main.object(forInfoDictionaryKey: "ShaarCacheFolderName") as? String
        ?? "Shaar Engine Preview"
    }
    return "Shaar"
  }
}
