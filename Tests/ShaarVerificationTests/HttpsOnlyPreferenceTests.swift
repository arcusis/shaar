// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import ChromiumBridgeVerification
import Foundation
import Testing

@Suite struct HttpsOnlyPreferenceTests {
  private func directory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(
      path: "arcusis-https-only-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    return url
  }

  @Test func writesTheStrictPreferenceAndKeepsOtherKeys() throws {
    let root = try directory()
    defer { try? FileManager.default.removeItem(at: root) }
    let profile = "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE"
    let profileDirectory = root.appending(path: "Profile \(profile.lowercased())")
    try FileManager.default.createDirectory(at: profileDirectory, withIntermediateDirectories: true)
    let preferences = profileDirectory.appending(path: "Preferences")
    try JSONSerialization.data(withJSONObject: ["homepage": "https://example.com"]).write(
      to: preferences)

    #expect(ARCWriteHttpsOnlyPreference(root, profile, true))
    #expect(ARCReadHttpsOnlyPreference(root, profile.lowercased())?.boolValue == true)
    let saved =
      try JSONSerialization.jsonObject(with: Data(contentsOf: preferences))
      as? [String: Any]
    #expect(saved?["homepage"] as? String == "https://example.com")
    #expect(saved?["https_only_mode_enabled"] as? Bool == true)

    let attributes = try FileManager.default.attributesOfItem(atPath: preferences.path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
  }

  @Test func storesAnExplicitOffAndLeavesAMatchingFileUntouched() throws {
    let root = try directory()
    defer { try? FileManager.default.removeItem(at: root) }
    let profile = UUID().uuidString
    #expect(ARCWriteHttpsOnlyPreference(root, profile, false))
    let preferences = root.appending(path: "Profile \(profile.lowercased())/Preferences")
    let original = try Data(contentsOf: preferences)
    #expect(ARCReadHttpsOnlyPreference(root, profile)?.boolValue == false)
    #expect(ARCWriteHttpsOnlyPreference(root, profile, false))
    #expect(try Data(contentsOf: preferences) == original)
  }

  @Test func seedKeepsAStoredOffAndDefaultsOnOnlyWhenUnset() throws {
    let root = try directory()
    defer { try? FileManager.default.removeItem(at: root) }
    let profile = UUID().uuidString
    #expect(ARCWriteHttpsOnlyPreference(root, profile, false))
    let preferences = root.appending(path: "Profile \(profile.lowercased())/Preferences")
    let storedOff = try Data(contentsOf: preferences)

    let kept = ARCSeedHttpsOnlyPreference(root, profile, nil)
    #expect(kept?.boolValue == false)
    #expect(try Data(contentsOf: preferences) == storedOff)

    #expect(ARCSeedHttpsOnlyPreference(root, profile, false)?.boolValue == false)
    #expect(ARCSeedHttpsOnlyPreference(root, profile, true)?.boolValue == true)
    #expect(ARCReadHttpsOnlyPreference(root, profile)?.boolValue == true)

    let fresh = UUID().uuidString
    #expect(ARCSeedHttpsOnlyPreference(root, fresh, nil)?.boolValue == true)
    #expect(ARCReadHttpsOnlyPreference(root, fresh)?.boolValue == true)
    let freshDirectory = root.appending(path: "Profile \(fresh.lowercased())")
    #expect(
      try FileManager.default.contentsOfDirectory(atPath: freshDirectory.path) == [
        "Preferences"
      ])
    #expect(ARCSeedHttpsOnlyPreference(root, "not-a-profile", nil) == nil)
  }

  @Test func refusesAnInvalidProfileAndAnUnreadableFile() throws {
    let root = try directory()
    defer { try? FileManager.default.removeItem(at: root) }
    #expect(!ARCWriteHttpsOnlyPreference(root, "not-a-profile", true))
    #expect(ARCReadHttpsOnlyPreference(root, "not-a-profile") == nil)
    #expect(
      !FileManager.default.fileExists(atPath: root.appending(path: "Profile not-a-profile").path))

    let profile = UUID().uuidString
    let directory = root.appending(path: "Profile \(profile.lowercased())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let preferences = directory.appending(path: "Preferences")
    let corrupt = Data("{not json".utf8)
    try corrupt.write(to: preferences)
    #expect(!ARCWriteHttpsOnlyPreference(root, profile, true))
    #expect(try Data(contentsOf: preferences) == corrupt)
    #expect(ARCReadHttpsOnlyPreference(root, profile) == nil)
  }

  @Test func failedLiveApplyRetriesDiskWhenChoiceRevertsToCachedValue() {
    let profileID = "test-profile"
    let cache = NSMutableDictionary()
    let dirtyProfiles = NSMutableSet()
    cache[profileID] = NSNumber(value: false)
    var diskValue = false
    var applyCalls = 0

    let applied = ARCCommitHttpsOnlyModeChange(
      cache, dirtyProfiles, profileID, true, true,
      { value in
        diskValue = value
        return true
      },
      { _ in
        applyCalls += 1
        return false
      })

    #expect(!applied)
    #expect(diskValue)
    #expect((cache[profileID] as? NSNumber)?.boolValue == false)
    #expect(dirtyProfiles.contains(profileID))

    let reverted = ARCCommitHttpsOnlyModeChange(
      cache, dirtyProfiles, profileID, false, true,
      { value in
        diskValue = value
        return true
      },
      { _ in
        applyCalls += 1
        return true
      })

    #expect(reverted)
    #expect(!diskValue)
    #expect((cache[profileID] as? NSNumber)?.boolValue == false)
    #expect(!dirtyProfiles.contains(profileID))
    #expect(applyCalls == 1)
  }

  @Test func disablesTheHttpsFirstDialogWithoutDroppingOtherState() throws {
    let root = try directory()
    defer { try? FileManager.default.removeItem(at: root) }
    let existing: [String: Any] = [
      "background_mode": ["enabled": false],
      "browser": [
        "enabled_labs_experiments": ["probe@1", "https-first-dialog-ui@1"],
        "keep": "yes",
      ],
    ]
    let localState = root.appending(path: "Local State")
    try JSONSerialization.data(withJSONObject: existing).write(to: localState)

    #expect(ARCDisableHttpsFirstDialog(root))

    let state = try #require(
      JSONSerialization.jsonObject(with: Data(contentsOf: localState)) as? [String: Any])
    let browser = try #require(state["browser"] as? [String: Any])
    #expect(
      browser["enabled_labs_experiments"] as? [String] == [
        "probe@1", "https-first-dialog-ui@2",
      ])
    #expect(browser["keep"] as? String == "yes")
    #expect((state["background_mode"] as? [String: Any])?["enabled"] as? Bool == false)

    let settled = try Data(contentsOf: localState)
    #expect(ARCDisableHttpsFirstDialog(root))
    #expect(try Data(contentsOf: localState) == settled)
  }

  @Test func leavesLocalStateUntouchedWhenTheBrowserEntryIsNotAnObject() throws {
    let root = try directory()
    defer { try? FileManager.default.removeItem(at: root) }
    let original = Data(#"{"browser": "custom"}"#.utf8)
    try original.write(to: root.appending(path: "Local State"))
    #expect(!ARCDisableHttpsFirstDialog(root))
    #expect(try Data(contentsOf: root.appending(path: "Local State")) == original)
  }
}
