// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import Foundation
import SwiftUI
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
        "Profiler.enable",
        "Profiler.startPreciseCoverage",
        "CSS.enable",
        "CSS.startRuleUsageTracking",
        "Profiler.takePreciseCoverage",
        "Profiler.stopPreciseCoverage",
        "CSS.stopRuleUsageTracking",
      ])
    let precise = zip(sent.methods, sent.params).first { method, _ in
      method == "Profiler.startPreciseCoverage"
    }
    #expect(precise?.1["callCount"] as? Bool == false)
    #expect(precise?.1["detailed"] as? Bool == true)
    #expect(model.recording == false)
  }

  @Test func probeEnablesCollectionWhenThePageAcceptsCoverage() async {
    let model = ShaarDevToolsCoverageModel()
    var methods: [String] = []
    model.send = { method, _ in
      methods.append(method)
      return [:]
    }
    await model.probeCollection()
    #expect(model.collectionReady)
    #expect(
      methods == [
        "Profiler.enable",
        "Profiler.startPreciseCoverage",
        "Profiler.stopPreciseCoverage",
        "CSS.enable",
        "CSS.startRuleUsageTracking",
        "CSS.stopRuleUsageTracking",
      ])
    await model.probeCollection()
    #expect(methods.count == 6)
  }

  @Test func probeLeavesCollectionWaitingWhenTheProfilerDomainIsOff() async {
    let model = ShaarDevToolsCoverageModel()
    model.send = { method, _ in
      if method == "Profiler.startPreciseCoverage" {
        throw DeveloperModeFailure("Profiler is not enabled")
      }
      return [:]
    }
    await model.probeCollection()
    #expect(!model.collectionReady)
    await model.start()
    #expect(!model.recording)
  }

  @Test func probeLeavesCollectionWaitingWhenTheEngineRejectsIt() async {
    let model = ShaarDevToolsCoverageModel()
    var methods: [String] = []
    model.send = { method, _ in
      methods.append(method)
      throw DeveloperModeFailure("unknown DevTools capability or command")
    }
    await model.probeCollection()
    #expect(!model.collectionReady)
    #expect(methods.contains("Profiler.enable"))
    #expect(methods.contains("Profiler.stopPreciseCoverage"))
    #expect(!methods.contains("Profiler.startPreciseCoverage"))
    #expect(!methods.contains("CSS.startRuleUsageTracking"))
  }

  @Test func probeRetriesWhenThePageGoesAway() async {
    let model = ShaarDevToolsCoverageModel()
    var rejectStart = true
    model.send = { method, _ in
      if rejectStart && method == "Profiler.enable" {
        rejectStart = false
        throw DeveloperModeFailure("The page changed. Try again.")
      }
      return [:]
    }
    await model.probeCollection()
    #expect(!model.collectionReady)
    await model.probeCollection()
    #expect(model.collectionReady)
  }

  @Test func coverageRepliesCoverMissingIdentifiersAndNumericBoxes() {
    let scripts = ShaarDevToolsCoverage.scripts(from: scriptReply())
    #expect(scripts.map(\.url) == ["script 9", "script 2", "script 3"])
    #expect(scripts[0].ranges == [ShaarDevToolsCoverageCountedSpan(start: 2, end: 6, count: 1)])
    #expect(scripts[2].ranges == [ShaarDevToolsCoverageCountedSpan(start: 0, end: 0, count: 0)])

    let listed = ShaarDevToolsCoverage.sheets(from: listedSheetReply())
    #expect(listed.map(\.url) == ["http://localhost:3000/blank.css"])
    #expect(listed[0].totalBytes == 8)
    #expect(listed[0].usedRanges.isEmpty)

    let grouped = ShaarDevToolsCoverage.sheets(from: groupedRuleReply())
    #expect(grouped.map(\.url) == ["http://localhost:3000/partial.css", "sheet-2"])
    #expect(grouped[0].totalBytes == 40)
    #expect(
      grouped[0].usedRanges == [
        ShaarDevToolsCoverageSpan(start: 0, end: 40),
        ShaarDevToolsCoverageSpan(start: 20, end: 30),
      ])
    #expect(grouped[1].totalBytes == 10)
    #expect(grouped[1].usedRanges.isEmpty)
    #expect(ShaarDevToolsCoverage.sizeLabel(12) == "12 B")
    #expect(ShaarDevToolsCoverage.sizeLabel(2_048) == "2.0 KB")
    #expect(ShaarDevToolsCoverage.displayName("http://localhost:3000/app.js") == "/app.js")
    #expect(ShaarDevToolsCoverage.displayName("http://localhost:3000/") == "localhost")
    #expect(ShaarDevToolsCoverage.displayName("not a url") == "not a url")
    #expect(ShaarDevToolsCoverageKind.script.title == "Script")
    #expect(ShaarDevToolsCoverageKind.stylesheet.title == "Style sheet")
    let gapped = ShaarDevToolsCoverage.summarize(
      scripts: [
        ShaarDevToolsCoverageScript(
          url: "http://localhost:3000/gap.js",
          ranges: [
            ShaarDevToolsCoverageCountedSpan(start: 0, end: 10, count: 1),
            ShaarDevToolsCoverageCountedSpan(start: 20, end: 30, count: 1),
            ShaarDevToolsCoverageCountedSpan(start: 8, end: 4, count: 1),
          ])
      ],
      sheets: [])
    #expect(gapped.map(\.usedBytes) == [20])
  }

  @Test func coveragePanelRendersOffscreenForEachState() async throws {
    _ = NSApplication.shared
    let defaults = UserDefaults(suiteName: "ShaarDevToolsCoverage.render.\(UUID().uuidString)")!
    let target = SiteControlTarget(
      tabID: UUID(), profileID: UUID(), url: URL(string: "http://localhost:3000/")!)
    let shell = ShaarDevToolsModel(target: target, layoutDefaults: defaults)
    let inspector = InspectorModel(target: target, engine: nil)
    shell.open(inspector: inspector)
    let model = shell.coverage
    #expect(!model.collectionReady)
    let waiting = try renderCoverage(model, height: 420)

    model.collectionReady = true
    await model.start()
    #expect(model.notice == .needsPage)
    let needsPage = try renderCoverage(model, height: 420)

    model.send = { _, _ in throw ShaarCoverageFailure("Coverage was rejected.") }
    await model.start()
    #expect(model.notice == .failed("Coverage was rejected."))
    #expect(!model.recording)
    let failed = try renderCoverage(model, height: 420)

    model.send = { _, _ in [:] }
    await model.start()
    #expect(model.recording)
    let recording = try renderCoverage(model, height: 420)
    model.send = nil
    await model.stop()
    #expect(model.notice == .needsPage)
    #expect(!model.recording)

    let taken = CoverageCallLog()
    model.send = { method, params in
      taken.record(method, params: params)
      if method == "Profiler.takePreciseCoverage" {
        throw ShaarCoverageFailure("Coverage could not be read.")
      }
      return [:]
    }
    await model.start()
    await model.stop()
    #expect(taken.methods.contains("Profiler.takePreciseCoverage"))
    #expect(model.notice == .failed("Coverage could not be read."))

    let next = SiteControlTarget(tabID: UUID(), profileID: target.profileID, url: target.url)
    model.retarget(next)
    #expect(model.rows.isEmpty)
    #expect(model.notice == nil)
    model.present(scripts: renderedScripts, sheets: renderedSheets)
    #expect(model.rows.map(\.percent) == [50, 40, 0])
    let rows = try renderCoverage(model, height: 520)
    shell.section = .coverage
    let panel = try VisualCapture.pngOffscreen(
      ShaarDevToolsPanel(model: shell, inspector: inspector, openChromium: {}),
      size: NSSize(width: 850, height: 620))
    #expect(!waiting.isEmpty)
    #expect(!needsPage.isEmpty)
    #expect(!failed.isEmpty)
    #expect(!recording.isEmpty)
    #expect(!rows.isEmpty)
    #expect(!panel.isEmpty)
    shell.close()
  }
}

