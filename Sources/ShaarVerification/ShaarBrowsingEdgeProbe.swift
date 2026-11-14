// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import BrowserCore
import ChromiumBridge
import CoreFoundation
import Darwin
import Foundation

@testable import ArcusisBrowser

let browsingEdgeDialogNoteCap = 40
let browsingEdgeDialogSampleIntervalMs = 50

func browsingEdgeDialogSampleGap() -> String {
  "Sweeps are \(browsingEdgeDialogSampleIntervalMs) ms apart, so a shorter flash can be missed."
}

func browsingEdgeRecordNote(
  notes: inout [[String: String]], seen: inout Set<String>, dropped: inout Bool,
  note: [String: String], key: String
) {
  guard seen.insert(key).inserted else { return }
  guard notes.count < browsingEdgeDialogNoteCap else {
    dropped = true
    return
  }
  notes.append(note)
}

func browsingEdgePrintSurface(_ note: [String: String]) -> Bool {
  let name = (note["class"] ?? "").lowercased()
  let title = (note["title"] ?? "").lowercased()
  return name.contains("print") || title.contains("print")
}

func browsingEdgeFileChooserOpened(_ note: [String: String]) -> Bool {
  note["kind"] == "open-panel"
}

func browsingEdgeHiddenWindowsFailure(
  stillVisible: [String], notes: [[String: String]], notesDropped: Bool = false
) -> String? {
  let flashed = notes.compactMap { note -> String? in
    guard note["kind"] == "visible" else { return nil }
    let title = note["title"] ?? ""
    if !title.isEmpty { return title }
    let name = note["class"] ?? ""
    return name.isEmpty ? "window" : name
  }
  var parts: [String] = []
  if !flashed.isEmpty {
    parts.append("Visible during the run: \(flashed.joined(separator: ", "))")
  }
  if !stillVisible.isEmpty {
    parts.append("Still visible: \(stillVisible.joined(separator: ", "))")
  }
  if notesDropped {
    parts.append("Dialog note cap was hit, so a later window was not recorded")
  }
  if parts.isEmpty { return nil }
  return parts.joined(separator: ". ")
}

func browsingEdgeHiddenWindowsVerdict(
  stillVisible: [String], notes: [[String: String]], notesDropped: Bool
) -> (passed: Bool, detail: String) {
  let gap = browsingEdgeDialogSampleGap()
  if let failure = browsingEdgeHiddenWindowsFailure(
    stillVisible: stillVisible, notes: notes, notesDropped: notesDropped)
  {
    return (false, "\(failure). \(gap)")
  }
  return (true, "No window was left visible. \(gap)")
}

/// Records panels the probe asked for and cancels file choosers.
/// A visible browser window is left where it is, so the hidden-windows row can fail.
private final class DialogGuard: NSObject, @unchecked Sendable {
  private let lock = NSLock()
  private var running = false
  private var notes: [[String: String]] = []
  private var seen: Set<String> = []
  private var dropped = false

  func start() {
    lock.lock()
    if running {
      lock.unlock()
      return
    }
    running = true
    lock.unlock()
    Thread.detachNewThread { [weak self] in
      while let self, self.keepRunning {
        self.perform(
          #selector(sweepOnMain), on: Thread.main, with: nil, waitUntilDone: false,
          modes: [RunLoop.Mode.common.rawValue])
        Thread.sleep(forTimeInterval: Double(browsingEdgeDialogSampleIntervalMs) / 1000)
      }
    }
  }

  func stop() {
    lock.lock()
    running = false
    lock.unlock()
  }

  func snapshot() -> [[String: String]] {
    lock.lock()
    defer { lock.unlock() }
    return notes
  }

  func notesWereDropped() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return dropped
  }

  private var keepRunning: Bool {
    lock.lock()
    defer { lock.unlock() }
    return running
  }

  @MainActor
  @objc private func sweepOnMain() {
    guard keepRunning else { return }
    if let modal = NSApp.modalWindow {
      if let panel = modal as? NSSavePanel {
        recordChooser(panel)
      } else {
        record(modal, kind: "modal")
      }
    }
    for window in NSApp.windows {
      if let panel = window as? NSSavePanel {
        recordChooser(panel)
        continue
      }
      if let sheet = window.attachedSheet {
        record(sheet, kind: "sheet")
      }
      if window.isVisible {
        record(window, kind: "visible")
      }
    }
  }

  @MainActor
  private func recordChooser(_ panel: NSSavePanel) {
    let kind = panel is NSOpenPanel ? "open-panel" : "save-panel"
    record(panel, kind: kind)
    guard panel.isVisible else { return }
    panel.cancel(nil)
    panel.orderOut(nil)
  }

  @MainActor
  private func record(_ window: NSWindow, kind: String) {
    let text = labels(in: window).joined(separator: " ")
    let key = "\(kind)|\(window.className)|\(window.title)|\(text)"
    let note = [
      "kind": kind,
      "class": window.className,
      "title": window.title,
      "text": String(text.prefix(240)),
    ]
    lock.lock()
    defer { lock.unlock() }
    browsingEdgeRecordNote(notes: &notes, seen: &seen, dropped: &dropped, note: note, key: key)
  }

  @MainActor
  private func labels(in window: NSWindow) -> [String] {
    var values: [String] = []
    if let view = window.contentView { collect(view, into: &values) }
    return values
  }

  @MainActor
  private func collect(_ view: NSView, into values: inout [String]) {
    guard values.count < 12 else { return }
    if let text = view as? NSTextField, !text.stringValue.isEmpty {
      values.append(text.stringValue)
    }
    if let button = view as? NSButton, !button.title.isEmpty {
      values.append("button:\(button.title)")
    }
    for child in view.subviews { collect(child, into: &values) }
  }
}

/// Exercises heavy pages, dialogs, downloads, popups, find, zoom, print,
/// and renderer recovery in one hidden verification window.
@MainActor enum ShaarBrowsingEdgeProbe {
  private static let snapshotScript = """
    ({ready:document.documentElement.dataset.ready||'',\
    title:document.title||'',\
    text:(document.body&&document.body.innerText||'').replace(/\\s+/g,' ').slice(0,300),\
    href:location.href,\
    nodes:document.getElementsByTagName('*').length,\
    armed:document.documentElement.dataset.armed||''})
    """

