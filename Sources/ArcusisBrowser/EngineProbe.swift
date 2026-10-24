import AppKit
import BrowserCore
import ChromiumBridge
import Foundation
import SwiftUI

/// Uses only a marked, disposable directory and an authored loopback fixture.
/// No window is ordered onscreen and no existing browser profiles are opened.
@MainActor
final class EngineProbe {
  private let runtime: ARCChromiumRuntime
  private let root: URL
  private let fixture: URL
  private let phase: String
  private let includeBitwarden: Bool
  private let awaitAbruptTermination: Bool
  private let expectedAfterTermination: BrowserSession?
  private let output: URL
  private var checks: [String] = []
  private var finished = false
  private var passed = false
  private var localFixturesPassed = false
  private var loadedTabs: Set<String> = []
  private let store: BrowserStore
  private var browserEngine: BrowserEngine?
  private var nativeHostProbe: NativeHostProbe?
  private var resultError: Error?
  private var host: NSHostingView<BrowserWindow>?

  private let profileA = "C766672E-AB82-4F84-8ED3-2C6D75AEB1D1"
  private let profileB = "F29A09F3-FAF9-4938-A25B-260F67F42CC3"
  private let tabA = "8EDD2777-1856-499D-A38F-702B0660CA59"
  private let tabB = "B30C0118-3DA8-47D2-B661-D3F0FE3E5F98"
  private let sharedA = "C05629FB-8905-4236-8F72-9336FB84079C"

  private init(
    root: URL, fixture: URL, phase: String, output: URL, includeBitwarden: Bool,
    awaitAbruptTermination: Bool, expectAbruptRecovery: Bool
  ) throws {
    self.root = root
    self.fixture = fixture
    self.phase = phase
    self.includeBitwarden = includeBitwarden
    self.awaitAbruptTermination = awaitAbruptTermination
    expectedAfterTermination =
      expectAbruptRecovery ? try AbruptProbeCheckpoint.expectedSession(root: root) : nil
    self.output = output
    guard let frameworks = Bundle.main.privateFrameworksURL else {
      throw ProbeFailure("Run the probe from the bundled app with its pinned engine.")
    }
    runtime = try ARCChromiumRuntime(
      frameworkURL: frameworks.appending(path: "Chromium Framework.framework"))
    let profiles = [
      BrowserProfile(id: UUID(uuidString: profileA)!, name: "Account Alpha"),
      BrowserProfile(id: UUID(uuidString: profileB)!, name: "Account Beta"),
    ]
    let spaces = [
      BrowserSpace(
        profileID: profiles[0].id, name: "Account Alpha", symbol: "house", tint: .lavender,
        tabs: [BrowserTab(id: UUID(uuidString: tabA)!, url: fixture)]),
      BrowserSpace(
        profileID: profiles[1].id, name: "Account Beta", symbol: "briefcase", tint: .ocean,
        tabs: [BrowserTab(id: UUID(uuidString: tabB)!, url: fixture)]),
      BrowserSpace(
        profileID: profiles[0].id, name: "Shared Alpha", symbol: "square.stack", tint: .forest,
        tabs: [BrowserTab(id: UUID(uuidString: sharedA)!, url: fixture)]),
    ]
    let session = try BrowserSession(
      profiles: profiles, spaces: spaces, selectedSpaceID: spaces[0].id)
    store = BrowserStore(
      sessionFile: SessionFile(url: root.appending(path: "session.json")), session: session)
    if let expectedAfterTermination {
      guard store.session == expectedAfterTermination else {
        throw AbruptCheckpointError.snapshotMismatch
      }
      checks.append(
        "exact saved Space/profile/tab/folder/recovery model restores before native startup after SIGKILL"
      )
    }
  }

