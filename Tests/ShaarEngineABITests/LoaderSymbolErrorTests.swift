// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing

@testable import ShaarEngineABI

@_cdecl("test_loader_matching_abi_major")
private func testLoaderMatchingABIMajor() -> UInt32 { 1 }

private struct MissingSymbolResolver: ShaarSymbolResolving {
  let exports: Set<String>

  func symbol(named: String) -> UnsafeRawPointer? {
    guard exports.contains(named) else { return nil }
    return unsafeBitCast(
      testLoaderMatchingABIMajor as @convention(c) () -> UInt32,
      to: UnsafeRawPointer.self)
  }
}

@Test func loaderReportsEachMissingRequiredExport() {
  #expect(throws: ShaarEngineError.missingSymbol("shaar_abi_major")) {
    try ShaarEngineLoader(resolver: MissingSymbolResolver(exports: []))
  }
  #expect(throws: ShaarEngineError.missingSymbol("shaar_engine_create")) {
    try ShaarEngineLoader(resolver: MissingSymbolResolver(exports: ["shaar_abi_major"]))
  }
}
