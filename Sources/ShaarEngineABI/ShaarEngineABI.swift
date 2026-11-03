// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Darwin
import Foundation

/// Step 0 deliberately leaves shipping builds on the existing ChromiumBridge path.
public enum ShaarEngineImplementation: Equatable, Sendable {
  case ardia
  case shaar

  public static let shippingDefault: Self = .ardia

  /// Shaar is opt-in for debug and source-engine CI runs. Release builds always
  /// retain Ardia unless a caller explicitly constructs a test transport.
  public static func selected(
    debugSetting: String? = nil,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    isDebug: Bool = _isDebugAssertConfiguration()
  ) -> Self {
    guard isDebug else { return .shippingDefault }
    return (debugSetting ?? environment["SHAAR_ENGINE_IMPLEMENTATION"]) == "shaar" ? .shaar : .ardia
  }
}

public enum ShaarEngineError: Error, Equatable, Sendable {
  case missingSymbol(String)
  case unsupportedABI(expected: UInt32, actual: UInt32)
  case invalidStatusCode(UInt32)
  case invalidEvent(String)
  case status(ShaarStatusCode, platformCode: Int32, message: String)
}

/// Numeric values are fixed by Design/shaar_engine.h and are never inferred from text.
public enum ShaarStatusCode: UInt32, CaseIterable, Sendable {
  case ok = 0
  case invalidArgument = 1
  case unsupportedABI = 2
  case notReady = 3
  case notFound = 4
  case wrongProfile = 5
  case wrongSession = 6
  case privateDisallowed = 7
  case policyBlocked = 8
  case permissionDenied = 9
  case conflict = 10
  case cancelled = 11
  case ioError = 12
  case chromiumError = 13
  case shuttingDown = 14
  case unsupportedCapability = 15
}

public struct ShaarCopiedEvent: Equatable, Sendable {
  public let sequence: UInt64
  public let kind: UInt32
  public let profileID: Data
  public let sessionID: Data
  public let windowID: Data
  public let tabID: Data
  public let payloadJSON: Data

  public init(
    sequence: UInt64, kind: UInt32, profileID: Data, sessionID: Data,
    windowID: Data, tabID: Data, payloadJSON: Data
  ) {
    self.sequence = sequence
    self.kind = kind
    self.profileID = profileID
    self.sessionID = sessionID
    self.windowID = windowID
    self.tabID = tabID
    self.payloadJSON = payloadJSON
  }
}

/// Public layout mirrors the size-prefixed v1 ABI event, while exposing only copied data.
@frozen public struct ShaarBytes {
  public var data: UnsafePointer<CChar>?
  public var size: Int
  public init(data: UnsafePointer<CChar>?, size: Int) {
    self.data = data
    self.size = size
  }
}

@frozen public struct ShaarABIEvent {
  public var size: UInt32
  public var sequence: UInt64
  public var kind: UInt32
  public var profileID: ShaarBytes
  public var sessionID: ShaarBytes
  public var windowID: ShaarBytes
  public var tabID: ShaarBytes
  public var payloadJSON: ShaarBytes
}

private func copyBytes(_ bytes: ShaarBytes, field: String) throws -> Data {
  guard bytes.size >= 0, bytes.size == 0 || bytes.data != nil else {
    throw ShaarEngineError.invalidEvent("invalid \(field) slice")
  }
  guard let pointer = bytes.data, bytes.size > 0 else { return Data() }
  return Data(bytes: pointer, count: bytes.size)
}

public enum ShaarEventCopy {
  public static func copy(_ event: ShaarABIEvent) throws -> ShaarCopiedEvent {
    let requiredSize = UInt32(MemoryLayout<ShaarABIEvent>.size)
    guard event.size >= requiredSize else {
      throw ShaarEngineError.invalidEvent("short event struct")
    }
    let profile = try copyBytes(event.profileID, field: "profile ID")
    let session = try copyBytes(event.sessionID, field: "session ID")
    if event.kind != 1 && profile.isEmpty {
      throw ShaarEngineError.invalidEvent("profile-scoped event has no profile ID")
    }
    return ShaarCopiedEvent(
      sequence: event.sequence, kind: event.kind, profileID: profile,
      sessionID: session,
      windowID: try copyBytes(event.windowID, field: "window ID"),
      tabID: try copyBytes(event.tabID, field: "tab ID"),
      payloadJSON: try copyBytes(event.payloadJSON, field: "payload JSON"))
  }
}