  static func run(frameworkURL: URL, outputURL: URL, pageURL: URL?) -> Int32 {
    guard let pageURL, pageURL.scheme == "http", pageURL.host == "127.0.0.1" else { return 2 }
    let root = outputURL.deletingLastPathComponent().appending(path: "profile")
    do {
      let workspace = try BrowserWorkspaceStore(
        file: WorkspaceFile(
          url: root.appending(path: "workspace.json"),
          legacySessionURL: root.appending(path: "session.json")))
      let runtime = try ARCShaarRuntime(frameworkURL: frameworkURL)
      let host = NativeBrowserHost(
        events: BrowserRuntimeEvents(runtime: runtime), workspace: workspace,
        presentation: .hiddenProbe)
      let report = EdgeProbeReport(output: outputURL)
      runtime.onReady = { [weak host] in
        guard let host else { return }
        NSApp.setActivationPolicy(.prohibited)
        Task {
          await exercise(host: host, runtime: runtime, pageURL: pageURL, report: report)
        }
      }
      return withExtendedLifetime(host) {
        let dataRoot = outputURL.deletingLastPathComponent().appending(path: "Chromium")
        let code = runtime.run(withDataDirectory: dataRoot, testing: true)
        host.detach()
        return code
      }
    } catch {
      write(
        ["passed": false, "complete": true, "error": error.localizedDescription, "rows": []],
        to: outputURL)
      return 1
    }
  }

  private static func exercise(
    host: NativeBrowserHost, runtime: ARCShaarRuntime, pageURL: URL, report: EdgeProbeReport
  ) async {
    let dialogs = DialogGuard()
    defer {
      dialogs.stop()
      silenceRenderers()
      let hidden = NSApp.windows.allSatisfy { !$0.isVisible }
      report.finish(
        hidden: hidden, dialogs: dialogs.snapshot(),
        dialogsTruncated: dialogs.notesWereDropped())
      host.events.quit()
    }
    do {
      try host.restore()
    } catch {
      report.add(makeRow("Setup", false, error.localizedDescription))
      return
    }
    guard let context = host.contexts.values.first else {
      report.add(makeRow("Setup", false, "No hidden window"))
      return
    }
    dialogs.start()
    report.add(await checkFind(context, runtime, pageURL))
    report.add(await checkPageZoom(context, runtime))
    report.add(await checkPrint(dialogs))
    report.add(await checkHuge(context, runtime, pageURL))
    report.add(await checkScroll(context, runtime, pageURL))
    report.add(contentsOf: await checkMedia(context, runtime, pageURL))
    report.add(await checkMemory(context, runtime, pageURL))
    report.add(contentsOf: await checkHTTP(context, runtime, pageURL))
    report.add(await checkSlowDownload(context, pageURL))
    report.add(await checkDownloadLink(context, runtime, pageURL))
    report.add(contentsOf: await checkPopups(context, runtime, pageURL))
    report.add(await checkHang(context, runtime, pageURL))
    report.add(await checkCrash(context))
    report.add(contentsOf: await checkDialogs(context, runtime, pageURL, dialogs))
    cancelActiveDownloads(context)
    let stray = visibleWindowLabels()
    let notes = dialogs.snapshot()
    let verdict = browsingEdgeHiddenWindowsVerdict(
      stillVisible: stray, notes: notes, notesDropped: dialogs.notesWereDropped())
    report.add(makeRow("Hidden windows", verdict.passed, verdict.detail))
  }

  private static func checkPageZoom(
    _ context: NativeBrowserContext, _ runtime: ARCShaarRuntime
  ) async -> [String: Any] {
    let view = menuTitles(menuID: "View")
    let before = await pageScale(runtime, context)
    guard let item = firstItem(where: isPageZoom) else {
      return makeRow("Page zoom", false, "No Zoom In command to invoke. View: \(view).")
    }
    let title = item.title
    let sent = perform(item)
    try? await Task.sleep(for: .milliseconds(400))
    let after = await pageScale(runtime, context)
    let changed = scaleChanged(before, after)
    let hidden = windowsHidden()
    return makeRow(
      "Page zoom", sent && changed && hidden,
      "invoked \(title), sent \(sent), scale \(scaleText(before)) to \(scaleText(after)), hidden \(hidden)"
    )
  }

  private static func checkPrint(_ dialogs: DialogGuard) async -> [String: Any] {
    let file = menuTitles(menuID: "File")
    guard let item = firstItem(where: isPrintCommand) else {
      return makeRow("Print", false, "No Print command to invoke. File: \(file).")
    }
    let title = item.title
    let before = dialogs.snapshot().count
    let sent = perform(item)
    try? await Task.sleep(for: .milliseconds(500))
    let fresh = Array(dialogs.snapshot().dropFirst(before))
    let panel = fresh.contains(where: browsingEdgePrintSurface)
    dismissPrintSurfaces()
    let hidden = windowsHidden()
    return makeRow(
      "Print", sent && panel && hidden,
      "invoked \(title), sent \(sent), panel \(panel), hidden \(hidden), \(describe(fresh))")
  }

  private static func pageScale(
    _ runtime: ARCShaarRuntime, _ context: NativeBrowserContext
  ) async -> Double? {
    let json = await evaluate(
      runtime, tab: selectedID(context), script: "({scale:window.devicePixelRatio})", seconds: 3)
    return Self.pageScale(from: json)
  }

  static func pageScale(from json: String?) -> Double? {
    guard let value = object(from: json)?["scale"],
      let number = value as? NSNumber,
      CFGetTypeID(number) != CFBooleanGetTypeID(),
      number.doubleValue.isFinite,
      number.doubleValue > 0
    else { return nil }
    return number.doubleValue
  }

  private static func scaleChanged(_ before: Double?, _ after: Double?) -> Bool {
    guard let before, let after else { return false }
    return abs(after - before) > 0.05
  }

  private static func scaleText(_ value: Double?) -> String {
    guard let value else { return "nil" }
    return String(format: "%.3f", value)
  }

  private static func dismissPrintSurfaces() {
    for window in NSApp.windows where window.className.lowercased().contains("print") {
      window.orderOut(nil)
    }
  }

  private static func perform(_ item: NSMenuItem) -> Bool {
    guard let action = item.action else { return false }
    return NSApp.sendAction(action, to: item.target, from: item)
  }

  private static func menuTitles(menuID: String) -> String {
    menuLines().filter { $0.menuID == menuID }.map(\.title).joined(separator: ", ")
  }

  private static func isPageZoom(_ item: MenuLine) -> Bool {
    let title = item.title.lowercased()
    let itemID = item.itemID.lowercased()
    if title.contains("zoom in") || title.contains("zoom out") || title.contains("actual size")
      || itemID.contains("zoom in") || itemID.contains("zoom out") || itemID.contains("actual size")
    {
      return true
    }
    let inView = item.menuID == "View"
    let key = item.key.lowercased()
    let command = item.modifiers.contains(.command)
    let zoomKey = key == "=" || key == "-" || key == "+" || key == "0"
    return inView && command && zoomKey
  }

  private static func isPrintCommand(_ item: MenuLine) -> Bool {
    let title = item.title.lowercased()
    let itemID = item.itemID.lowercased()
    for value in [title, itemID] {
      if value == "print" || value == "print…" || value == "print..." || value.hasPrefix("print ") {
        return true
      }
    }
    return false
  }

