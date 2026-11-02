// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing

@testable import ArcusisBrowser

@Test func vitalThresholdsMatchWebDevBoundaries() {
  for (good, poor) in [(2500.0, 4000.0), (200, 500), (0.1, 0.25)] {
    #expect(PerformanceQuality.rate(nil, good: good, poor: poor) == .unavailable)
    #expect(PerformanceQuality.rate(.nan, good: good, poor: poor) == .unavailable)
    #expect(PerformanceQuality.rate(good, good: good, poor: poor) == .good)
    #expect(PerformanceQuality.rate(poor, good: good, poor: poor) == .needsImprovement)
    #expect(PerformanceQuality.rate(poor + 0.001, good: good, poor: poor) == .poor)
  }
}

@Test func performanceSnapshotKeepsMissingMetricsUnavailable() {
  let value = PagePerformanceSnapshot(
    page: ["cls": 0.2, "lcp": -1, "bytes": Double.infinity], engineMetrics: [])
  #expect(value.lcp == nil && value.inp == nil && value.heapBytes == nil)
  #expect(value.clsQuality == .needsImprovement && value.transferredBytes == 0)
}