  static func run(arguments: [String]) -> Int32 {
    do {
      func value(_ flag: String) throws -> String {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1)
        else { throw ProbeFailure("Missing \(flag)") }
        return arguments[index + 1]
      }
      let root = URL(filePath: try value("--probe-data-dir")).standardizedFileURL
        .resolvingSymlinksInPath()
      let output = URL(filePath: try value("--probe-output")).standardizedFileURL
        .resolvingSymlinksInPath()
      let phase = try value("--probe-phase")
      let temporary = FileManager.default.temporaryDirectory.standardizedFileURL
        .resolvingSymlinksInPath()
      guard root.path.hasPrefix(temporary.path + "/"),
        output.deletingLastPathComponent().path == root.path,
        try String(contentsOf: root.appending(path: ".arcusis-probe"), encoding: .utf8)
          == "arcusis-engine-probe-v1\n",
        ["initial", "restart"].contains(phase),
        let fixture = URL(string: try value("--probe-url")), fixture.scheme == "http",
        fixture.host() == "127.0.0.1", fixture.port != nil
      else {
        throw ProbeFailure("Probe requires a marked temporary directory and loopback fixture.")
      }
      let includeBitwarden = arguments.contains("--bitwarden")
      let awaitAbruptTermination = arguments.contains("--probe-await-abrupt-termination")
      let expectAbruptRecovery = arguments.contains("--probe-expect-abrupt-recovery")
      guard !(awaitAbruptTermination && expectAbruptRecovery),
        !awaitAbruptTermination || (phase == "initial" && !includeBitwarden),
        !expectAbruptRecovery || (phase == "restart" && !includeBitwarden)
      else { throw ProbeFailure("Invalid abrupt-recovery probe flags.") }
      let probe = try EngineProbe(
        root: root, fixture: fixture, phase: phase, output: output,
        includeBitwarden: includeBitwarden, awaitAbruptTermination: awaitAbruptTermination,
        expectAbruptRecovery: expectAbruptRecovery)
      probe.runtime.onReady = { [weak probe] in
        guard let probe else { return }
        Task {
          do {
            try probe.attachNativeShell()
            await probe.exercise()
          } catch {
            probe.finish(error: error)
          }
        }
      }
      // A bounded test must fail even if a renderer never calls its completion.
      DispatchQueue.main.asyncAfter(deadline: .now() + (includeBitwarden ? 150 : 75)) {
        [weak probe] in
        probe?.finish(error: ProbeFailure("Engine probe timed out."))
      }
      let code = probe.runtime.run(
        withDataDirectory: root.appending(path: "Chromium"), testing: true)
      probe.auditNativeHostShutdown()
      return probe.passed ? code : 1
    } catch {
      FileHandle.standardError.write(
        Data("Engine probe failed: \(error.localizedDescription)\n".utf8))
      return 1
    }
  }

  private func attachNativeShell() throws {
    browserEngine = try BrowserEngine(
      events: BrowserRuntimeEvents(runtime: runtime), store: store, presentsNativePanels: false)
    let changed = runtime.onTabChanged
    runtime.onTabChanged = { [weak self] id, url, title, loading, back, forward in
      changed?(id, url, title, loading, back, forward)
      guard let self else { return }
      if !loading && url == self.fixture.absoluteString { self.loadedTabs.insert(id) }
    }
    guard let content = runtime.hostView else { return }
    let host = NSHostingView(rootView: BrowserWindow(store: store))
    host.frame = content.bounds
    host.autoresizingMask = [.width, .height]
    content.addSubview(host)
    self.host = host
    browserEngine?.reconcile()
  }

  private func load(_ id: String) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      runtime.loadProfileID(id) { error in
        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
      }
    }
  }

  private func evaluate(_ tab: String, _ script: String) async throws -> Any {
    let json: String? = await withCheckedContinuation { continuation in
      runtime.evaluate(inTabID: tab, script: script) { continuation.resume(returning: $0) }
    }
    guard let json, let data = json.data(using: .utf8) else {
      throw ProbeFailure("JavaScript evaluation failed for \(tab).")
    }
    return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
  }

  private func snapshot(_ tab: String) async throws -> [String: Any] {
    let script = """
      ({fixture:document.documentElement.dataset.arcusisFixture,
        cookie:document.cookie, local:localStorage.getItem('account'),
        session:sessionStorage.getItem('account'), instance:window.arcusisInstance})
      """
    for _ in 0..<80 {
      if !loadedTabs.contains(tab) {
        try await Task.sleep(for: .milliseconds(100))
        continue
      }
      if let result = try? await evaluate(tab, script) as? [String: Any],
        result["fixture"] as? String == "v1"
      {
        return result
      }
      try await Task.sleep(for: .milliseconds(100))
    }
    throw ProbeFailure("Loopback fixture did not load in \(tab).")
  }

  private func expect(_ condition: Bool, _ name: String) throws {
    guard condition else { throw ProbeFailure(name) }
    checks.append(name)
  }

  private func exercise() async {
    do {
      try await load(profileA)
      try await load(profileB)
      try runtime.openTabID(tabA, profileID: profileA, url: fixture.absoluteString)
      try runtime.openTabID(tabB, profileID: profileB, url: fixture.absoluteString)
      let firstA = try await snapshot(tabA)
      let firstB = try await snapshot(tabB)
      if let expectedAfterTermination {
        let tabs = expectedAfterTermination.spaces.flatMap(\.tabs)
        var ready = false
        for _ in 0..<100 {
          ready = tabs.allSatisfy {
            runtime.nativeTabID(forID: $0.id.uuidString) >= 0
              && browserEngine?.pages[$0.id]?.loading == false
          }
          if ready { break }
          try await Task.sleep(for: .milliseconds(100))
        }
        let nativeIDs = tabs.map { runtime.nativeTabID(forID: $0.id.uuidString) }
        try expect(
          ready && Set(nativeIDs).count == tabs.count,
          "every saved tab gets a distinct live native tab after abrupt browser termination")
        try expect(
          AbruptProbeCheckpoint.matchesAfterNavigation(
            store.session, expected: expectedAfterTermination),
          "native startup retains saved profile/Space ownership, ordering, pins, folders, selection, and closed entries after SIGKILL"
        )
      }
      if phase == "initial" {
        try expect(
          firstA["local"] is NSNull && firstB["local"] is NSNull, "fresh profiles have no account")
        for (tab, account) in [(tabA, "alpha"), (tabB, "beta")] {
          _ = try await evaluate(
            tab,
            """
            (() => {
            document.cookie='account=\(account); Path=/; Max-Age=86400; SameSite=Lax';
            localStorage.setItem('account','\(account)');
            sessionStorage.setItem('account','\(account)'); return true;
            })()
            """)
          if tab == tabA {
            let untouchedB = try await snapshot(tabB)
            try expect(
              untouchedB["cookie"] as? String == "" && untouchedB["local"] is NSNull,
              "profile A sign-in leaves profile B empty")
          }
        }
        try runtime.openTabID(sharedA, profileID: profileA, url: fixture.absoluteString)
        let shared = try await snapshot(sharedA)
        try expect(
          shared["cookie"] as? String == "account=alpha" && shared["local"] as? String == "alpha"
            && shared["session"] is NSNull,
          "explicitly shared profile shares account storage with a separate tab session")
        var rejected = false
        do { try runtime.openTabID(tabA, profileID: profileB, url: fixture.absoluteString) } catch {
          rejected = true
        }
        try expect(rejected, "live tab cannot be reassigned to another profile")
      }
      for iteration in 0..<20 {
        let isA = iteration.isMultiple(of: 2)
        let tab = isA ? tabA : tabB
        let account = isA ? "alpha" : "beta"
        guard
          let space = store.session.spaces.first(where: {
            $0.tabs.contains { $0.id.uuidString == tab }
          })
        else { throw ProbeFailure("Native tab lost its owning space.") }
        store.perform(.space(space.id))
        try expect(
          store.session.selectedSpace.selectedTabID?.uuidString == tab
            && store.session.selectedSpace.profileID.uuidString == (isA ? profileA : profileB),
          "\(phase) switch \(iteration + 1) selects the correct native space and profile")
        let state = try await snapshot(tab)
        let original = isA ? firstA : firstB
        let retainsAccountAndDocument =
          state["cookie"] as? String == "account=\(account)"
          && state["local"] as? String == account
          && state["instance"] as? String == original["instance"] as? String
        if !retainsAccountAndDocument {
          try JSONSerialization.data(
            withJSONObject: [
              "phase": phase, "iteration": iteration + 1, "tabID": tab,
              "profileID": isA ? profileA : profileB,
              "expectedAccount": account, "original": original, "observed": state,
              "scope":
                "Failure-only snapshot of authored disposable account fixture. No real credentials.",
            ], options: [.prettyPrinted, .sortedKeys]
          ).write(to: root.appending(path: "\(phase)-account-failure.json"), options: .atomic)
        }
        try expect(
          retainsAccountAndDocument,
          "\(phase) switch \(iteration + 1) retains isolated account and live document")
        try expect(
          phase == "initial"
            ? state["session"] as? String == account : state["session"] is NSNull,
          "\(phase) switch \(iteration + 1) has expected tab session storage")
      }
      let profileIDs = store.session.profiles.map(\.id)
      let restored = BrowserStore(
        sessionFile: SessionFile(url: root.appending(path: "session.json")))
      try expect(
        restored.session.profiles.map(\.id) == profileIDs,
        "profile identities survive session restore")
      try expect(
        store.storageNotice == nil && browserEngine?.notice == nil,
        "native shell and engine report no storage errors")
      store.perform(.space(store.session.spaces[0].id))
      try await Task.sleep(for: .milliseconds(200))
      let picture: Data? = await withCheckedContinuation { continuation in
        runtime.captureProbeTabID(tabA) { continuation.resume(returning: $0) }
      }
      try expect(picture != nil, "Chromium captures the authored fixture without a visible window")
      try picture?.write(to: root.appending(path: "\(phase)-page.png"), options: .atomic)
      try renderShell(name: "\(phase)-native.png")
      store.showCommand()
      try await Task.sleep(for: .milliseconds(200))
      try renderShell(name: "\(phase)-command.png")
      store.dismissCommand()
      if let browserEngine {
        checks += try await ExtensionProbe(
          runtime: runtime, engine: browserEngine, store: store,
          root: root, phase: phase
        ).run()
        checks += try await PageFindProbe(
          runtime: runtime, store: store, root: root, phase: phase
        ).run()
        checks += try await MediaPermissionProbe(
          runtime: runtime, engine: browserEngine, store: store,
          root: root, phase: phase
        ).run()
        checks += try await DownloadProbe(
          runtime: runtime, engine: browserEngine, store: store, root: root, phase: phase
        ).run()
        checks += try await OrderingProbe(
          runtime: runtime, engine: browserEngine, store: store, root: root, phase: phase
        ).run()
        checks += try await FolderProbe(
          runtime: runtime, engine: browserEngine, store: store, root: root, phase: phase
        ).run()
        checks += try await ReopenProbe(
          runtime: runtime, engine: browserEngine, store: store, root: root, phase: phase
        ).run()
        checks += try await LibraryProbe(
          runtime: runtime, engine: browserEngine, store: store, root: root, fixture: fixture,
          phase: phase
        ).run()
        checks += try await RendererRecoveryProbe(
          runtime: runtime, engine: browserEngine, store: store, root: root, fixture: fixture,
          phase: phase
        ).run()
        checks += try await NativeWindowProbe(
          runtime: runtime, engine: browserEngine, store: store, root: root, fixture: fixture,
          phase: phase
        ).run()
        checks += try await WindowClientProbe(
          primary: browserEngine, store: store, root: root, fixture: fixture, phase: phase
        ).run()
        checks += try await NativeSelectionProbe(
          primary: browserEngine, store: store, root: root, fixture: fixture, phase: phase
        ).run()
        checks += try await WorkspaceProbe(
          primary: browserEngine, store: store, root: root, fixture: fixture, phase: phase
        ).run()
        let nativeHost = try NativeHostProbe(
          primary: browserEngine, store: store, root: root, fixture: fixture, phase: phase)
        nativeHostProbe = nativeHost
        checks += try await nativeHost.run()
        localFixturesPassed = true
        if includeBitwarden {
          checks += try await BitwardenProbe(
            runtime: runtime, engine: browserEngine, store: store,
            root: root, fixture: fixture, phase: phase
          ).run()
        }
      }
      if awaitAbruptTermination {
        try expect(
          try SessionFile(url: root.appending(path: "session.json")).load() == store.session,
          "pre-termination checkpoint matches the last completed session save")
        try AbruptProbeCheckpoint.record(
          root: root, session: store.session, checks: checks,
          chromiumVersion: runtime.chromiumVersion)
        // Keep the real engine loop alive. The parent must observe readiness and SIGKILL this owned process group.
        return
      }
      // Allow Chromium's normal persistent-cookie transaction to commit before graceful shutdown.
      try await Task.sleep(for: .seconds(2))
      finish(error: nil)
    } catch { finish(error: error) }
  }

  private func renderShell(name: String) throws {
    guard let host else { throw ProbeFailure("Native shell is missing.") }
    host.layoutSubtreeIfNeeded()
    guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
      throw ProbeFailure("Native shell could not create an offscreen bitmap.")
    }
    host.cacheDisplay(in: host.bounds, to: bitmap)
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
      throw ProbeFailure("Native shell could not encode its preview.")
    }
    try png.write(to: root.appending(path: name), options: .atomic)
  }

  private func finish(error: Error?) {
    guard !finished else { return }
    finished = true
    resultError = error
    do { try nativeHostProbe?.prepareForQuit() } catch {
      resultError = ProbeFailure(
        "\(resultError?.localizedDescription ?? "") Host quit snapshot: \(error.localizedDescription)"
      )
      localFixturesPassed = false
    }
    passed = resultError == nil
    writeReport()
    runtime.quit()
  }

  private func auditNativeHostShutdown() {
    guard localFixturesPassed else { return }
    do { checks += try nativeHostProbe?.auditAfterQuit() ?? [] } catch {
      resultError = ProbeFailure(
        "\(resultError?.localizedDescription ?? "") Host shutdown audit: \(error.localizedDescription)"
      )
      passed = false
      localFixturesPassed = false
    }
    writeReport()
  }

  private func writeReport() {
    let report: [String: Any] = [
      "phase": phase, "passed": passed, "chromiumVersion": runtime.chromiumVersion,
      "bitwardenStoreProbe": includeBitwarden,
      "abruptRecoveryProbe": expectedAfterTermination != nil,
      "localFixturesPassed": localFixturesPassed,
      "checks": checks, "error": resultError?.localizedDescription as Any? ?? NSNull(),
      "scope":
        includeBitwarden
        ? "Disposable fixtures plus a real Bitwarden store probe. See separate Bitwarden reports for passed and failed stages. No vault or Workspace credentials entered."
        : "Disposable account and component-loaded MV3 fixtures. Store installation, Google Workspace and Bitwarden are not tested."
        ,
    ]
    do {
      try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        .write(to: output, options: .atomic)
    } catch {
      passed = false
      FileHandle.standardError.write(
        Data("Probe report failed: \(error.localizedDescription)\n".utf8))
    }
  }
}

private struct ProbeFailure: LocalizedError {
  let message: String
  init(_ message: String) { self.message = message }
  var errorDescription: String? { message }
}