  private static func checkFind(
    _ context: NativeBrowserContext, _ runtime: ARCShaarRuntime, _ page: URL
  ) async -> [String: Any] {
    guard await open(context, runtime, page, path: "/find", marker: "find") else {
      return makeRow("Find in page", false, "Find page did not commit")
    }
    let store = context.store
    guard store.canFindCurrentPage else {
      return makeRow("Find in page", false, "Find is unavailable on the current page")
    }
    store.showPageFind()
    store.updatePageFindQuery("OrbitFindMarker")
    let found = await wait(seconds: 8) {
      store.pageFind?.matchCount == 3 && store.pageFind?.canMove == true
    }
    let first = store.pageFind?.activeMatch ?? -1
    if found { store.movePageFind(forward: true) }
    let advanced = await wait(seconds: 4) {
      guard let state = store.pageFind else { return false }
      return state.matchCount == 3 && state.activeMatch != first && state.activeMatch > 0
    }
    let moved = found && advanced
    store.updatePageFindQuery("zzzz-no-such-edge-token")
    let empty = await wait(seconds: 4) {
      store.pageFind?.matchCount == 0 && store.pageFind?.searching == false
    }
    store.dismissPageFind()
    let closed = store.pageFind == nil
    let passed = found && moved && empty && closed && windowsHidden()
    return makeRow(
      "Find in page", passed,
      "three matches \(found), next \(moved), none \(empty), closed \(closed), status \(store.pageFind?.status ?? "closed")"
    )
  }

  private static func checkHuge(
    _ context: NativeBrowserContext, _ runtime: ARCShaarRuntime, _ page: URL
  ) async -> [String: Any] {
    let started = Date()
    guard await open(context, runtime, page, path: "/huge", marker: "huge") else {
      return makeRow("Huge DOM", false, "Huge page did not become ready")
    }
    let before = residentMegabytes()
    let last = await evaluate(
      runtime, tab: selectedID(context),
      script:
        "document.getElementById('last-row') ? document.getElementById('last-row').textContent : ''",
      seconds: 8)
    let after = residentMegabytes()
    let ping = await evaluate(runtime, tab: selectedID(context), script: "({ok:true})", seconds: 3)
    let text = last?.replacingOccurrences(of: "\"", with: "")
    let passed = text == "row 14999" && ping != nil && failure(context) == nil && windowsHidden()
    let ms = Int(Date().timeIntervalSince(started) * 1000)
    return makeRow(
      "Huge DOM", passed,
      "last \(text ?? "missing"), responsive \(ping != nil), \(ms) ms, resident \(before) to \(after) MB"
    )
  }

  private static func checkScroll(
    _ context: NativeBrowserContext, _ runtime: ARCShaarRuntime, _ page: URL
  ) async -> [String: Any] {
    guard await open(context, runtime, page, path: "/scroll", marker: "scroll") else {
      return makeRow("Infinite scroll", false, "Scroll page did not become ready")
    }
    let first = await scrollState(runtime, context)
    try? await Task.sleep(for: .milliseconds(400))
    let second = await scrollState(runtime, context)
    let ping = await evaluate(runtime, tab: selectedID(context), script: "({ok:true})", seconds: 3)
    let firstCount = number(first?["count"]) ?? 0
    let secondCount = number(second?["count"]) ?? 0
    let height = number(second?["height"]) ?? 0
    let client = number(second?["client"]) ?? 0
    let top = number(second?["top"]) ?? 0
    let frames = number(second?["frames"]) ?? 0
    let scrollEvents = number(second?["scrollEvents"]) ?? 0
    let scrollEndEvents = number(second?["scrollEndEvents"]) ?? 0
    let scrollable = height > client + 40 && top > 0
    let grew = secondCount >= firstCount + 200
    guard frames > 0 else {
      return makeRow(
        "Infinite scroll", false,
        "Hidden window produced no frames. rows \(firstCount), top \(top), height \(height), client \(client)",
        proven: false)
    }
    guard scrollable || grew else {
      return makeRow(
        "Infinite scroll", false,
        "Box did not scroll. rows \(firstCount), top \(top), height \(height), client \(client), frames \(frames)",
        proven: false)
    }
    let passed =
      grew && scrollEvents > 0 && scrollEndEvents > 0 && ping != nil
      && failure(context) == nil && windowsHidden()
    return makeRow(
      "Infinite scroll", passed,
      "rows \(firstCount) then \(secondCount), scroll events \(scrollEvents), scrollend events \(scrollEndEvents), top \(top), height \(height), client \(client), frames \(frames), responsive \(ping != nil)",
      proven: scrollFailureIsAttributable(scrollEvents: scrollEvents)
    )
  }

  private static func scrollState(_ runtime: ARCShaarRuntime, _ context: NativeBrowserContext) async
    -> [String: Any]?
  {
    let json = await evaluate(
      runtime, tab: selectedID(context),
      script: """
        (()=>{const root=document.getElementById('root'); if(!root) return {count:0,top:0,height:0,client:0};
        const last=root.lastElementChild; if(last) last.scrollIntoView({block:'end'});
        root.scrollTop=root.scrollHeight;
        return {count:root.children.length,top:root.scrollTop,height:root.scrollHeight,client:root.clientHeight,frames:window.__frames||0,scrollEvents:window.__scrollEvents||0,scrollEndEvents:window.__scrollEndEvents||0};})()
        """,
      seconds: 5)
    return object(from: json)
  }

  private static func checkMedia(
    _ context: NativeBrowserContext, _ runtime: ARCShaarRuntime, _ page: URL
  ) async -> [[String: Any]] {
    guard await open(context, runtime, page, path: "/media", marker: "media") else {
      let snap = await snapshot(runtime, context)
      let detail = "Media page did not become ready. \(snap["text"] as? String ?? "")"
      return [
        makeRow("WebGL", false, detail),
        makeRow("Video", false, detail),
      ]
    }
    let json = await evaluate(
      runtime, tab: selectedID(context), script: "window.__edgeMedia || {}", seconds: 5)
    let media = object(from: json) ?? [:]
    let pixel = numbers(media["pixel"])
    let webgl = flag(media["webgl"]) == true
    let video = videoIsPlaying(media)
    let vendor = media["vendor"] as? String ?? ""
    let error = media["error"] as? String ?? ""
    return [
      makeRow(
        "WebGL", webgl && failure(context) == nil && windowsHidden(),
        "context \(webgl), vendor \(vendor), pixel \(pixel), \(error)"),
      makeRow(
        "Video", video && failure(context) == nil && windowsHidden(),
        "playing \(video), width \(media["videoWidth"] ?? ""), paused \(media["paused"] ?? ""), \(error)"
      ),
    ]
  }

