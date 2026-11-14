// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import ShaarEngineC
import Testing

@testable import ShaarEngineABI

private struct EmptyPageViewSymbols: ShaarSymbolResolving {
  func symbol(named: String) -> UnsafeRawPointer? { nil }
}

@_cdecl("fake_page_view_get")
private func fakePageViewGet(_ handle: OpaquePointer?) -> UnsafeMutableRawPointer? {
  handle == OpaquePointer(bitPattern: 0x22) ? UnsafeMutableRawPointer(bitPattern: 0x77) : nil
}

@_cdecl("fake_page_view_action")
private func fakePageViewAction(
  _ engine: OpaquePointer?, _ window: OpaquePointer?, _ tab: OpaquePointer?,
  _ error: UnsafeMutablePointer<shaar_error>?
) -> shaar_error_code {
  guard engine == OpaquePointer(bitPattern: 0x11),
    window == OpaquePointer(bitPattern: 0x22), tab == OpaquePointer(bitPattern: 0x33)
  else { return shaar_error_code(rawValue: 1) }
  return shaar_error_code(rawValue: 4)
}

@_cdecl("fake_page_view_action_invalid_message_slice")
private func fakePageViewActionInvalidMessageSlice(
  _ engine: OpaquePointer?, _ window: OpaquePointer?, _ tab: OpaquePointer?,
  _ error: UnsafeMutablePointer<shaar_error>?
) -> shaar_error_code {
  error?.pointee.message = shaar_bytes(data: nil, size: 1)
  return shaar_error_code(rawValue: 4)
}

@_cdecl("fake_page_view_action_short_error_struct")
private func fakePageViewActionShortErrorStruct(
  _ engine: OpaquePointer?, _ window: OpaquePointer?, _ tab: OpaquePointer?,
  _ error: UnsafeMutablePointer<shaar_error>?
) -> shaar_error_code {
  error?.pointee.size = 0
  error?.pointee.code = shaar_error_code(rawValue: 4)
  return shaar_error_code(rawValue: 4)
}

@_cdecl("fake_page_view_resize")
private func fakePageViewResize(
  _ engine: OpaquePointer?, _ window: OpaquePointer?, _ width: Double, _ height: Double,
  _ error: UnsafeMutablePointer<shaar_error>?
) -> shaar_error_code {
  width == 300 && height == 200 ? shaar_error_code(rawValue: 0) : shaar_error_code(rawValue: 1)
}

private struct FakePageViewSymbols: ShaarSymbolResolving {
  func symbol(named name: String) -> UnsafeRawPointer? {
    switch name {
    case "shaar_window_host_view", "shaar_window_native_window", "shaar_tab_host_view":
      let function = fakePageViewGet as @convention(c) (OpaquePointer?) -> UnsafeMutableRawPointer?
      return unsafeBitCast(function, to: UnsafeRawPointer.self)
    case "shaar_tab_view_attach", "shaar_tab_view_detach", "shaar_tab_view_focus":
      let function =
        fakePageViewAction
        as @convention(c) (
          OpaquePointer?, OpaquePointer?, OpaquePointer?, UnsafeMutablePointer<shaar_error>?
        ) -> shaar_error_code
      return unsafeBitCast(function, to: UnsafeRawPointer.self)
    case "shaar_window_host_resize":
      let function =
        fakePageViewResize
        as @convention(c) (
          OpaquePointer?, OpaquePointer?, Double, Double, UnsafeMutablePointer<shaar_error>?
        ) -> shaar_error_code
      return unsafeBitCast(function, to: UnsafeRawPointer.self)
    default: return nil
    }
  }
}

private struct FakeInvalidMessagePageViewSymbols: ShaarSymbolResolving {
  func symbol(named name: String) -> UnsafeRawPointer? {
    switch name {
    case "shaar_window_host_view", "shaar_window_native_window", "shaar_tab_host_view":
      let function = fakePageViewGet as @convention(c) (OpaquePointer?) -> UnsafeMutableRawPointer?
      return unsafeBitCast(function, to: UnsafeRawPointer.self)
    case "shaar_tab_view_attach", "shaar_tab_view_detach", "shaar_tab_view_focus":
      let function =
        fakePageViewActionInvalidMessageSlice
        as @convention(c) (
          OpaquePointer?, OpaquePointer?, OpaquePointer?, UnsafeMutablePointer<shaar_error>?
        ) -> shaar_error_code
      return unsafeBitCast(function, to: UnsafeRawPointer.self)
    case "shaar_window_host_resize":
      let function = fakePageViewResize
        as @convention(c) (
          OpaquePointer?, OpaquePointer?, Double, Double, UnsafeMutablePointer<shaar_error>?
        ) -> shaar_error_code
      return unsafeBitCast(function, to: UnsafeRawPointer.self)
    default: return nil
    }
  }
}

private struct FakeShortErrorPageViewSymbols: ShaarSymbolResolving {
  func symbol(named name: String) -> UnsafeRawPointer? {
    guard ["shaar_tab_view_attach", "shaar_tab_view_detach", "shaar_tab_view_focus"].contains(name)
    else { return FakePageViewSymbols().symbol(named: name) }
    let function =
      fakePageViewActionShortErrorStruct
      as @convention(c) (
        OpaquePointer?, OpaquePointer?, OpaquePointer?, UnsafeMutablePointer<shaar_error>?
      ) -> shaar_error_code
    return unsafeBitCast(function, to: UnsafeRawPointer.self)
  }
}

@Suite("Shaar page view ABI")
struct ShaarPageViewABITests {
  @Test @MainActor func missingViewSymbolFailsBeforeUse() {
    #expect(throws: ShaarEngineError.missingSymbol("shaar_window_host_view")) {
      try ShaarPageViewABI(resolver: EmptyPageViewSymbols())
    }
  }

  @Test @MainActor func borrowedViewAndTypedAttachFailure() throws {
    let abi = try ShaarPageViewABI(resolver: FakePageViewSymbols())
    let engine = OpaquePointer(bitPattern: 0x11)!
    let window = OpaquePointer(bitPattern: 0x22)!
    let tab = OpaquePointer(bitPattern: 0x33)!
    #expect(abi.borrowedHostView(window: window) == UnsafeMutableRawPointer(bitPattern: 0x77))
    #expect(throws: ShaarEngineError.status(.notFound, platformCode: 0, message: "")) {
      try abi.attach(engine: engine, window: window, tab: tab)
    }
    try abi.resize(engine: engine, window: window, width: 300, height: 200)
  }

  @Test @MainActor func invalidErrorMessageSliceIsRejected() throws {
    let abi = try ShaarPageViewABI(resolver: FakeInvalidMessagePageViewSymbols())
    #expect(throws: ShaarEngineError.invalidEvent("invalid page-view error message")) {
      try abi.attach(
        engine: OpaquePointer(bitPattern: 0x11)!, window: OpaquePointer(bitPattern: 0x22)!,
        tab: OpaquePointer(bitPattern: 0x33)!)
    }
  }

  @Test @MainActor func shortErrorStructIsRejectedBeforeDecodingItsFields() throws {
    let abi = try ShaarPageViewABI(resolver: FakeShortErrorPageViewSymbols())
    #expect(throws: ShaarEngineError.invalidEvent("short page-view error")) {
      try abi.attach(
        engine: OpaquePointer(bitPattern: 0x11)!, window: OpaquePointer(bitPattern: 0x22)!,
        tab: OpaquePointer(bitPattern: 0x33)!)
    }
  }
}