@MainActor private func renderCoverage(_ model: ShaarDevToolsCoverageModel, height: CGFloat) throws
  -> Data
{
  try VisualCapture.pngOffscreen(
    ShaarDevToolsCoveragePanel(model: model), size: NSSize(width: 640, height: height))
}

private let renderedScripts = [
  ShaarDevToolsCoverageScript(
    url: "http://localhost:3000/app.js",
    ranges: [
      ShaarDevToolsCoverageCountedSpan(start: 0, end: 40, count: 1),
      ShaarDevToolsCoverageCountedSpan(start: 40, end: 100, count: 0),
    ])
]

private let renderedSheets = [
  ShaarDevToolsCoverageSheet(
    url: "http://localhost:3000/site.css", totalBytes: 2_048,
    usedRanges: [ShaarDevToolsCoverageSpan(start: 0, end: 1_024)]),
  ShaarDevToolsCoverageSheet(
    url: "http://localhost:3000/", totalBytes: 0, usedRanges: []),
]

private func scriptReply() -> [String: Any] {
  return [
    "result": [
      [
        "scriptId": "9",
        "functions": [
          [
            "ranges": [
              [
                "startOffset": NSNumber(value: 2),
                "endOffset": NSNumber(value: 6),
                "count": NSNumber(value: 1),
              ] as [String: Any]
            ]
          ] as [String: Any]
        ],
      ] as [String: Any],
      ["url": "", "functions": []] as [String: Any],
      [
        "functions": [
          ["ranges": [["count": "no"] as [String: Any]]] as [String: Any]
        ]
      ] as [String: Any],
    ] as [[String: Any]]
  ]
}

private func listedSheetReply() -> [String: Any] {
  return [
    "sheets": [
      ["totalBytes": 12] as [String: Any],
      ["url": "", "totalBytes": 4] as [String: Any],
      [
        "url": "http://localhost:3000/blank.css",
        "totalBytes": NSNumber(value: 8),
        "ruleUsage": [
          ["used": NSNumber(value: false), "startOffset": 1, "endOffset": 2] as [String: Any]
        ],
      ] as [String: Any],
    ] as [[String: Any]]
  ]
}

private func groupedRuleReply() -> [String: Any] {
  return [
    "ruleUsage": [
      [
        "url": "http://localhost:3000/partial.css",
        "startOffset": 0,
        "endOffset": 40,
        "used": true,
      ] as [String: Any],
      [
        "url": "http://localhost:3000/partial.css",
        "startOffset": 20.0,
        "endOffset": 30.0,
        "used": NSNumber(value: true),
      ] as [String: Any],
      [
        "styleSheetId": "sheet-2",
        "startOffset": 0,
        "endOffset": 10,
        "used": false,
      ] as [String: Any],
      ["startOffset": 0, "endOffset": 4] as [String: Any],
    ] as [[String: Any]]
  ]
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