  private static func checkMemory(
    _ context: NativeBrowserContext, _ runtime: ARCShaarRuntime, _ page: URL
  ) async -> [String: Any] {
    let before = residentMegabytes()
    guard await open(context, runtime, page, path: "/memory", marker: "memory") else {
      let dead = failure(context)
      return makeRow(
        "Memory hog", false,
        dead == nil
          ? "Memory page did not become ready"
          : "Renderer died while allocating (\(dead?.status ?? ""))")
    }
    let json = await evaluate(
      runtime, tab: selectedID(context),
      script:
        "({bytes:Number(document.documentElement.dataset.bytes||0), sentinel:window.__hog&&window.__hog[0]?window.__hog[0][0]:-1, error:document.documentElement.dataset.error||''})",
      seconds: 8)
    let state = object(from: json) ?? [:]
    let bytes = number(state["bytes"]) ?? 0
    let sentinel = number(state["sentinel"]) ?? -1
    let allocationError = state["error"] as? String ?? ""
    _ = await evaluate(
      runtime, tab: selectedID(context), script: "window.__hog=null;({released:true})", seconds: 4)
    let after = residentMegabytes()
    if !allocationError.isEmpty && bytes < 192 * 1024 * 1024 {
      return makeRow(
        "Memory hog", false,
        "Allocation did not stick: \(allocationError). Resident \(before) to \(after) MB",
        proven: false)
    }
    let passed =
      bytes >= 192 * 1024 * 1024 && sentinel == 7 && failure(context) == nil && windowsHidden()
    return makeRow(
      "Memory hog", passed,
      "allocated \(bytes) bytes, sentinel \(sentinel), resident \(before) to \(after) MB")
  }

  private static func checkHTTP(
    _ context: NativeBrowserContext, _ runtime: ARCShaarRuntime, _ page: URL
  ) async -> [[String: Any]] {
    let notFound = await httpRow(
      context, runtime, page, path: "/http/404", name: "HTTP 404", needle: "edge-http-404")
    let failed = await httpRow(
      context, runtime, page, path: "/http/500", name: "HTTP 500", needle: "edge-http-500")
    let offline = await unreachableRow(context, runtime)
    return [notFound, failed, offline]
  }

  private static func httpRow(
    _ context: NativeBrowserContext, _ runtime: ARCShaarRuntime, _ page: URL, path: String,
    name: String, needle: String
  ) async -> [String: Any] {
    _ = await open(context, runtime, page, path: path, marker: nil)
    let snap = await snapshot(runtime, context)
    let text = pageText(snap, context)
    let href = snap["href"] as? String ?? shellURL(context)
    let shown = text.contains(needle)
    return makeRow(name, shown && windowsHidden(), "href \(href) text \(text)")
  }

  private static func unreachableRow(
    _ context: NativeBrowserContext, _ runtime: ARCShaarRuntime
  ) async -> [String: Any] {
    guard let url = URL(string: "http://127.0.0.1:3999/edge-offline") else {
      return makeRow(
        "Unreachable host", false, "Could not build the closed-port URL", proven: false)
    }
    context.store.perform(.open(url))
    _ = await wait(seconds: 12) {
      guard let tab = selectedID(context) else { return false }
      return context.engine.pages[tab]?.loading == false
    }
    let snap = await snapshot(runtime, context)
    let combined = pageText(snap, context)
    let title = snap["title"] as? String ?? context.store.session.selectedPage?.tab.title ?? ""
    let signs = [
      "refused", "unreachable", "offline", "err_", "can't", "can’t", "cannot", "timed out",
      "not available",
    ]
    let shown = signs.contains { combined.contains($0) }
    let stayed = combined.contains("orbitfindmarker") || combined.contains("edge-http-500")
    return makeRow(
      "Unreachable host", shown && !stayed && windowsHidden(),
      "title \(title) text \(combined)")
  }

  private static func checkSlowDownload(_ context: NativeBrowserContext, _ page: URL) async
    -> [String: Any]
  {
    guard let url = url(page, "/files/slow.bin") else {
      return makeRow("Download", false, "Could not build the download URL", proven: false)
    }
    let profile = context.store.session.selectedSpace.profileID
    let prior = Set(downloadItems(context, profile).map(\.id))
    context.store.perform(.open(url))
    let appeared = await wait(seconds: 12) {
      context.engine.runtime.refreshDownloads(forProfileID: profile.uuidString)
      return downloadItems(context, profile).contains {
        !prior.contains($0.id) && $0.receivedBytes > 0
      }
    }
    guard appeared,
      var item = downloadItems(context, profile).first(where: { !prior.contains($0.id) })
    else {
      return makeRow("Download", false, "Opening an attachment URL did not start a download")
    }
    var pauseDetail = "pause not reached"
    if item.state == .downloading && !item.paused {
      let asked = context.engine.downloads.perform(
        .pause, id: item.id, profileID: profile, selectedProfileID: profile)
      let held = await wait(seconds: 6) {
        context.engine.runtime.refreshDownloads(forProfileID: profile.uuidString)
        return downloadItems(context, profile).first { $0.id == item.id }?.paused == true
      }
      let pausedBytes =
        downloadItems(context, profile).first { $0.id == item.id }?.receivedBytes ?? 0
      try? await Task.sleep(for: .milliseconds(800))
      let later = downloadItems(context, profile).first { $0.id == item.id }?.receivedBytes ?? 0
      pauseDetail = "pause asked \(asked), held \(held), bytes \(pausedBytes) to \(later)"
      if held {
        _ = context.engine.downloads.perform(
          .resume, id: item.id, profileID: profile, selectedProfileID: profile)
      }
    }
    context.store.showDownloads()
    let showed =
      context.store.sheet.map { sheet in
        if case .downloads = sheet { return true }
        return false
      } ?? false
    context.store.sheet = nil
    context.store.sheetDidDismiss()
    let finished = await wait(seconds: 30) {
      context.engine.runtime.refreshDownloads(forProfileID: profile.uuidString)
      return downloadItems(context, profile).first { $0.id == item.id }?.state == .finished
    }
    item = downloadItems(context, profile).first { $0.id == item.id } ?? item
    let bytes = fileBytes(item.fileURL)
    let good =
      bytes?.starts(with: Data("edge-download-ok\n".utf8)) == true && bytes?.count == 256 * 1024
    removeOwnedDownload(item.fileURL)
    let passed = finished && showed && good && !item.dangerous && windowsHidden()
    return makeRow(
      "Download", passed,
      "\(pauseDetail); sheet \(showed); finished \(finished); bytes \(bytes?.count ?? -1); dangerous \(item.dangerous); path \(item.fileURL?.path ?? "")"
    )
  }