@MainActor public final class ShaarEventDispatcher {
  private let handler: @MainActor (ShaarCopiedEvent) -> Void
  public init(handler: @escaping @MainActor (ShaarCopiedEvent) -> Void) { self.handler = handler }

  /// Call from the C callback. Borrowed bytes are copied before the callback returns.
  public nonisolated func receive(_ borrowed: ShaarABIEvent) {
    let copied = try? ShaarEventCopy.copy(borrowed)
    guard let copied else { return }
    Task { @MainActor [weak self] in self?.handler(copied) }
  }
}

public protocol ShaarSymbolResolving {
  func symbol(named: String) -> UnsafeRawPointer?
}

private struct FrameworkSymbols: ShaarSymbolResolving {
  let handle: UnsafeMutableRawPointer
  func symbol(named: String) -> UnsafeRawPointer? {
    dlsym(handle, named).map(UnsafeRawPointer.init)
  }
}

public final class ShaarEngineLoader: ShaarSymbolResolving, @unchecked Sendable {
  public static let abiMajor: UInt32 = 1
  public let implementation: ShaarEngineImplementation
  private let abiMajorFunction: @convention(c) () -> UInt32
  public let createSymbol: UnsafeRawPointer
  private let symbolResolver: any ShaarSymbolResolving
  private var frameworkHandle: UnsafeMutableRawPointer?

  public init(resolver: ShaarSymbolResolving, implementation: ShaarEngineImplementation = .shaar)
    throws
  {
    guard let majorSymbol = resolver.symbol(named: "shaar_abi_major") else {
      throw ShaarEngineError.missingSymbol("shaar_abi_major")
    }
    guard let create = resolver.symbol(named: "shaar_engine_create") else {
      throw ShaarEngineError.missingSymbol("shaar_engine_create")
    }
    let major = unsafeBitCast(majorSymbol, to: (@convention(c) () -> UInt32).self)()
    guard major == Self.abiMajor else {
      throw ShaarEngineError.unsupportedABI(expected: Self.abiMajor, actual: major)
    }
    self.implementation = implementation
    self.symbolResolver = resolver
    self.abiMajorFunction = unsafeBitCast(majorSymbol, to: (@convention(c) () -> UInt32).self)
    self.createSymbol = create
    self.frameworkHandle = nil
  }

  public func currentMajor() -> UInt32 { abiMajorFunction() }

  public static func load(frameworkURL: URL, implementation: ShaarEngineImplementation = .shaar)
    throws -> Self
  {
    let binary = frameworkURL.appending(path: "Versions/Current/Chromium Framework")
    guard let handle = dlopen(binary.path, RTLD_NOW | RTLD_LOCAL) else {
      throw ShaarEngineError.missingSymbol(String(cString: dlerror()))
    }
    do {
      let loader = try Self(
        resolver: FrameworkSymbols(handle: handle), implementation: implementation)
      loader.frameworkHandle = handle
      return loader
    } catch {
      dlclose(handle)
      throw error
    }
  }

  public func symbol(named: String) -> UnsafeRawPointer? {
    symbolResolver.symbol(named: named)
  }

  /// Called by the single transport owner after engine release and after every
  /// module has stopped submitting requests.
  func closeFramework() {
    guard let frameworkHandle else { return }
    self.frameworkHandle = nil
    dlclose(frameworkHandle)
  }

  deinit { closeFramework() }
}

extension ShaarStatusCode {
  public static func decode(_ rawValue: UInt32, platformCode: Int32 = 0, message: String = "")
    throws
  {
    guard let status = Self(rawValue: rawValue) else {
      throw ShaarEngineError.invalidStatusCode(rawValue)
    }
    guard status == .ok else {
      throw ShaarEngineError.status(status, platformCode: platformCode, message: message)
    }
  }
}
