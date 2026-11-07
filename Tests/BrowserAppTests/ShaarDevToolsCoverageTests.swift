// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing

@testable import ArcusisBrowser

@MainActor @Suite struct ShaarDevToolsCoverageTests {
  @Test func byteCountsMergeRangesAndSortUnusedFirst() {
    let rows = ShaarDevToolsCoverage.summarize(
      scripts: [
        ShaarDevToolsCoverageScript(
          url: "http://localhost:3000/app.js",
          ranges: [
            ShaarDevToolsCoverageCountedSpan(start: 0, end: 40, count: 2),
            ShaarDevToolsCoverageCountedSpan(start: 30, end: 50, count: 1),
            ShaarDevToolsCoverageCountedSpan(start: 40, end: 100, count: 0),
          ])
      ],
      sheets: [
        ShaarDevToolsCoverageSheet(
          url: "http://localhost:3000/empty.css", totalBytes: 200, usedRanges: []),
        ShaarDevToolsCoverageSheet(
          url: "http://localhost:3000/partial.css", totalBytes: 50,
          usedRanges: [ShaarDevToolsCoverageSpan(start: 40, end: 80)]),
      ])
    #expect(
      rows.map(\.url) == [
        "http://localhost:3000/empty.css",
        "http://localhost:3000/app.js",
        "http://localhost:3000/partial.css",
      ])
    #expect(rows.map(\.unusedBytes) == [200, 50, 40])
    #expect(rows.map(\.usedBytes) == [0, 50, 10])
    #expect(rows.map(\.totalBytes) == [200, 100, 50])
    #expect(rows.map(\.percent) == [0, 50, 20])
    #expect(rows.map(\.kind) == [.stylesheet, .script, .stylesheet])
  }

  @Test func zeroTotalStaysAtZeroPercent() {
    let rows = ShaarDevToolsCoverage.summarize(
      scripts: [],
      sheets: [
        ShaarDevToolsCoverageSheet(
          url: "http://localhost:3000/blank.css", totalBytes: 0, usedRanges: [])
      ])
    #expect(rows.count == 1)
    #expect(rows[0].usedBytes == 0)
    #expect(rows[0].unusedBytes == 0)
    #expect(rows[0].percent == 0)
  }

  @Test func fixtureTransportDrivesAUsedRangeAndAnUnusedSheet() async {
    let fixture = ShaarCoverageFixture()
    let model = ShaarDevToolsCoverageModel()
    model.transport = fixture
    await model.recordFixture()
    #expect(
      fixture.methods == [
        "Profiler.startPreciseCoverage",
        "Profiler.takePreciseCoverage",
        "Profiler.stopPreciseCoverage",
        "CSS.startRuleUsageTracking",
        "CSS.stopRuleUsageTracking",
      ])
    #expect(
      model.rows.map(\.url) == [
        "http://localhost:3000/empty.css",
        "http://localhost:3000/app.js",
      ])
    #expect(model.rows[0].kind == .stylesheet)
    #expect(model.rows[0].usedBytes == 0)
    #expect(model.rows[0].totalBytes == 200)
    #expect(model.rows[0].unusedBytes == 200)
    #expect(model.rows[1].kind == .script)
    #expect(model.rows[1].usedBytes == 40)
    #expect(model.rows[1].totalBytes == 100)
    #expect(model.rows[1].percent == 40)
  }

  @Test func liveCollectionStaysOffUntilTheEngineAllowsIt() async {
    let model = ShaarDevToolsCoverageModel()
    let sent = CoverageCallLog()
    model.send = { method, params in
      sent.record(method, params: params)
      return [:]
    }
    await model.start()
    await model.stop()
    #expect(sent.methods == [])
    model.collectionReady = true
    await model.start()
    await model.stop()
    #expect(
      sent.methods == [
        "Profiler.startPreciseCoverage",
        "CSS.enable",
        "CSS.startRuleUsageTracking",
        "Profiler.takePreciseCoverage",
        "Profiler.stopPreciseCoverage",
        "CSS.stopRuleUsageTracking",
      ])
    let startParams = sent.params.first
    #expect(startParams?["callCount"] as? Bool == false)
    #expect(startParams?["detailed"] as? Bool == true)
    #expect(model.recording == false)
  }
}

@MainActor private final class ShaarCoverageFixture: ShaarCoverageTransport {
  private(set) var methods: [String] = []

  func execute(_ method: String) async -> [String: Any] {
    methods.append(method)
    if method == "Profiler.takePreciseCoverage" { return Self.taken }
    if method == "CSS.stopRuleUsageTracking" { return Self.rules }
    return [:]
  }

  private static let taken: [String: Any] = [
    "result": [
      [
        "scriptId": "7",
        "url": "http://localhost:3000/app.js",
        "functions": [
          [
            "functionName": "main",
            "ranges": [
              ["startOffset": 0, "endOffset": 40, "count": 1] as [String: Any],
              ["startOffset": 40, "endOffset": 100, "count": 0] as [String: Any],
            ] as [[String: Any]],
          ] as [String: Any]
        ] as [[String: Any]],
      ] as [String: Any]
    ] as [[String: Any]]
  ]

  private static let rules: [String: Any] = [
    "sheets": [
      [
        "url": "http://localhost:3000/empty.css",
        "totalBytes": 200,
        "ruleUsage": [] as [[String: Any]],
      ] as [String: Any]
    ] as [[String: Any]]
  ]
}

@MainActor private final class CoverageCallLog {
  private(set) var methods: [String] = []
  private(set) var params: [[String: Any]] = []

  func record(_ method: String, params: [String: Any]) {
    methods.append(method)
    self.params.append(params)
  }
}
