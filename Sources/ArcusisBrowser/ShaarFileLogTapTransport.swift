// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import Foundation

struct ShaarFileLogTapTransport: ShaarLocalConsoleTransport {
  let sourceID = "fileLogTap"
  let origin: ShaarConsoleEvent.Origin = .server
  let file: URL

  func messages(for target: SiteControlTarget) -> AsyncStream<ShaarLocalConsoleMessage> {
    guard DevelopmentModePreference.isEnabled,
      DevelopmentPage.detect(url: target.url).isDevelopmentPage,
      file.isFileURL
    else { return AsyncStream { $0.finish() } }
    return AsyncStream { continuation in
      let task = Task { await tail(continuation: continuation) }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  private func tail(continuation: AsyncStream<ShaarLocalConsoleMessage>.Continuation) async {
    let scoped = file.startAccessingSecurityScopedResource()
    defer { if scoped { file.stopAccessingSecurityScopedResource() } }
    guard FileManager.default.isReadableFile(atPath: file.path) else {
      continuation.yield(.unavailable)
      continuation.finish()
      return
    }
    continuation.yield(.available)
    var reader = ShaarLocalLogReader(file: file)
    do {
      while !Task.isCancelled {
        guard FileManager.default.fileExists(atPath: file.path) else {
          continuation.yield(.unavailable)
          break
        }
        for line in try reader.readLines() {
          continuation.yield(
            .event(
              ShaarConsoleEvent(
                id: UUID(), level: .log, message: String(line.prefix(4_096)),
                source: file.lastPathComponent, origin: .server)))
        }
        try await Task.sleep(for: .milliseconds(250))
      }
    } catch is CancellationError {
      // The user disconnected the tap or the tab changed.
    } catch {
      continuation.yield(.unavailable)
    }
    continuation.finish()
  }
}
