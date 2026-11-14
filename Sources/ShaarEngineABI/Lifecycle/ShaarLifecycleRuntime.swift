// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Darwin
import Foundation

@usableFromInline @frozen struct ShaarLifecycleConfig {
  @usableFromInline var size: UInt32
  @usableFromInline var requestedMajor: UInt32
  @usableFromInline var requestedMinor: UInt32
  @usableFromInline var dataRoot: ShaarBytes
  @usableFromInline var locale: ShaarBytes
  @usableFromInline var onEvent: ShaarEventCallback?
  @usableFromInline var eventContext: UnsafeMutableRawPointer?
}

@usableFromInline @frozen struct ShaarLifecycleError {
  @usableFromInline var size: UInt32
  @usableFromInline var code: UInt32
  @usableFromInline var platformCode: Int32
  @usableFromInline var message: ShaarBytes
}

@usableFromInline typealias ShaarEventCallback =
  @convention(c) (
    UnsafeMutableRawPointer?, UnsafeRawPointer?
  ) -> Void
@usableFromInline typealias ShaarCreateFunction =
  @convention(c) (
    UnsafeRawPointer?, UnsafeMutablePointer<OpaquePointer?>?, UnsafeMutableRawPointer?
  ) -> UInt32
@usableFromInline typealias ShaarRunFunction =
  @convention(c) (
    OpaquePointer?, UnsafeMutableRawPointer?
  ) -> UInt32
@usableFromInline typealias ShaarRequestQuitFunction =
  @convention(c) (
    OpaquePointer?, UnsafeMutableRawPointer?
  ) -> UInt32
@usableFromInline typealias ShaarReleaseFunction = @convention(c) (OpaquePointer?) -> Void

private struct LifecycleFrameworkSymbols: ShaarSymbolResolving {
  let handle: UnsafeMutableRawPointer
  func symbol(named: String) -> UnsafeRawPointer? {
    dlsym(handle, named).map(UnsafeRawPointer.init)
  }
}

private func lifecycleErrorMessage(_ bytes: ShaarBytes) throws -> String {
  guard bytes.size >= 0, bytes.size == 0 || bytes.data != nil else {
    throw ShaarEngineError.invalidEvent("invalid lifecycle error message slice")
  }
  guard let data = bytes.data, bytes.size > 0 else { return "" }
  return data.withMemoryRebound(to: UInt8.self, capacity: bytes.size) {
    String(decoding: UnsafeBufferPointer(start: $0, count: bytes.size), as: UTF8.self)
  }
}

private func receiveShaarEvent(
  _ context: UnsafeMutableRawPointer?, _ event: UnsafeRawPointer?
) {
  guard let context, let event else { return }
  Unmanaged<ShaarEventDispatcher>.fromOpaque(context).takeUnretainedValue()
    .receive(event.assumingMemoryBound(to: ShaarABIEvent.self).pointee)
}

/// Owns the lifecycle ABI handles. `release()` must follow run return so Chromium-owned callbacks
/// and process globals cannot outlive the loaded framework.
@MainActor public final class ShaarLifecycleRuntime {
  public let implementation: ShaarEngineImplementation = .shaar
  public static let abiMinor: UInt32 = 0

  private let createFunction: ShaarCreateFunction
  private let runFunction: ShaarRunFunction
  private let requestQuitFunction: ShaarRequestQuitFunction
  private let releaseFunction: ShaarReleaseFunction
  private let eventDispatcher: ShaarEventDispatcher
  private var engine: OpaquePointer?
  private var frameworkHandle: UnsafeMutableRawPointer?
  private var hasRun = false
  private var runReturned = false
  public var hasRunStarted: Bool { hasRun }
  public var hasRunReturned: Bool { runReturned }

