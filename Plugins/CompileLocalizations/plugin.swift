// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import PackagePlugin

@main
struct CompileLocalizations: BuildToolPlugin {
  func createBuildCommands(context: PluginContext, target: Target) async throws -> [Command] {
    guard target.name == "BrowserCore" else { return [] }
    let output = context.pluginWorkDirectoryURL.appending(path: "localizations")
    let script = context.package.directoryURL.appending(path: "scripts/compile-localizations.py")
    return [
      .prebuildCommand(
        displayName: "Validate and compile string catalogs",
        executable: URL(fileURLWithPath: "/usr/bin/env"),
        arguments: ["python3", script.path, context.package.directoryURL.path, output.path],
        outputFilesDirectory: output)
    ]
  }
}
