// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

public enum BrowserTestEnvironment {
  public static var isSanitizerRun: Bool {
    ProcessInfo.processInfo.environment["CI_SANITIZER"] != nil
  }

  /// Wall-clock speedup ratios are noisy on shared machines, so tests assert them only on request.
  public static var assertsSpeedupRatios: Bool {
    ProcessInfo.processInfo.environment["SPEEDUP_BENCHMARK"] == "1"
  }
}