  public init(
    resolver: ShaarSymbolResolving,
    dataRoot: URL,
    locale: String,
    onEvent: @escaping @MainActor (ShaarCopiedEvent) -> Void
  ) throws {
    func required(_ name: String) throws -> UnsafeRawPointer {
      guard let address = resolver.symbol(named: name) else {
        throw ShaarEngineError.missingSymbol(name)
      }
      return address
    }

    let majorAddress = try required("shaar_abi_major")
    let minorAddress = try required("shaar_abi_minor")
    let createAddress = try required("shaar_engine_create")
    let runAddress = try required("shaar_engine_run")
    let quitAddress = try required("shaar_engine_request_quit")
    let releaseAddress = try required("shaar_engine_release")
    let submitAddress = try required("shaar_submit")
    let cancelAddress = try required("shaar_cancel_request")
    _ = (submitAddress, cancelAddress)

    let major = unsafeBitCast(majorAddress, to: (@convention(c) () -> UInt32).self)()
    let minor = unsafeBitCast(minorAddress, to: (@convention(c) () -> UInt32).self)()
    guard major == ShaarEngineLoader.abiMajor else {
      throw ShaarEngineError.unsupportedABI(expected: ShaarEngineLoader.abiMajor, actual: major)
    }
    _ = minor  // Higher minor versions are backward-compatible; request our known prefix.

    createFunction = unsafeBitCast(createAddress, to: ShaarCreateFunction.self)
    runFunction = unsafeBitCast(runAddress, to: ShaarRunFunction.self)
    requestQuitFunction = unsafeBitCast(quitAddress, to: ShaarRequestQuitFunction.self)
    releaseFunction = unsafeBitCast(releaseAddress, to: ShaarReleaseFunction.self)
    eventDispatcher = ShaarEventDispatcher(handler: onEvent)

    let root = dataRoot.standardizedFileURL.path
    var createdEngine: OpaquePointer?
    var error = ShaarLifecycleError(
      size: UInt32(MemoryLayout<ShaarLifecycleError>.size), code: 0, platformCode: 0,
      message: ShaarBytes(data: nil, size: 0))
    let result = root.withCString { rootCString in
      locale.withCString { localeCString in
        let config = ShaarLifecycleConfig(
          size: UInt32(MemoryLayout<ShaarLifecycleConfig>.size),
          requestedMajor: ShaarEngineLoader.abiMajor, requestedMinor: Self.abiMinor,
          dataRoot: ShaarBytes(data: rootCString, size: root.utf8.count),
          locale: ShaarBytes(data: localeCString, size: locale.utf8.count),
          onEvent: receiveShaarEvent,
          eventContext: Unmanaged.passUnretained(eventDispatcher).toOpaque())
        return withUnsafePointer(to: config) { configPointer in
          withUnsafeMutablePointer(to: &error) { errorPointer in
            createFunction(
              UnsafeRawPointer(configPointer), &createdEngine,
              UnsafeMutableRawPointer(errorPointer))
          }
        }
      }
    }
    try Self.decode(result, error: error)
    guard let createdEngine else {
      throw ShaarEngineError.status(
        .chromiumError, platformCode: 0,
        message: "engine create returned no handle")
    }
    engine = createdEngine
  }

  public convenience init(
    frameworkURL: URL,
    dataRoot: URL,
    locale: String,
    onEvent: @escaping @MainActor (ShaarCopiedEvent) -> Void
  ) throws {
    let binary = frameworkURL.appending(path: "Versions/Current/Chromium Framework")
    guard let handle = dlopen(binary.path, RTLD_NOW | RTLD_LOCAL) else {
      throw ShaarEngineError.missingSymbol(String(cString: dlerror()))
    }
    do {
      try self.init(
        resolver: LifecycleFrameworkSymbols(handle: handle), dataRoot: dataRoot,
        locale: locale, onEvent: onEvent)
      frameworkHandle = handle
    } catch {
      dlclose(handle)
      throw error
    }
  }

  public func run() throws {
    guard let engine else {
      throw ShaarEngineError.status(.notReady, platformCode: 0, message: "engine is released")
    }
    guard !hasRun else {
      throw ShaarEngineError.status(.conflict, platformCode: 0, message: "engine run is single-use")
    }
    hasRun = true
    var error = Self.emptyError()
    let result = withUnsafeMutablePointer(to: &error) {
      runFunction(engine, UnsafeMutableRawPointer($0))
    }
    runReturned = true
    try Self.decode(result, error: error)
  }

  public func requestQuit() throws {
    guard let engine, hasRun, !runReturned else {
      throw ShaarEngineError.status(.notReady, platformCode: 0, message: "engine is not running")
    }
    var error = Self.emptyError()
    let result = withUnsafeMutablePointer(to: &error) {
      requestQuitFunction(engine, UnsafeMutableRawPointer($0))
    }
    try Self.decode(result, error: error)
  }

  public func release() {
    guard runReturned || !hasRun else { return }
    if let engine {
      releaseFunction(engine)
      self.engine = nil
    }
    if let frameworkHandle {
      dlclose(frameworkHandle)
      self.frameworkHandle = nil
    }
  }

  private static func emptyError() -> ShaarLifecycleError {
    ShaarLifecycleError(
      size: UInt32(MemoryLayout<ShaarLifecycleError>.size), code: 0,
      platformCode: 0, message: ShaarBytes(data: nil, size: 0))
  }

  private static func decode(_ result: UInt32, error: ShaarLifecycleError) throws {
    guard error.size >= UInt32(MemoryLayout<ShaarLifecycleError>.size) else {
      throw ShaarEngineError.invalidEvent("short lifecycle error struct")
    }
    let code = result == 0 ? error.code : result
    try ShaarStatusCode.decode(
      code, platformCode: error.platformCode, message: try lifecycleErrorMessage(error.message))
  }
}
