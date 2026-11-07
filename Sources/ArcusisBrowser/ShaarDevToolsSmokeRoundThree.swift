// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import Foundation

@MainActor extension ShaarDevToolsSmoke {
  static func exerciseRealWorldRoundThree(
    shell: ShaarDevToolsModel, inspector: InspectorModel, context: NativeBrowserContext,
    host: NativeBrowserHost, pageURL: URL, report: ShaarDevToolsSmokeReport
  ) async {
    prepareDock(shell, context: context)
    await roundThreeMemory(shell, context: context, report: report)
    await roundThreeCoverage(shell, context: context, pageURL: pageURL, report: report)
    await roundThreeAudits(shell, inspector: inspector, context: context, report: report)
    await roundThreeIssues(shell, inspector: inspector, context: context, report: report)
    await roundThreeComponents(shell, context: context, report: report)
    await roundThreeRecorder(shell, inspector: inspector, context: context, report: report)
    await roundThreeRepro(shell, context: context, report: report)
    await roundThreeViewports(shell, context: context, report: report)
    await roundThreeRendering(shell, inspector: inspector, context: context, report: report)
    await roundThreeComparison(shell, context: context, report: report)
    await roundThreeSensors(shell, inspector: inspector, context: context, report: report)
    await roundThreeCSS(shell, context: context, pageURL: pageURL, report: report)
    await roundThreePerformance(shell, inspector: inspector, context: context, report: report)
    row(windowsHidden(host), "round3-hidden", "All app windows stayed hidden", report: report)
  }

  private static func row(
    _ passed: Bool, _ name: String, _ detail: String, report: ShaarDevToolsSmokeReport
  ) {
    if passed { report.pass(name, detail) } else { report.fail(name, detail) }
  }

  private static func show(
    _ section: ShaarDevToolsSection, shell: ShaarDevToolsModel,
    context: NativeBrowserContext, report: ShaarDevToolsSmokeReport
  ) async {
    let button = "shaar.devtools.\(section.rawValue.lowercased())"
    let pressed = ShaarDevToolsSmokeAccess.press(identifier: button, in: context.hosting)
    if shell.section != section { shell.section = section }
    let root = contentIdentifier(section)
    let rendered = await wait(attempts: 40) {
      let found = root.map {
        ShaarDevToolsSmokeAccess.element(identifier: $0, in: context.hosting) != nil
      } ?? false
      return found || section == .issues && !shell.issues.isEmpty || panelIsPainted(
        section, in: ShaarDevToolsSmokeAccess.renderedText(context.hosting))
    }
    await settle(context)
    let capture = report.directory.appending(
      path: "world-round3-\(section.rawValue.replacingOccurrences(of: " ", with: "-").lowercased()).png")
    let painted = ShaarDevToolsSmokeAccess.capture(context.hosting, to: capture)
    row(rendered && painted, "round3-panel-\(section.rawValue)",
        "Root=\(rendered), tab press=\(pressed), offscreen capture=\(painted)", report: report)
  }

  private static func roundThreeMemory(
    _ shell: ShaarDevToolsModel, context: NativeBrowserContext, report: ShaarDevToolsSmokeReport
  ) async {
    await show(.memory, shell: shell, context: context, report: report)
    let pressed = ShaarDevToolsSmokeAccess.press(
      identifier: "shaar.devtools.memory.snapshot", in: context.hosting)
    if !pressed { await shell.memory.takeSnapshot() }
    _ = await wait(attempts: 150) { shell.memory.snapshot != nil || shell.memory.failure != nil }
    let first = shell.memory.snapshot
    row(first?.nodeCount ?? 0 > 0, "round3-memory-snapshot",
        "Pressed=\(pressed), nodes=\(first?.nodeCount ?? 0), bytes=\(first?.totalBytes ?? 0), failure=\(shell.memory.failure ?? "none")", report: report)
    await shell.memory.takeSnapshot()
    row(shell.memory.snapshot != nil, "round3-memory-second",
        "Second snapshot nodes=\(shell.memory.snapshot?.nodeCount ?? 0)", report: report)
    row(false, "round3-memory-compare-retainers",
        "Memory keeps only one summary; no snapshot comparison or retainer graph", report: report)
  }

