// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Stable across toolchains: failures identify their seed and bounded case index.
public struct SeededGenerator: RandomNumberGenerator {
  public static let seeds: [UInt64] = [0x334, 0x5A17, 0xC0FFEE]
  private var state: UInt64

  public init(seed: UInt64) { state = seed }

  public mutating func next() -> UInt64 {
    state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
    return state
  }

  public mutating func sample(_ upperBound: Int) -> Int {
    Int(next() % UInt64(upperBound))
  }

  public mutating func identifier() -> UUID {
    UUID(
      uuidString: String(
        format: "%08llx-0000-4000-8000-%012llx", next() & 0xffff_ffff,
        next() & 0xffff_ffff_ffff))!
  }
}

public enum UpgradeFixtures {
  public static let profileID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!

  public static func url(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .appending(path: "Fixtures/Upgrade/\(name).json")
  }
}
