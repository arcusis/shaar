// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

@MainActor
final class LocalConsoleFixtureServer {
  let port: Int
  private let process: Process

  init(script: String) throws {
    let path = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appending(path: "Tests/Fixtures/LocalConsole/\(script)").path
    let pipe = Pipe()
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    process.arguments = [path]
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    try process.run()
    self.process = process
    let data = pipe.fileHandleForReading.availableData
    guard
      let port = Int(
        String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    else {
      process.terminate()
      throw URLError(.cannotParseResponse)
    }
    self.port = port
  }

  func stop() {
    guard process.isRunning else { return }
    process.terminate()
    process.waitUntilExit()
  }

  deinit { if process.isRunning { process.terminate() } }
}