  private static func checkDownloadLink(
    _ context: NativeBrowserContext, _ runtime: ARCShaarRuntime, _ page: URL
  ) async -> [String: Any] {
    guard await open(context, runtime, page, path: "/download", marker: "download") else {
      return makeRow("Download link", false, "Download page did not commit")
    }
    let profile = context.store.session.selectedSpace.profileID
    let prior = Set(downloadItems(context, profile).map(\.id))
    let clicked = await click(runtime, tab: selectedID(context), element: "popup")
    let appeared = await wait(seconds: 10) {
      context.engine.runtime.refreshDownloads(forProfileID: profile.uuidString)
      return downloadItems(context, profile).contains { !prior.contains($0.id) }
    }
    let item = downloadItems(context, profile).first { !prior.contains($0.id) }
    let finished = await wait(seconds: 8) {
      guard let item else { return false }
      context.engine.runtime.refreshDownloads(forProfileID: profile.uuidString)
      return downloadItems(context, profile).first { $0.id == item.id }?.state == .finished
    }
    let bytes = fileBytes(item?.fileURL)
    let good = bytes == Data("edge-small-ok\n".utf8)
    removeOwnedDownload(item?.fileURL)
    return makeRow(
      "Download link", clicked && appeared && finished && good && windowsHidden(),
      "clicked \(clicked), started \(appeared), finished \(finished), bytes \(bytes?.count ?? -1)",
      proven: clicked)
  }

  private static func checkPopups(
    _ context: NativeBrowserContext, _ runtime: ARCShaarRuntime, _ page: URL
  ) async -> [[String: Any]] {
    guard await open(context, runtime, page, path: "/popups", marker: "popups") else {
      return [makeRow("window.open", false, "Popup page did not commit")]
    }
    var rows: [[String: Any]] = []
    for (name, element) in [("target=_blank", "blank"), ("window.open", "popup")] {
      let before = tabIDs(context)
      let clicked = await click(runtime, tab: selectedID(context), element: element)
      let adopted = await wait(seconds: 8) {
        tabIDs(context).subtracting(before).isEmpty == false
      }
      let created = tabIDs(context).subtracting(before)
      let destination = await destinationReady(runtime, context, ids: created)
      let sameWindow = created.allSatisfy { id in
        runtime.windowID(forTabID: id.uuidString) == context.nativeID
      }
      rows.append(
        makeRow(
          name, clicked && adopted && destination && sameWindow && windowsHidden(),
          "clicked \(clicked), adopted \(adopted), destination \(destination), same window \(sameWindow), tabs \(created.count)",
          proven: clicked))
      await closeTabs(context, created)
    }
    let before = tabIDs(context)
    let opened = await evaluate(
      runtime, tab: selectedID(context),
      script: "({opened:!!window.open('/popup-dest?ungestured=1','_blank')})",
      seconds: 4)
    let state = object(from: opened)
    let newTabs = tabIDs(context).subtracting(before)
    let blocked = flag(state?["opened"]) == false && newTabs.isEmpty && windowsHidden()
    rows.append(
      makeRow(
        "Popup without a gesture", blocked,
        "script opened \(state?["opened"] ?? "timeout"), new tabs \(newTabs.count)"))
    await closeTabs(context, newTabs)
    return rows
  }

  private static func checkDialogs(
    _ context: NativeBrowserContext, _ runtime: ARCShaarRuntime, _ page: URL, _ dialogs: DialogGuard
  ) async -> [[String: Any]] {
    guard await open(context, runtime, page, path: "/dialogs", marker: "dialogs") else {
      return [makeRow("JavaScript dialogs", false, "Dialog page did not commit")]
    }
    var rows: [[String: Any]] = []
    rows.append(
      await dialogCall(
        context, runtime, dialogs, name: "alert",
        script:
          "(()=>{window.__edgeDialog='started'; alert('edge-alert'); window.__edgeDialog='returned'; return {stage:'returned'};})()"
      ))
    rows.append(
      await dialogCall(
        context, runtime, dialogs, name: "confirm",
        script:
          "(()=>{window.__edgeDialog='started'; const value=confirm('edge-confirm'); window.__edgeDialog='returned'; return {stage:'returned', value:value};})()"
      ))
    rows.append(
      await dialogCall(
        context, runtime, dialogs, name: "prompt",
        script:
          "(()=>{window.__edgeDialog='started'; const value=prompt('edge-prompt',''); window.__edgeDialog='returned'; return {stage:'returned', value:value===null?'cancelled':String(value)};})()"
      ))
    rows.append(await checkBeforeUnload(context, runtime, page, dialogs))
    rows.append(await checkAuth(context, runtime, page, dialogs))
    rows.append(await checkFilePicker(context, runtime, page, dialogs))
    return rows
  }

  private static func dialogCall(
    _ context: NativeBrowserContext, _ runtime: ARCShaarRuntime, _ dialogs: DialogGuard,
    name: String, script: String
  ) async -> [String: Any] {
    let before = dialogs.snapshot().count
    let json = await evaluate(runtime, tab: selectedID(context), script: script, seconds: 4)
    let fresh = dialogNotes(Array(dialogs.snapshot().dropFirst(before)))
    let returned = object(from: json)?["stage"] as? String == "returned"
    if json == nil { await recover(context, runtime) }
    let hidden = windowsHidden()
    let passed = !fresh.isEmpty && returned && hidden
    return makeRow(
      name, passed,
      "dialog \(fresh.count), returned \(returned), hidden \(hidden), \(describe(fresh))")
  }

  private static func checkBeforeUnload(
    _ context: NativeBrowserContext, _ runtime: ARCShaarRuntime, _ page: URL, _ dialogs: DialogGuard
  ) async -> [String: Any] {
    guard await open(context, runtime, page, path: "/dialogs", marker: "dialogs") else {
      return makeRow("beforeunload", false, "Could not return to the dialog page")
    }
    let clicked = await click(runtime, tab: selectedID(context), element: "performance-input")
    var armSnap = await snapshot(runtime, context)
    let armDeadline = Date().addingTimeInterval(4)
    while armSnap["armed"] as? String != "1" && Date() < armDeadline {
      try? await Task.sleep(for: .milliseconds(100))
      armSnap = await snapshot(runtime, context)
    }
    let isArmed = armSnap["armed"] as? String == "1"
    let before = dialogs.snapshot().count
    guard let away = url(page, "/find") else {
      return makeRow("beforeunload", false, "Could not build the next URL", proven: false)
    }
    _ = await open(context, runtime, away, path: "/find", marker: nil)
    let fresh = dialogNotes(Array(dialogs.snapshot().dropFirst(before)))
    let snap = await snapshot(runtime, context)
    let left =
      (snap["ready"] as? String) == "find" || (snap["href"] as? String ?? "").contains("/find")
    let exercised = clicked && isArmed
    let hidden = windowsHidden()
    let passed = beforeUnloadProbePassed(
      exercised: exercised, dialogCount: fresh.count, navigated: left, windowsHidden: hidden)
    return makeRow(
      "beforeunload", passed,
      "clicked \(clicked), armed \(isArmed), dialog \(fresh.count), navigated \(left), hidden \(hidden), \(describe(fresh))",
      proven: exercised)
  }