  private static func roundThreeCoverage(
    _ shell: ShaarDevToolsModel, context: NativeBrowserContext, pageURL: URL,
    report: ShaarDevToolsSmokeReport
  ) async {
    await show(.coverage, shell: shell, context: context, report: report)
    await shell.coverage.probeCollection()
    let ready = shell.coverage.collectionReady
    if ready { await shell.coverage.start() }
    row(ready && shell.coverage.recording, "round3-coverage-start",
        "Ready=\(ready), recording=\(shell.coverage.recording), notice=\(String(describing: shell.coverage.notice))", report: report)
    guard shell.coverage.recording else { return }
    _ = try? await context.engine.inspectors[shell.target.tabID]?.evaluate(
      "(()=>{const style=document.createElement('style');style.textContent='body{outline:0 solid transparent}';document.head.appendChild(style);return 42})()")
    await shell.coverage.stop()
    let beforeReload = shell.coverage.rows
    row(beforeReload.contains { $0.totalBytes > 0 && $0.usedBytes >= 0 && $0.unusedBytes >= 0 },
        "round3-coverage-bytes", "Files=\(beforeReload.count), notice=\(String(describing: shell.coverage.notice))", report: report)
    if beforeReload.isEmpty {
      report.manual("round3-coverage-open-file", "No coverage row available to open")
    } else {
      report.fail("round3-coverage-open-file", "Coverage rows are static views without an Open in Sources action")
    }
    await shell.coverage.start()
    guard shell.coverage.recording else { return }
    let reloaded = context.store.reloadCurrentPage()
    if reloaded { _ = await wait(attempts: 180) { worldPageReady(context, pageURL) } }
    let survived = shell.coverage.recording
    await shell.coverage.stop()
    let rows = shell.coverage.rows
    row(reloaded && survived && !rows.isEmpty, "round3-coverage-reload-stop",
        "Reload=\(reloaded), recording survived=\(survived), files=\(rows.count), notice=\(String(describing: shell.coverage.notice))", report: report)
  }

  private static func roundThreeAudits(
    _ shell: ShaarDevToolsModel, inspector: InspectorModel, context: NativeBrowserContext,
    report: ShaarDevToolsSmokeReport
  ) async {
    await show(.audits, shell: shell, context: context, report: report)
    _ = try? await inspector.evaluate("(()=>{const b=document.createElement('button');b.id='shaar-round3-unlabeled';document.body.appendChild(b);return true})()")
    let pressed = ShaarDevToolsSmokeAccess.press(
      identifier: "shaar.devtools.runAudit", in: context.hosting)
    if !pressed { shell.pageAudit.run() }
    _ = await wait(attempts: 300) { shell.auditCounts.hasReport || shell.auditFailure != nil }
    let counts = shell.auditCounts
    row(counts.hasReport && counts.violations > 0, "round3-audit-run",
        "Pressed=\(pressed), violations=\(counts.violations), incomplete=\(counts.incomplete), failure=\(shell.auditFailure ?? "none")", report: report)
    if let finding = shell.auditRows.first(where: { !$0.target.isEmpty }) {
      shell.openAuditFinding(finding.id)
      let selected = await wait(attempts: 60) { inspector.selection?.locked == true }
      row(selected, "round3-audit-node-link",
          "Finding=\(finding.id), target=\(finding.target), selected=\(selected)", report: report)
    } else {
      report.fail("round3-audit-node-link", "Unlabeled test button produced no node-linked finding")
    }
    _ = try? await inspector.evaluate("document.getElementById('shaar-round3-unlabeled')?.remove()")
  }

