import BrowserCore
import Foundation

/// Evidence for an opt-in fault test. These files never repair or replace the live session.
enum AbruptProbeCheckpoint {
  static let snapshotName = "pre-abrupt-session.json"
  static let readyName = "ready-for-abrupt-termination.json"

  static func record(root: URL, session: BrowserSession, checks: [String], chromiumVersion: String)
    throws
  {
    guard try SessionFile(url: root.appending(path: "session.json")).load() == session else {
      throw AbruptCheckpointError.snapshotMismatch
    }
    try SessionFile(url: root.appending(path: snapshotName)).save(session)
    try JSONSerialization.data(
      withJSONObject: [
        "schema": 1, "ready": true, "phase": "initial",
        "pid": ProcessInfo.processInfo.processIdentifier, "localFixturesPassed": true,
        "expectedSnapshot": snapshotName, "chromiumVersion": chromiumVersion, "checks": checks,
        "scope":
          "Ready for parent-controlled termination. This is not a completed process or recovery result.",
      ], options: [.prettyPrinted, .sortedKeys]
    ).write(to: root.appending(path: readyName), options: .atomic)
  }

  static func expectedSession(root: URL) throws -> BrowserSession {
    guard let expected = try SessionFile(url: root.appending(path: snapshotName)).load(),
      let saved = try SessionFile(url: root.appending(path: "session.json")).load(),
      saved == expected
    else { throw AbruptCheckpointError.snapshotMismatch }
    return expected
  }

  static func matchesAfterNavigation(_ current: BrowserSession, expected: BrowserSession) -> Bool {
    guard current.profiles == expected.profiles,
      current.selectedSpaceID == expected.selectedSpaceID,
      current.closedTabs == expected.closedTabs, current.spaces.count == expected.spaces.count
    else { return false }
    for (actual, saved) in zip(current.spaces, expected.spaces) {
      guard actual.tabs.count == saved.tabs.count else { return false }
      var normalized = actual
      for index in normalized.tabs.indices {
        // A restored page can publish a new title. Its identity, URL, placement, and ownership must survive.
        normalized.tabs[index].title = saved.tabs[index].title
      }
      guard normalized == saved else { return false }
    }
    return true
  }
}

enum AbruptCheckpointError: Error, LocalizedError {
  case snapshotMismatch
  var errorDescription: String? {
    "The saved session does not match the pre-termination checkpoint."
  }
}