  private static func checkAuth(
    _ context: NativeBrowserContext, _ runtime: ARCShaarRuntime, _ page: URL, _ dialogs: DialogGuard
  ) async -> [String: Any] {
    guard let auth = url(page, "/auth") else {
      return makeRow("Auth prompt", false, "Could not build the auth URL", proven: false)
    }
    let before = dialogs.snapshot().count
    context.store.perform(.open(stamped(auth) ?? auth))
    _ = await wait(seconds: 8) {
      guard let tab = selectedID(context) else { return false }
      return context.engine.pages[tab]?.loading == false
    }
    let fresh = dialogNotes(Array(dialogs.snapshot().dropFirst(before)))
    let snap = await snapshot(runtime, context)
    let text = pageText(snap, context)
    return makeRow(
      "Auth prompt", !fresh.isEmpty && windowsHidden(),
      "dialogs \(fresh.count), hidden \(windowsHidden()), text \(text), \(describe(fresh))")
  }

  private static func checkFilePicker(
    _ context: NativeBrowserContext, _ runtime: ARCShaarRuntime, _ page: URL, _ dialogs: DialogGuard
  ) async -> [String: Any] {
    guard await open(context, runtime, page, path: "/dialogs", marker: "dialogs") else {
      return makeRow("File picker", false, "Could not return to the file input")
    }
    let before = dialogs.snapshot().count
    let clicked = await click(runtime, tab: selectedID(context), element: "blank")
    try? await Task.sleep(for: .milliseconds(600))
    let fresh = Array(dialogs.snapshot().dropFirst(before))
    let opened = fresh.contains(where: browsingEdgeFileChooserOpened)
    return makeRow(
      "File picker", clicked && opened && windowsHidden(),
      "clicked \(clicked), chooser \(opened), hidden \(windowsHidden()), \(describe(fresh))",
      proven: clicked)
  }

  private static func checkHang(
    _ context: NativeBrowserContext, _ runtime: ARCShaarRuntime, _ page: URL
  ) async -> [String: Any] {
    guard await open(context, runtime, page, path: "/hang", marker: "hang") else {
      return makeRow("Hang recovery", false, "Hang page did not commit", proven: false)
    }
    try? await Task.sleep(for: .milliseconds(800))
    let wedged =
      await evaluate(runtime, tab: selectedID(context), script: "({ping:1})", seconds: 2) == nil
    guard wedged else {
      return makeRow(
        "Hang recovery", false, "The page stayed responsive, so hang recovery was not proven",
        proven: false)
    }
    let reloaded = context.store.reloadCurrentPage()
    var recovered = await ping(runtime, context, seconds: 12)
    var how = "reload"
    if !recovered {
      let restarted = context.store.reloadCurrentPage(.newRenderer)
      recovered = await ping(runtime, context, seconds: 12)
      how = "restart page asked \(restarted)"
    }
    if !recovered { await killRenderers() }
    let passed = wedged && reloaded && recovered && windowsHidden()
    return makeRow(
      "Hang recovery", passed,
      "wedged \(wedged), reload asked \(reloaded), recovered \(recovered) via \(how)")
  }

  private static func checkCrash(_ context: NativeBrowserContext) async -> [String: Any] {
    guard let tab = selectedID(context) else {
      return makeRow("Sad tab", false, "No selected tab", proven: false)
    }
    let pids = rendererProcessIDs()
    guard !pids.isEmpty else {
      return makeRow("Sad tab", false, "No renderer process belonged to this app", proven: false)
    }
    probeNote("Sad tab: killing \(pids)")
    var killed: [Int32] = []
    var died = false
    for pid in pids.prefix(4) {
      await killProcess(pid)
      killed.append(pid)
      died = await wait(seconds: 3) { context.store.rendererFailures[tab] != nil }
      if died { break }
    }
    guard died, let failure = context.store.rendererFailures[tab] else {
      return makeRow(
        "Sad tab", false,
        "Killing renderers \(killed) did not show a failed page")
    }
    probeNote("Sad tab: reloading")
    let started = context.store.reloadFailedPage(failure.id)
    let restored = await wait(seconds: 8) {
      context.store.rendererFailures[tab] == nil && context.engine.pages[tab]?.loading == false
    }
    return makeRow(
      "Sad tab", started && restored && windowsHidden(),
      "status \(failure.status), reload \(started), restored \(restored), killed \(killed)")
  }

  private static func recover(_ context: NativeBrowserContext, _ runtime: ARCShaarRuntime) async {
    if context.store.reloadCurrentPage() == false {
      _ = context.store.reloadCurrentPage(.newRenderer)
    }
    let back = await ping(runtime, context, seconds: 8)
    if !back { await killRenderers() }
  }