  private static func roundThreeIssues(
    _ shell: ShaarDevToolsModel, inspector: InspectorModel, context: NativeBrowserContext,
    report: ShaarDevToolsSmokeReport
  ) async {
    _ = try? await inspector.evaluate("console.error('shaar-round3-issue')")
    _ = try? await inspector.evaluate("fetch('/__shaar_round3_missing.png?round3='+Date.now()).catch(()=>{});true")
    _ = await wait(attempts: 80) { shell.issues.contains { $0.title.contains("shaar-round3-issue") } }
    _ = await wait(attempts: 80) {
      shell.issues.contains { $0.title.contains("__shaar_round3_missing.png") }
    }
    await show(.issues, shell: shell, context: context, report: report)
    guard let issue = shell.issues.first(where: { $0.title.contains("shaar-round3-issue") }) else {
      report.fail("round3-issues-list", "Injected page error absent from Issues")
      return
    }
    shell.openIssue(issue)
    row(shell.section == .console && shell.console.selectedID != nil,
        "round3-issues-link", "Error links to selected Console row", report: report)
    if let request = shell.issues.first(where: { $0.title.contains("__shaar_round3_missing.png") }) {
      shell.openIssue(request)
      row(shell.section == .network && shell.network.selectedID != nil,
          "round3-issues-request-link", "Failed request links to selected Network row", report: report)
    } else {
      report.fail("round3-issues-request-link", "Failed request absent from Issues")
    }
  }

  private static func roundThreeComponents(
    _ shell: ShaarDevToolsModel, context: NativeBrowserContext, report: ShaarDevToolsSmokeReport
  ) async {
    await show(.components, shell: shell, context: context, report: report)
    await shell.framework.refresh()
    let rows = shell.framework.rows
    var scriptFailure = "none"
    if shell.framework.failure != nil {
      do {
        let raw = try await context.engine.inspectors[shell.target.tabID]?.evaluate(
          ShaarFrameworkPageScript.inspect)
        _ = try ShaarFrameworkSnapshotParser.parse(raw)
        scriptFailure = "Parser succeeded on retry"
      } catch let failure as ShaarFrameworkFailure {
        scriptFailure = "Parser: \(failure.reason)"
      } catch {
        scriptFailure = error.localizedDescription
      }
    }
    if shell.target.url.host == "127.0.0.1" && [3210, 3211].contains(shell.target.url.port ?? 0) {
      row(!rows.isEmpty, "round3-components-tree",
          "Framework=\(String(describing: shell.framework.framework)), nodes=\(rows.count), failure=\(shell.framework.failure ?? "none"), script=\(scriptFailure)", report: report)
      if let first = rows.first {
        shell.framework.select(first.id)
        row(shell.framework.selected != nil, "round3-components-detail",
            "Selected=\(shell.framework.selected?.name ?? "none"), props=\(shell.framework.selected?.props.count ?? 0), state=\(shell.framework.selected?.state.count ?? 0)", report: report)
        var highlighted = false
        if let inspector = context.engine.inspectors[shell.target.tabID] {
          for _ in 0..<30 {
            let value = try? await inspector.evaluate(
              "document.getElementById('shaar-framework-highlight')?.getAttribute('data-shaar-highlight')")
            if value as? String == first.id {
              highlighted = true
              break
            }
            try? await Task.sleep(for: .milliseconds(100))
          }
        }
        row(highlighted, "round3-components-select-page",
            "Selected component highlighted on page=\(highlighted)", report: report)
      }
    } else {
      report.manual("round3-components-tree", "Framework tree only expected on local Next.js and Vue")
    }
  }

