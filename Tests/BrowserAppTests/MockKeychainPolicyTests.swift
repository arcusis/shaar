// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import ChromiumBridge
import Foundation
import Testing

@Suite struct MockKeychainPolicyTests {
  @Test func requestRequiresAnAdHocSignature() {
    #expect(ARCMockKeychainEnabled(true, true))
    #expect(!ARCMockKeychainEnabled(true, false))
    #expect(!ARCMockKeychainEnabled(false, true))
    #expect(!ARCMockKeychainEnabled(false, false))
  }

  @Test func adHocBundleQualifiesAndUnsignedDoesNot() throws {
    let signed = try FixtureApp.make(sign: true)
    defer { signed.remove() }
    let unsigned = try FixtureApp.make(sign: false)
    defer { unsigned.remove() }
    let signedBundle = try #require(Bundle(url: signed.root))
    let unsignedBundle = try #require(Bundle(url: unsigned.root))
    #expect(ARCBundleIsAdHocSigned(signedBundle))
    #expect(!ARCBundleIsAdHocSigned(unsignedBundle))
  }

  @Test func appleSignedBundleIsNotAdHoc() throws {
    let source = URL(fileURLWithPath: "/System/Applications/Calculator.app")
    guard FileManager.default.fileExists(atPath: source.path) else { return }
    let copy = FileManager.default.temporaryDirectory
      .appending(path: "shaar-apple-signed-\(UUID().uuidString).app", directoryHint: .isDirectory)
    try FileManager.default.copyItem(at: source, to: copy)
    defer { try? FileManager.default.removeItem(at: copy) }
    let bundle = try #require(Bundle(url: copy))
    #expect(!ARCBundleIsAdHocSigned(bundle))
  }

  @Test func certificateSignedBundleIsNotAdHocWhenIdentityIsAvailable() throws {
    let identities = try runOutput(
      "/usr/bin/security", ["find-identity", "-v", "-p", "codesigning"])
    guard
      let identity = identities.split(separator: "\n").compactMap({ line -> String? in
        guard line.contains("\"") else { return nil }
        let parts = line.split(separator: "\"")
        return parts.count > 1 ? String(parts[1]) : nil
      }).first
    else { return }

    let fixture = try FixtureApp.make(sign: false)
    defer { fixture.remove() }
    let status = try run("/usr/bin/codesign", ["--force", "--sign", identity, fixture.root.path])
    guard status == 0 else { return }
    let bundle = try #require(Bundle(url: fixture.root))
    #expect(!ARCBundleIsAdHocSigned(bundle))
  }
}

private struct FixtureApp {
  let root: URL

  static func make(sign: Bool) throws -> FixtureApp {
    let root = FileManager.default.temporaryDirectory
      .appending(path: "shaar-mock-keychain-\(UUID().uuidString).app", directoryHint: .isDirectory)
    let macOS = root.appending(path: "Contents/MacOS", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
    let stub = macOS.appending(path: "stub")
    try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: stub)
    _ = try run("/usr/bin/codesign", ["--remove-signature", stub.path])
    let plist = """
      <?xml version="1.0" encoding="UTF-8"?>
      <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
      <plist version="1.0"><dict>
        <key>CFBundleExecutable</key><string>stub</string>
        <key>CFBundleIdentifier</key><string>com.arcusis.test.adhoc</string>
        <key>CFBundleName</key><string>stub</string>
        <key>CFBundlePackageType</key><string>APPL</string>
        <key>CFBundleVersion</key><string>1</string>
        <key>CFBundleShortVersionString</key><string>1.0</string>
      </dict></plist>
      """
    try Data(plist.utf8).write(to: root.appending(path: "Contents/Info.plist"))
    if sign {
      let status = try run("/usr/bin/codesign", ["--force", "--sign", "-", root.path])
      if status != 0 { throw FixtureError.signFailed }
    }
    return FixtureApp(root: root)
  }

  func remove() {
    try? FileManager.default.removeItem(at: root)
  }
}

private enum FixtureError: Error { case signFailed }

@discardableResult
private func run(_ launchPath: String, _ arguments: [String]) throws -> Int32 {
  let process = Process()
  process.executableURL = URL(fileURLWithPath: launchPath)
  process.arguments = arguments
  try process.run()
  process.waitUntilExit()
  return process.terminationStatus
}

private func runOutput(_ launchPath: String, _ arguments: [String]) throws -> String {
  let process = Process()
  let output = Pipe()
  process.executableURL = URL(fileURLWithPath: launchPath)
  process.arguments = arguments
  process.standardOutput = output
  try process.run()
  process.waitUntilExit()
  return String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
}
