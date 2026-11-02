// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import Darwin
import Foundation

enum BrowserRestart {
  static let restoreArgument = "--restore-after-language-change"

  static func startsFresh(defaults: UserDefaults = .standard, arguments: [String]) -> Bool {
    defaults.bool(forKey: "settingsStartFresh") && !arguments.contains(restoreArgument)
  }

  @MainActor static func prepare(
    workspace: BrowserWorkspaceStore, defaults: UserDefaults = .standard,
    flushGeometry: () -> Void
  ) throws {
    flushGeometry()
    guard workspace.persistSnapshot() else { throw CocoaError(.fileWriteUnknown) }
    try workspace.flushSaves()
    guard defaults.synchronize() else { throw CocoaError(.fileWriteUnknown) }
  }

  /// Called only after the native runtime and workspace lock have been released.
  /// Replacing this process avoids Launch Services reusing the exiting instance.
  static func relaunch() -> Never {
    guard let executable = Bundle.main.executableURL else { exit(1) }
    let launchArguments = [executable.path, restoreArgument]
    let arguments = launchArguments.map { argument in
      argument.withCString { strdup($0) }
    }
    defer {
      for argument in arguments { free(argument) }
    }
    var argv = arguments + [nil]
    _ = execv(executable.path, &argv)
    FileHandle.standardError.write(Data("Could not restart Shaar (errno \(errno)).\n".utf8))
    exit(1)
  }
}