  private static func roundThreeRecorder(
    _ shell: ShaarDevToolsModel, inspector: InspectorModel, context: NativeBrowserContext,
    report: ShaarDevToolsSmokeReport
  ) async {
    await show(.recorder, shell: shell, context: context, report: report)
    await shell.recorder.start()
    let started = shell.recorder.recording
    _ = try? await inspector.evaluate("(()=>{const b=document.createElement('button');b.id='shaar-round3-click';b.onclick=()=>{window.__shaarRound3Clicked=true};document.body.appendChild(b);const i=document.createElement('input');i.id='shaar-round3-input';document.body.appendChild(i);b.click();i.value='round3';i.dispatchEvent(new Event('change',{bubbles:true}));return true})()")
    await shell.recorder.stop()
    let steps = shell.recorder.steps
    row(started && steps.contains { $0.kind == .click } && steps.contains { $0.kind == .change },
        "round3-recorder-record", "Started=\(started), steps=\(steps.map { $0.kind.rawValue })", report: report)
    _ = try? await inspector.evaluate("window.__shaarRound3Clicked=false;document.getElementById('shaar-round3-input').value='';true")
    await shell.recorder.replay()
    let replayed = try? await inspector.evaluate(
      "window.__shaarRound3Clicked === true && document.getElementById('shaar-round3-input').value === 'round3'")
    row((replayed as? NSNumber)?.boolValue == true, "round3-recorder-replay",
        "Replay click and typed value=\(String(describing: replayed)), notice=\(String(describing: shell.recorder.notice))", report: report)
    let exported = try? shell.recorder.exportFile(in: report.directory)
    row(exported != nil, "round3-recorder-export",
        "Export=\(exported?.lastPathComponent ?? "none"), notice=\(String(describing: shell.recorder.notice))", report: report)
    _ = try? await inspector.evaluate("document.getElementById('shaar-round3-click')?.remove();document.getElementById('shaar-round3-input')?.remove()")
  }

  private static func roundThreeRepro(
    _ shell: ShaarDevToolsModel, context: NativeBrowserContext, report: ShaarDevToolsSmokeReport
  ) async {
    await show(.repro, shell: shell, context: context, report: report)
    let ready = await wait(attempts: 300) { shell.repro.available }
    if !ready && shell.repro.recording && !shell.repro.hasMaskedFrames {
      report.manual("round3-repro-bundle", "Hidden page produced no masked video frame; Create remained disabled")
      return
    }
    let file = ready ? await shell.repro.capture(to: report.directory) : nil
    row(file != nil && shell.repro.viewerContents != nil, "round3-repro-bundle",
        "Available=\(ready), saved=\(file?.lastPathComponent ?? "none"), failure=\(shell.repro.failure ?? "none")", report: report)
  }

  private static func roundThreeViewports(
    _ shell: ShaarDevToolsModel, context: NativeBrowserContext, report: ShaarDevToolsSmokeReport
  ) async {
    await show(.viewports, shell: shell, context: context, report: report)
    let ready = await wait(attempts: 80) { shell.viewports.available }
    if ready { try? await shell.viewports.perform(.add(.iphone15Pro)) }
    _ = await wait(attempts: 80) { !shell.viewports.frames.isEmpty }
    let frame = shell.viewports.frames.first
    row(frame != nil, "round3-viewports-preset",
        "Available=\(ready), frames=\(shell.viewports.frames.count)", report: report)
    if let frame {
      try? await shell.viewports.perform(.rotate(frame.id))
      let rotated = await wait(attempts: 80) {
        shell.viewports.frames.first?.orientation != frame.orientation
      }
      row(rotated, "round3-viewports-rotate", "Rotated=\(rotated)", report: report)
    }
    row(false, "round3-viewports-custom-size", "No custom width and height control", report: report)
  }

  private static func roundThreeRendering(
    _ shell: ShaarDevToolsModel, inspector: InspectorModel, context: NativeBrowserContext,
    report: ShaarDevToolsSmokeReport
  ) async {
    await show(.rendering, shell: shell, context: context, report: report)
    await shell.rendering.prepare()
    let ready = shell.rendering.overlayCommandsAvailable
    shell.rendering.paintRects = true
    shell.rendering.layoutShiftRegions = true
    shell.rendering.fpsMeter = true
    await shell.rendering.settled()
    row(ready && shell.rendering.failure == nil, "round3-rendering-overlays",
        "Available=\(ready), failure=\(shell.rendering.failure ?? "none")", report: report)
    shell.rendering.restore()
  }