  private static func ping(
    _ runtime: ARCShaarRuntime, _ context: NativeBrowserContext, seconds: Double
  ) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
      if await evaluate(runtime, tab: selectedID(context), script: "({ping:1})", seconds: 2) != nil
      {
        return true
      }
      try? await Task.sleep(for: .milliseconds(200))
    }
    return false
  }

  private static func destinationReady(
    _ runtime: ARCShaarRuntime, _ context: NativeBrowserContext, ids: Set<UUID>
  ) async -> Bool {
    for id in ids {
      let json = await evaluate(
        runtime, tab: id,
        script:
          "({marker:document.getElementById('destination')?document.getElementById('destination').innerText:''})",
        seconds: 4)
      if object(from: json)?["marker"] as? String == "Popup destination loaded" { return true }
    }
    return false
  }

  private static func open(
    _ context: NativeBrowserContext, _ runtime: ARCShaarRuntime, _ page: URL,
    path: String, marker: String?
  ) async -> Bool {
    guard let target = url(page, path), let stamped = stamped(target) else { return false }
    let nonce = stamped.query ?? ""
    context.store.perform(.open(stamped))
    let committed = await wait(seconds: 20) {
      guard let tab = context.engine.siteControlTarget else { return false }
      let href = tab.url.absoluteString
      let onNonce = href.contains(nonce)
      let strippedError = marker == nil && tab.url.path == path && !href.contains("n=")
      guard onNonce || strippedError else { return false }
      return context.engine.pages[tab.tabID]?.loading == false
    }
    guard committed else { return false }
    guard let marker else { return true }
    let deadline = Date().addingTimeInterval(20)
    while Date() < deadline {
      if failure(context) != nil { return false }
      let snap = await snapshot(runtime, context)
      if snap["ready"] as? String == marker { return true }
      try? await Task.sleep(for: .milliseconds(100))
    }
    return false
  }

  private static func snapshot(_ runtime: ARCShaarRuntime, _ context: NativeBrowserContext) async
    -> [String: Any]
  {
    let json = await evaluate(runtime, tab: selectedID(context), script: snapshotScript, seconds: 5)
    return object(from: json) ?? [:]
  }

  private static func evaluate(
    _ runtime: ARCShaarRuntime, tab: UUID?, script: String, seconds: Double
  ) async -> String? {
    guard let tab else { return nil }
    return await withCheckedContinuation { continuation in
      let once = EdgeProbeOnce()
      runtime.evaluate(inTabID: tab.uuidString, script: script) { value in
        if once.claim() { continuation.resume(returning: value) }
      }
      Task {
        try? await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
        if once.claim() { continuation.resume(returning: nil) }
      }
    }
  }

  private static func click(_ runtime: ARCShaarRuntime, tab: UUID?, element: String) async -> Bool {
    guard let tab else { return false }
    return await withCheckedContinuation { continuation in
      let once = EdgeProbeOnce()
      runtime.submitTrustedProbeClick(inTabID: tab.uuidString, elementID: element) { value in
        if once.claim() { continuation.resume(returning: value) }
      }
      Task {
        try? await Task.sleep(for: .seconds(8))
        if once.claim() { continuation.resume(returning: false) }
      }
    }
  }

  private static func wait(seconds: Double, _ condition: () -> Bool) async -> Bool {
    let steps = Int(seconds * 10)
    for _ in 0..<steps {
      if condition() { return true }
      try? await Task.sleep(for: .milliseconds(100))
    }
    return condition()
  }

  private static func selectedID(_ context: NativeBrowserContext) -> UUID? {
    context.store.session.selectedPage?.tab.id
  }

  private static func tabIDs(_ context: NativeBrowserContext) -> Set<UUID> {
    Set(context.store.session.spaces.flatMap { $0.tabs.map(\.id) })
  }

  private static func closeTabs(_ context: NativeBrowserContext, _ ids: Set<UUID>) async {
    for id in ids { context.store.closeTab(id) }
    _ = await wait(seconds: 4) {
      tabIDs(context).isDisjoint(with: ids)
    }
  }

  private static func failure(_ context: NativeBrowserContext) -> RendererFailure? {
    guard let tab = selectedID(context) else { return nil }
    return context.store.rendererFailures[tab]
  }

  private static func downloadItems(_ context: NativeBrowserContext, _ profile: UUID)
    -> [BrowserDownload]
  {
    context.engine.downloads.items(in: profile)
  }

  private static func cancelActiveDownloads(_ context: NativeBrowserContext) {
    let profile = context.store.session.selectedSpace.profileID
    for item in downloadItems(context, profile) {
      if item.state == .downloading {
        _ = context.engine.downloads.perform(
          .cancel, id: item.id, profileID: profile, selectedProfileID: profile)
      }
      removeOwnedDownload(item.fileURL)
    }
  }

  private static func removeOwnedDownload(_ url: URL?) {
    guard let url else { return }
    let name = url.lastPathComponent
    guard name.contains("edge-slow") || name.contains("edge-small") else { return }
    guard let bytes = try? Data(contentsOf: url) else { return }
    let slow = Data("edge-download-ok\n".utf8)
    let small = Data("edge-small-ok\n".utf8)
    guard bytes.starts(with: slow) || bytes.starts(with: small) else { return }
    try? FileManager.default.removeItem(at: url)
  }

  private static func fileBytes(_ url: URL?) -> Data? {
    guard let url else { return nil }
    return try? Data(contentsOf: url)
  }

  private static func url(_ page: URL, _ path: String) -> URL? {
    guard var components = URLComponents(url: page, resolvingAgainstBaseURL: false) else {
      return nil
    }
    components.path = path
    components.query = nil
    components.fragment = nil
    return components.url
  }

  private static func stamped(_ url: URL) -> URL? {
    guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
      return nil
    }
    var items = components.queryItems ?? []
    items.append(URLQueryItem(name: "n", value: UUID().uuidString))
    components.queryItems = items
    return components.url
  }

  static func object(from json: String?) -> [String: Any]? {
    guard let data = json?.data(using: .utf8) else { return nil }
    return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
  }

  private static func probeNote(_ text: String) {
    FileHandle.standardError.write(Data("\(text)\n".utf8))
  }

  private static func windowsHidden() -> Bool {
    NSApp.windows.allSatisfy { !$0.isVisible }
  }

  private static func shellURL(_ context: NativeBrowserContext) -> String {
    context.store.session.selectedPage?.tab.url.absoluteString ?? ""
  }

  private static func pageText(_ snap: [String: Any], _ context: NativeBrowserContext) -> String {
    let title = context.store.session.selectedPage?.tab.title ?? ""
    let parts = [snap["text"] as? String ?? "", snap["title"] as? String ?? "", title]
    return parts.joined(separator: " ").lowercased()
  }

  private static func dialogNotes(_ notes: [[String: String]]) -> [[String: String]] {
    notes.filter { note in
      let kind = note["kind"] ?? ""
      if kind == "modal" || kind == "sheet" || kind == "open-panel" || kind == "save-panel" {
        return true
      }
      let text = ((note["text"] ?? "") + " " + (note["title"] ?? "")).lowercased()
      let hints = [
        "edge-alert", "edge-confirm", "edge-prompt", "leave", "sign in",
        "authentication", "password", "user name", "username",
      ]
      return hints.contains { text.contains($0) }
    }
  }

  private static func visibleWindowLabels() -> [String] {
    NSApp.windows.filter(\.isVisible).map { window in
      window.title.isEmpty ? window.className : window.title
    }
  }

  private static func describe(_ notes: [[String: String]]) -> String {
    notes.map {
      "\($0["kind"] ?? "") \($0["class"] ?? "") \($0["title"] ?? "") \($0["text"] ?? "")"
    }
    .joined(separator: " || ")
  }

  private static func residentMegabytes() -> Int {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(
      MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) { pointer in
      pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
      }
    }
    guard result == KERN_SUCCESS else { return -1 }
    return Int(info.resident_size / (1024 * 1024))
  }

  private struct ProcessRow {
    let pid: Int32
    let ppid: Int32
    let command: String
  }

  private static func rendererProcessIDs() -> [Int32] {
    let snapshot = processSnapshot()
    let app = ProcessInfo.processInfo.processIdentifier
    var family: Set<Int32> = [app]
    var changed = true
    while changed {
      changed = false
      for process in snapshot
      where family.contains(process.ppid) && family.insert(process.pid).inserted {
        changed = true
      }
    }
    return snapshot.compactMap { process in
      guard family.contains(process.pid), process.command.contains("--type=renderer") else {
        return nil
      }
      return process.pid
    }.sorted(by: >)
  }

  private static func processSnapshot() -> [ProcessRow] {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/ps")
    process.arguments = ["-ax", "-o", "pid=,ppid=,command="]
    let pipe = Pipe()
    process.standardOutput = pipe
    guard (try? process.run()) != nil else { return [] }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let text = String(data: data, encoding: .utf8) ?? ""
    return text.split(separator: "\n").compactMap { line in
      let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
      guard parts.count == 3, let pid = Int32(parts[0]), let ppid = Int32(parts[1]) else {
        return nil
      }
      return ProcessRow(pid: pid, ppid: ppid, command: String(parts[2]))
    }
  }

  private static func killProcess(_ pid: Int32) async {
    await withCheckedContinuation { continuation in
      DispatchQueue.global(qos: .userInitiated).async {
        Darwin.kill(pid, SIGKILL)
        continuation.resume()
      }
    }
  }

  private static func silenceRenderers() {
    for pid in rendererProcessIDs().prefix(4) {
      Darwin.kill(pid, SIGKILL)
    }
  }

  private static func killRenderers() async {
    for pid in rendererProcessIDs().prefix(2) {
      await killProcess(pid)
    }
  }

  private static func menuLines() -> [MenuLine] {
    var lines: [MenuLine] = []
    func walk(_ menu: NSMenu?, parentTitle: String, parentID: String) {
      guard let menu else { return }
      let menuID = menu.identifier?.rawValue ?? parentID
      for item in menu.items {
        let title = item.title
        let itemID = item.identifier?.rawValue ?? ""
        let key = item.keyEquivalent
        let modifiers = item.keyEquivalentModifierMask
        let submenu = item.submenu
        let separator = item.isSeparatorItem
        if !separator {
          lines.append(
            MenuLine(
              menuTitle: parentTitle, menuID: menuID, title: title,
              itemID: itemID, key: key, modifiers: modifiers))
        }
        walk(submenu, parentTitle: title, parentID: itemID.isEmpty ? title : itemID)
      }
    }
    walk(NSApp.mainMenu, parentTitle: "", parentID: "")
    return lines
  }

  private static func firstItem(where matches: (MenuLine) -> Bool) -> NSMenuItem? {
    func walk(_ menu: NSMenu?, parentTitle: String, parentID: String) -> NSMenuItem? {
      guard let menu else { return nil }
      let menuID = menu.identifier?.rawValue ?? parentID
      for item in menu.items {
        let title = item.title
        let itemID = item.identifier?.rawValue ?? ""
        let key = item.keyEquivalent
        let modifiers = item.keyEquivalentModifierMask
        let submenu = item.submenu
        let separator = item.isSeparatorItem
        if !separator {
          let line = MenuLine(
            menuTitle: parentTitle, menuID: menuID, title: title,
            itemID: itemID, key: key, modifiers: modifiers)
          if matches(line) { return item }
        }
        let childID = itemID.isEmpty ? title : itemID
        if let found = walk(submenu, parentTitle: title, parentID: childID) {
          return found
        }
      }
      return nil
    }
    return walk(NSApp.mainMenu, parentTitle: "", parentID: "")
  }

  private struct MenuLine {
    let menuTitle: String
    let menuID: String
    let title: String
    let itemID: String
    let key: String
    let modifiers: NSEvent.ModifierFlags
  }

  private static func makeRow(
    _ name: String, _ passed: Bool, _ detail: String, proven: Bool = true
  ) -> [String: Any] {
    [
      "name": name,
      "passed": passed,
      "proven": proven,
      "detail": detail.replacingOccurrences(of: "\n", with: " "),
    ]
  }

  private static func write(_ value: [String: Any], to url: URL) {
    edgeProbeWrite(value, to: url)
  }

  nonisolated static func beforeUnloadProbePassed(
    exercised: Bool, dialogCount: Int, navigated: Bool, windowsHidden: Bool
  ) -> Bool {
    exercised && dialogCount > 0 && navigated && windowsHidden
  }

  nonisolated static func number(_ value: Any?) -> Int? {
    guard let number = value as? NSNumber,
      CFGetTypeID(number) != CFBooleanGetTypeID()
    else { return nil }
    let encoding = String(cString: number.objCType)
    if encoding == "f" || encoding == "d" {
      return Int(exactly: number.doubleValue)
    }
    return Int(number.stringValue)
  }

  nonisolated static func flag(_ value: Any?) -> Bool? {
    guard let number = value as? NSNumber,
      CFGetTypeID(number) == CFBooleanGetTypeID()
    else { return nil }
    return number.boolValue
  }

  nonisolated static func numbers(_ value: Any?) -> [Int] {
    if let values = value as? [Any] { return values.compactMap { number($0) } }
    if let values = value as? NSArray { return values.compactMap { number($0) } }
    return []
  }

  nonisolated static func videoIsPlaying(_ media: [String: Any]) -> Bool {
    flag(media["video"]) == true
      && flag(media["paused"]) == false
      && (number(media["videoWidth"]) ?? 0) > 0
  }

  nonisolated static func scrollFailureIsAttributable(scrollEvents: Int) -> Bool {
    scrollEvents > 0
  }
}

