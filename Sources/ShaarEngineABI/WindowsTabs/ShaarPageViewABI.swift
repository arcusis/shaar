// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import ShaarEngineC

private typealias ViewGetter = @convention(c) (OpaquePointer?) -> UnsafeMutableRawPointer?
private typealias TabViewAction =
  @convention(c) (
    OpaquePointer?, OpaquePointer?, OpaquePointer?, UnsafeMutablePointer<shaar_error>?
  ) -> shaar_error_code
private typealias WindowResize =
  @convention(c) (
    OpaquePointer?, OpaquePointer?, Double, Double, UnsafeMutablePointer<shaar_error>?
  ) -> shaar_error_code

/// Resolves page-host symbols from the same loader that owns the engine.
/// Returned AppKit pointers are borrowed until the corresponding close event.
@MainActor public final class ShaarPageViewABI {
  private let hostView: ViewGetter
  private let nativeWindow: ViewGetter
  private let tabView: ViewGetter
  private let attachView: TabViewAction
  private let detachView: TabViewAction
  private let focusView: TabViewAction
  private let resizeHost: WindowResize

  public init(resolver: any ShaarSymbolResolving) throws {
    func required(_ name: String) throws -> UnsafeRawPointer {
      guard let symbol = resolver.symbol(named: name) else {
        throw ShaarEngineError.missingSymbol(name)
      }
      return symbol
    }
    hostView = unsafeBitCast(try required("shaar_window_host_view"), to: ViewGetter.self)
    nativeWindow = unsafeBitCast(try required("shaar_window_native_window"), to: ViewGetter.self)
    tabView = unsafeBitCast(try required("shaar_tab_host_view"), to: ViewGetter.self)
    attachView = unsafeBitCast(try required("shaar_tab_view_attach"), to: TabViewAction.self)
    detachView = unsafeBitCast(try required("shaar_tab_view_detach"), to: TabViewAction.self)
    focusView = unsafeBitCast(try required("shaar_tab_view_focus"), to: TabViewAction.self)
    resizeHost = unsafeBitCast(try required("shaar_window_host_resize"), to: WindowResize.self)
  }

  public func borrowedHostView(window: OpaquePointer) -> UnsafeMutableRawPointer? {
    hostView(window)
  }

  public func borrowedNativeWindow(window: OpaquePointer) -> UnsafeMutableRawPointer? {
    nativeWindow(window)
  }

  public func borrowedTabView(tab: OpaquePointer) -> UnsafeMutableRawPointer? {
    tabView(tab)
  }

  public func attach(engine: OpaquePointer, window: OpaquePointer, tab: OpaquePointer) throws {
    try call(attachView, engine: engine, window: window, tab: tab)
  }

  public func detach(engine: OpaquePointer, window: OpaquePointer, tab: OpaquePointer) throws {
    try call(detachView, engine: engine, window: window, tab: tab)
  }

  public func focus(engine: OpaquePointer, window: OpaquePointer, tab: OpaquePointer) throws {
    try call(focusView, engine: engine, window: window, tab: tab)
  }

  public func resize(
    engine: OpaquePointer, window: OpaquePointer, width: Double, height: Double
  ) throws {
    var error = emptyError()
    let status = resizeHost(engine, window, width, height, &error)
    try decode(status, error: error)
  }

  private func call(
    _ function: TabViewAction, engine: OpaquePointer, window: OpaquePointer, tab: OpaquePointer
  ) throws {
    var error = emptyError()
    let status = function(engine, window, tab, &error)
    try decode(status, error: error)
  }

  private func emptyError() -> shaar_error {
    shaar_error(
      size: UInt32(MemoryLayout<shaar_error>.size), code: shaar_error_code(rawValue: 0),
      platform_code: 0, message: shaar_bytes(data: nil, size: 0))
  }

  private func decode(_ status: shaar_error_code, error: shaar_error) throws {
    guard error.size >= UInt32(MemoryLayout<shaar_error>.size) else {
      throw ShaarEngineError.invalidEvent("short page-view error")
    }
    guard error.message.size == 0 || error.message.data != nil else {
      throw ShaarEngineError.invalidEvent("invalid page-view error message")
    }
    let message: String
    if let data = error.message.data, error.message.size > 0 {
      message = String(decoding: Data(bytes: data, count: error.message.size), as: UTF8.self)
    } else {
      message = ""
    }
    try ShaarStatusCode.decode(
      UInt32(status.rawValue), platformCode: error.platform_code, message: message)
  }
}
