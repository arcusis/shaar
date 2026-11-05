// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// The browser is Shaar (Hebrew שער, "gateway"); Arcusis is the company that makes it.
public enum ProductIdentity {
  public static let enginePreviewBundleIdentifier = "com.arcusis.browser.engine-preview"
  public static var isEnginePreviewBundle: Bool {
    isEnginePreviewBundle(bundleIdentifier: Bundle.main.bundleIdentifier)
  }
  static func isEnginePreviewBundle(bundleIdentifier: String?) -> Bool {
    bundleIdentifier == enginePreviewBundleIdentifier
  }
  public static var name: String {
    name(forBundleIdentifier: Bundle.main.bundleIdentifier)
  }
  static func name(forBundleIdentifier bundleIdentifier: String?) -> String {
    if isEnginePreviewBundle(bundleIdentifier: bundleIdentifier) {
      return "Shaar Engine Preview"
    }
    return "Shaar"
  }
  public static var meaning: String {
    "שער — " + BrowserLocalization.string("the gateway to the internet", table: "Core")
  }
  /// The installed engine Preview must never load the regular browser's workspace or profiles.
  public static var dataFolderName: String {
    dataFolderName(
      forBundleIdentifier: Bundle.main.bundleIdentifier, info: Bundle.main.infoDictionary)
  }
  static func dataFolderName(forBundleIdentifier bundleIdentifier: String?, info: [String: Any]?)
    -> String
  {
    if isEnginePreviewBundle(bundleIdentifier: bundleIdentifier) {
      return info?["ShaarDataFolderName"] as? String ?? "Shaar Engine Preview"
    }
    return "Arcusis Browser"
  }
  public static var cacheFolderName: String {
    cacheFolderName(
      forBundleIdentifier: Bundle.main.bundleIdentifier, info: Bundle.main.infoDictionary)
  }
  static func cacheFolderName(forBundleIdentifier bundleIdentifier: String?, info: [String: Any]?)
    -> String
  {
    if isEnginePreviewBundle(bundleIdentifier: bundleIdentifier) {
      return info?["ShaarCacheFolderName"] as? String ?? "Shaar Engine Preview"
    }
    return "Shaar"
  }
}
