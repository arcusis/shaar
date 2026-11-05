// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Testing

@testable import BrowserCore

@Suite struct ProductIdentityTests {
  @Test func regularBundleKeepsExistingDataAndCacheRoots() {
    #expect(ProductIdentity.isEnginePreviewBundle == false)
    #expect(ProductIdentity.cacheFolderName == "Shaar")
    #expect(ProductIdentity.name(forBundleIdentifier: "com.arcusis.browser") == "Shaar")
    #expect(
      ProductIdentity.dataFolderName(forBundleIdentifier: "com.arcusis.browser", info: [:])
        == "Arcusis Browser")
    #expect(
      ProductIdentity.cacheFolderName(forBundleIdentifier: "com.arcusis.browser", info: [:])
        == "Shaar")
  }

  @Test func enginePreviewUsesDistinctIdentityAndConfiguredRoots() {
    let bundleID = ProductIdentity.enginePreviewBundleIdentifier
    let info = [
      "ShaarDataFolderName": "Shaar Engine Preview Data",
      "ShaarCacheFolderName": "Shaar Engine Preview Cache",
    ]
    #expect(ProductIdentity.name(forBundleIdentifier: bundleID) == "Shaar Engine Preview")
    #expect(
      ProductIdentity.dataFolderName(forBundleIdentifier: bundleID, info: info)
        == "Shaar Engine Preview Data")
    #expect(
      ProductIdentity.cacheFolderName(forBundleIdentifier: bundleID, info: info)
        == "Shaar Engine Preview Cache")
  }

  @Test func enginePreviewHasIsolatedFallbackRoots() {
    let bundleID = ProductIdentity.enginePreviewBundleIdentifier
    #expect(
      ProductIdentity.dataFolderName(forBundleIdentifier: bundleID, info: [:])
        == "Shaar Engine Preview")
    #expect(
      ProductIdentity.cacheFolderName(forBundleIdentifier: bundleID, info: [:])
        == "Shaar Engine Preview")
    #expect(
      ProductIdentity.dataFolderName(forBundleIdentifier: bundleID, info: nil)
        == "Shaar Engine Preview")
    #expect(
      ProductIdentity.cacheFolderName(forBundleIdentifier: bundleID, info: nil)
        == "Shaar Engine Preview")
  }
}