  private static func roundThreeComparison(
    _ shell: ShaarDevToolsModel, context: NativeBrowserContext, report: ShaarDevToolsSmokeReport
  ) async {
    guard shell.allowsWebKitComparison else {
      report.manual("round3-comparison", "Comparison is intentionally unavailable for private tabs")
      return
    }
    await show(.comparison, shell: shell, context: context, report: report)
    shell.comparison.refresh()
    let loaded = await wait(attempts: 120) {
      shell.comparison.chromiumPNG != nil && shell.comparison.webView != nil
    }
    row(loaded, "round3-comparison", "Chromium frame=\(shell.comparison.chromiumPNG != nil), WebKit view=\(shell.comparison.webView != nil), status=\(shell.comparison.status ?? "none")", report: report)
  }

  private static func roundThreeSensors(
    _ shell: ShaarDevToolsModel, inspector: InspectorModel, context: NativeBrowserContext,
    report: ShaarDevToolsSmokeReport
  ) async {
    await show(.sensors, shell: shell, context: context, report: report)
    shell.selectSensorLocation(.london)
    _ = try? await inspector.evaluate("navigator.geolocation.getCurrentPosition(p=>window.__shaarRound3Geo=p.coords.latitude+','+p.coords.longitude,e=>window.__shaarRound3Geo='error:'+e.message);true")
    var location: String?
    for _ in 0..<80 {
      location = try? await inspector.evaluate("window.__shaarRound3Geo") as? String
      if location != nil { break }
      try? await Task.sleep(for: .milliseconds(100))
    }
    row(location?.hasPrefix("51.5") == true, "round3-sensors-location",
        "Geolocation=\(location ?? "none")", report: report)
    shell.setSensorTouch(true)
    var touch: Any?
    for _ in 0..<50 {
      touch = try? await inspector.evaluate("Number(navigator.maxTouchPoints)")
      if let points = touch as? NSNumber, points.intValue > 0 { break }
      try? await Task.sleep(for: .milliseconds(100))
    }
    row((touch as? NSNumber)?.intValue ?? 0 > 0, "round3-sensors-touch",
        "Max touch points=\(String(describing: touch)), ready=\(shell.sensorTouchReady)", report: report)
    shell.selectSensorIdle(.idle)
    row(shell.sensorIdleReady, "round3-sensors-idle",
        "Idle ready=\(shell.sensorIdleReady), notice=\(String(describing: shell.sensorNotice))", report: report)
    shell.resetSensors()
  }

  private static func roundThreeCSS(
    _ shell: ShaarDevToolsModel, context: NativeBrowserContext, pageURL: URL,
    report: ShaarDevToolsSmokeReport
  ) async {
    await show(.cssOverview, shell: shell, context: context, report: report)
    await shell.cssOverview.reload(force: true)
    let summary = shell.cssOverview.summary
    row(shell.cssOverview.loaded && shell.cssOverview.failure == nil && summary.examined > 0,
        "round3-css-overview", "URL=\(pageURL.host ?? ""), loaded=\(shell.cssOverview.loaded), sheets=\(summary.examined), colors=\(summary.colors.count), fonts=\(summary.fonts.count), media=\(summary.media.count), failure=\(shell.cssOverview.failure ?? "none")", report: report)
  }

  private static func roundThreePerformance(
    _ shell: ShaarDevToolsModel, inspector: InspectorModel, context: NativeBrowserContext,
    report: ShaarDevToolsSmokeReport
  ) async {
    await show(.performance, shell: shell, context: context, report: report)
    shell.performance.startRecording()
    _ = try? await inspector.evaluate("(()=>{const end=performance.now()+80;while(performance.now()<end){};return true})()")
    try? await Task.sleep(for: .seconds(1))
    await shell.performance.refresh()
    shell.performance.stopRecording()
    row(!shell.performance.timelineTasks.isEmpty, "round3-performance-tasks",
        "Tasks=\(shell.performance.timelineTasks.count), recorded=\(shell.performance.recordedTasks.count), failure=\(shell.performance.failure ?? "none")", report: report)
    row(shell.performance.lcpMilliseconds != nil || shell.performance.fcpMilliseconds != nil,
        "round3-performance-vitals", "LCP=\(String(describing: shell.performance.lcpMilliseconds)), FCP=\(String(describing: shell.performance.fcpMilliseconds))", report: report)
  }
}
