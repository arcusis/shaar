// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

public enum ShaarEngineStartupError: Error, Equatable, Sendable {
  case frameworkLoadFailed(String)
}

/// The single app-side owner of the Shaar framework, engine lifecycle, submit
/// export, and event sink. Module ABI transports resolve their entry point from
/// this object so they share its framework lifetime and engine instance.
@MainActor public final class ShaarEngineTransport: ShaarSymbolResolving {
  public let implementation: ShaarEngineImplementation = .shaar
  public let lifecycle: ShaarLifecycleRuntime
  public let submitSymbol: UnsafeRawPointer

  nonisolated private let loader: ShaarEngineLoader
  private var shutDown = false

  private init(
    loader: ShaarEngineLoader,
    lifecycle: ShaarLifecycleRuntime,
    submitSymbol: UnsafeRawPointer
  ) {
    self.loader = loader
    self.lifecycle = lifecycle
    self.submitSymbol = submitSymbol
  }

  nonisolated public func symbol(named: String) -> UnsafeRawPointer? {
    loader.symbol(named: named)
  }

  public static func start(
    frameworkURL: URL,
    dataRoot: URL,
    locale: String,
    onEvent: @escaping @MainActor (ShaarCopiedEvent) -> Void
  ) throws -> ShaarEngineTransport {
    do {
      let loader = try ShaarEngineLoader.load(frameworkURL: frameworkURL, implementation: .shaar)
      guard let submitSymbol = loader.symbol(named: "shaar_submit") else {
        throw ShaarEngineError.missingSymbol("shaar_submit")
      }
      let lifecycle = try ShaarLifecycleRuntime(
        resolver: loader, dataRoot: dataRoot, locale: locale, onEvent: onEvent)
      return ShaarEngineTransport(
        loader: loader, lifecycle: lifecycle, submitSymbol: submitSymbol)
    } catch {
      throw ShaarEngineStartupError.frameworkLoadFailed(String(describing: error))
    }
  }

  /// Lifecycle `run` owns Chromium's run loop. Call it on the app's engine
  /// executor; all module submissions resolve through this transport meanwhile.
  public func run() throws { try lifecycle.run() }

  /// The engine must stop and return from run before release; the framework is
  /// closed last so callbacks and ABI function pointers remain valid. If run is
  /// active, this requests quit; call again once run returns to finish release.
  public func shutdown() throws {
    guard !shutDown else { return }
    if lifecycle.hasRunStarted && !lifecycle.hasRunReturned {
      try lifecycle.requestQuit()
      return
    }
    lifecycle.release()
    loader.closeFramework()
    shutDown = true
  }
}