@MainActor
private final class EdgeProbeReport {
  let output: URL
  private var rows: [[String: Any]] = []

  init(output: URL) { self.output = output }

  func add(_ row: [String: Any]) {
    rows.append(row)
    publish(complete: false, hidden: NSApp.windows.allSatisfy { !$0.isVisible }, dialogs: [])
    let name = row["name"] as? String ?? ""
    let passed = row["passed"] as? Bool ?? false
    let detail = row["detail"] as? String ?? ""
    FileHandle.standardError.write(Data("\(name): \(passed) \(detail)\n".utf8))
  }

  func add(contentsOf extra: [[String: Any]]) {
    for row in extra { add(row) }
  }

  func finish(hidden: Bool, dialogs: [[String: String]], dialogsTruncated: Bool) {
    publish(complete: true, hidden: hidden, dialogs: dialogs, dialogsTruncated: dialogsTruncated)
  }

  private func publish(
    complete: Bool, hidden: Bool, dialogs: [[String: String]], dialogsTruncated: Bool = false
  ) {
    let passed =
      complete && hidden && !dialogsTruncated && !rows.isEmpty && rows.allSatisfy(rowAccepted)
    edgeProbeWrite(
      [
        "passed": passed, "complete": complete, "allWindowsHidden": hidden,
        "dialogsTruncated": dialogsTruncated,
        "dialogSampleIntervalMs": browsingEdgeDialogSampleIntervalMs,
        "rows": rows, "dialogs": dialogs,
      ],
      to: output)
  }
}

private final class EdgeProbeOnce: @unchecked Sendable {
  private let lock = NSLock()
  private var fired = false
  func claim() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    if fired { return false }
    fired = true
    return true
  }
}

private func rowAccepted(_ row: [String: Any]) -> Bool {
  (row["passed"] as? Bool) == true && (row["proven"] as? Bool) != false
}

private func edgeProbeWrite(_ value: [String: Any], to url: URL) {
  guard JSONSerialization.isValidJSONObject(value),
    let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted])
  else { return }
  try? data.write(to: url, options: .atomic)
}
