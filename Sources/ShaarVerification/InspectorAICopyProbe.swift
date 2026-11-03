// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import ChromiumBridge
import ChromiumBridgeVerification
import Foundation
import SwiftUI

@testable import ArcusisBrowser

@MainActor struct InspectorAICopyProbe {
  let engine: BrowserEngine
  let store: BrowserStore
  let root: URL
  let fixture: URL
  let phase: String

  func run() async throws -> [String] {
    var address = URLComponents(url: fixture, resolvingAgainstBaseURL: false)!
    address.host = "inspector.localhost"
    address.path = "/inspector-ai"
    address.query = "token=private-query-fixture"
    address.fragment = "private-fragment-fixture"
    store.perform(.open(address.url!))
    try await wait {
      engine.siteControlTarget?.url.path == "/inspector-ai"
        && engine.pages[engine.siteControlTarget!.tabID]?.loading == false
    }
    guard let target = engine.siteControlTarget else {
      throw InspectorFailure("AI fixture target is missing.")
    }
    engine.toggleInspector(for: target)
    guard let inspector = engine.inspectors[target.tabID] else {
      throw InspectorFailure("AI Inspector is missing.")
    }
    defer { inspector.close() }
    try await wait {
      try await inspector.evaluate("!!globalThis.__shaarInspectorV2") as? Bool == true
    }
    try await pick(inspector, "#ai-save")
    let ai = inspector.aiCopy
    ai.screenshotCache = .init(directory: root.appending(path: "inspector-ai-cache"))
    let board = NSPasteboard.withUniqueName()
    defer { board.releaseGlobally() }
    await ai.copyElement(to: board)
    try check(ai.failure == nil, "AI element copy failed: \(ai.failure ?? "")")
    let receipt = try Self.pasteboardReceipt(board)
    try check(
      receipt["items"] as? Int == 1 && receipt["png"] as? Bool == true,
      "Clipboard must contain Markdown and PNG on one item.")
    let text = board.pasteboardItems?.first?.string(forType: .string) ?? ""
    _ = try Self.screenshotFile(board, within: ai.screenshotCache.directory)
    try check(
      text.hasPrefix("Attached browser context from http://inspector.localhost:"),
      "Markdown header is missing.")
    try check(
      text.contains("Accessible name: Save changes") && text.contains("Role: button")
        && text.contains("Full DOM path:"), "Selected element fields are missing.")
    for secret in [
      "private-query-fixture", "private-fragment-fixture", "password-private-fixture",
      "input-private-fixture", "textarea-private-fixture", "selected-private-fixture",
    ] { try check(!text.contains(secret), "Private fixture value leaked into Markdown.") }
    ai.feedback = "Increase the button padding."
    await ai.addNote()
    try check(ai.notes.count == 1 && ai.feedback.isEmpty, "Locked element note was not added.")
    // The same tab navigates to a second page; notes survive and retain their original page.
    address.path = "/inspector-ai/second"
    try check(engine.navigateCurrentPage(to: address.url!), "AI fixture navigation failed.")
    try await wait {
      inspector.target.url.path == "/inspector-ai/second"
        && engine.pages[target.tabID]?.loading == false && inspector.selection == nil
    }
    try await wait {
      try await inspector.evaluate("!!globalThis.__shaarInspectorV2") as? Bool == true
    }
    try await pick(inspector, "#ai-save")
    ai.intent = .question
    ai.feedback = "Should this action be primary?"
    await ai.addNote()
    try check(ai.notes.count == 2, "Per-tab notes did not survive navigation.")
    let other = InspectorModel(
      target: .init(tabID: UUID(), profileID: target.profileID, url: address.url!), engine: nil)
    try check(other.aiCopy.notes.isEmpty, "Notes escaped their owning tab.")
    await ai.copy(.withNotes, to: board)
    try check(
      ai.failure == nil
        && board.string(forType: .string)?.contains("## Design Feedback across pages") == true
        && ai.notes.count == 2,
      "Copy with notes must include context and preserve the notes.")
    await ai.copy(.image, to: board)
    try check(
      ai.failure == nil && board.pasteboardItems?.count == 1
        && board.string(forType: .string) == nil && board.data(forType: .png) != nil,
      "Copy image did not export one image-only item.")
    inspector.highlightEdge("padding", 0, active: true)
    try await wait {
      try await inspector.evaluate("__shaarInspectorV2.edgeHighlight().painted") as? Bool == true
    }
    inspector.highlightEdge("padding", 0, active: false)
    try await wait {
      try await inspector.evaluate("__shaarInspectorV2.edgeHighlight().painted") as? Bool == false
    }
    try await captureRedesign(inspector)
    ai.copyNotes(to: board)
    let notes = board.string(forType: .string) ?? ""
    try check(
      notes.contains("## Design Feedback across pages") && notes.contains("**Intent:** Change")
        && notes.contains("**Intent:** Question"), "Grouped note Markdown is incomplete.")
    try check(
      ai.notes.isEmpty && ai.clearedNotes.count == 2,
      "Successful batch copy must clear notes with undo.")
    ai.undoClear()
    try check(ai.notes.count == 2 && ai.clearedNotes.isEmpty, "Clear undo lost notes.")
    ai.delete(ai.notes[0].id)
    try check(ai.notes.count == 1, "Deleting one note changed the wrong set.")
    inspector.tab = .design
    try await pick(inspector, "#ai-card")
    let centers =
      try await inspector.evaluate(
        "(()=>{const api=__shaarInspectorV2,b=api.rectFor(api.element());return [...api.element().querySelectorAll('input,textarea,select')].map(el=>{const r=api.rectFor(el);return {x:(r.x-b.x+r.w/2)*2,y:(r.y-b.y+r.h/2)*2};});})()"
      ) as? [[String: Double]] ?? []
    await ai.copyElement(to: board)
    try check(ai.failure == nil, "Private container copy failed: \(ai.failure ?? "")")
    let containerText = board.string(forType: .string) ?? ""
    for secret in [
      "password-private-fixture", "input-private-fixture", "textarea-private-fixture",
      "selected-private-fixture",
    ] {
      try check(!containerText.contains(secret), "A form value leaked from the selected container.")
    }
    guard let png = board.pasteboardItems?.last?.data(forType: .png),
      let bitmap = NSBitmapImageRep(data: png)
    else { throw InspectorFailure("Clipboard PNG could not be decoded.") }
    try png.write(to: root.appending(path: "\(phase)-inspector-ai-private.png"))
    let samples: [[String: Any]] = centers.map { center in
      let x = Int(center["x"] ?? -1)
      let y = Int(center["y"] ?? -1)
      let color = bitmap.colorAt(
        x: max(0, min(bitmap.pixelsWide - 1, x)), y: max(0, min(bitmap.pixelsHigh - 1, y)))?
        .usingColorSpace(.sRGB)
      return [
        "x": x, "y": y,
        "rgb": color.map { [$0.redComponent, $0.greenComponent, $0.blueComponent] } ?? [],
      ]
    }
    try JSONSerialization.data(
      withJSONObject: [
        "width": bitmap.pixelsWide, "height": bitmap.pixelsHigh, "samples": samples,
      ], options: [.prettyPrinted, .sortedKeys]
    ).write(to: root.appending(path: "\(phase)-inspector-ai-pixels.json"))
    try check(centers.count == 4, "The privacy fixture lost a control.")
    for center in centers {
      let x = Int(center["x"] ?? -1)
      let y = Int(center["y"] ?? -1)
      guard x >= 0, y >= 0, x < bitmap.pixelsWide, y < bitmap.pixelsHigh else {
        throw InspectorFailure("Control lies outside its element screenshot.")
      }
      try check(Self.isMaskedPixel(bitmap, x: x, y: y), "Form control pixels were not masked.")
    }
    try png.write(to: root.appending(path: "\(phase)-inspector-ai-private.png"))
    try check(
      try await inspector.evaluate(
        "document.querySelector('[data-shaar-copy-mask]')===null && !document.querySelector('#ai-password').hasAttribute('style')"
      ) as? Bool == true, "Screenshot privacy changes were not cleaned up.")
    try check(
      try await inspector.evaluate(
        "(()=>{const p=__shaarInspectorV2,c=__shaarInspectorCopy,token=c.begin(p.read().selection.id),input=document.createElement('input');input.value='late-private-value';p.element().append(input);const refused=c.end(token)===false;input.remove();return refused&&!document.querySelector('[data-shaar-copy-mask]');})()"
      ) as? Bool == true,
      "A dynamically inserted form control did not invalidate the private capture.")
    let count = board.changeCount
    try await pick(inspector, "#ai-password")
    await ai.copyElement(to: board)
    try check(
      ai.failure != nil && board.changeCount == count, "Password selection replaced the clipboard.")
    try await pick(inspector, "#ai-save")
    inspector.setPanelMode(.page)
    guard let tools = inspector.pageTools else {
      throw InspectorFailure("Page diagnostics missing.")
    }
    tools.tool = .overview
    try await wait {
      await tools.refresh()
      return tools.startedAt != nil
    }
    _ = try await inspector.evaluate(
      "console.error('AI fixture console error');fetch('/inspector-ai-failure?token=network-private').then(r=>r.text()).then(()=>true)"
    )
    try await wait {
      await tools.refresh()
      return tools.console.contains {
        $0.level == "error" && $0.message.contains("AI fixture console error")
      } && tools.requests.contains { $0.status == 503 }
        && tools.signals.contains { $0.name == "Inspector AI fixture" }
    }
    ai.detailed = true
    await ai.copyElement(to: board)
    let detailed = board.string(forType: .string) ?? ""
    try check(
      ai.failure == nil && detailed.contains("Full computed styles:")
        && detailed.contains("Matched CSS rules:") && detailed.contains("AI fixture console error")
        && detailed.contains("status 503") && detailed.contains("Inspector AI fixture"),
      "Detailed context is missing collected diagnostics.")
    try check(!detailed.contains("network-private"), "Detailed request query was not stripped.")
    try check(
      try await inspector.evaluate(
        "__shaarInspectorV2.overlay().painted && document.querySelector('[data-shaar-inspector]').style.visibility==='hidden'"
      ) as? Bool == true, "Copy reactivated picking overlays in Page mode.")
    inspector.setPanelMode(.element)
    inspector.tab = .notes
    let data = try JSONSerialization.data(
      withJSONObject: [
        "clipboard": receipt, "notesPages": 2, "privateControlsMasked": centers.count,
        "passed": true,
      ], options: [.prettyPrinted, .sortedKeys])
    try data.write(to: root.appending(path: "\(phase)-inspector-ai-receipt.json"))
    return [
      "Copy for AI has one Markdown/PNG item and a cached screenshot path",
      "AI context omits URL suffixes and form values",
      "Notes stay per tab, group pages, delete, copy-clear and undo",
      "Detailed AI copy uses collected CSS, console, HTTP errors and technologies",
      "Element PNG masks form controls and restores page styles",
      "Offscreen AI probe uses an isolated pasteboard",
    ]
  }

  static func isMaskedPixel(_ bitmap: NSBitmapImageRep, x: Int, y: Int) -> Bool {
    guard bitmap.bitsPerSample == 8, bitmap.samplesPerPixel >= 3,
      (0..<bitmap.pixelsWide).contains(x), (0..<bitmap.pixelsHigh).contains(y)
    else { return false }
    var channels = [UInt](repeating: 0, count: bitmap.samplesPerPixel)
    bitmap.getPixel(&channels, atX: x, y: y)
    // CSS #808080 is encoded in the PNG's channels; colorAt converts its embedded color profile.
    return channels.prefix(3).allSatisfy { (126...130).contains($0) }
  }

  static func pasteboardReceipt(_ board: NSPasteboard) throws -> [String: Any] {
    guard let items = board.pasteboardItems, items.count == 1,
      let markdown = items[0].string(forType: .string),
      let typed = items[0].string(forType: .init("net.daringfireball.markdown")), markdown == typed,
      let png = items[0].data(forType: .png), let bitmap = NSBitmapImageRep(data: png),
      bitmap.pixelsWide > 0 && bitmap.pixelsHigh > 0
    else { throw InspectorFailure("Clipboard context is missing Markdown or an actual PNG.") }
    return [
      "items": items.count, "markdown": true, "png": true, "width": bitmap.pixelsWide,
      "height": bitmap.pixelsHigh,
    ]
  }

  static func screenshotFile(_ board: NSPasteboard, within directory: URL) throws -> URL {
    let text = board.string(forType: .string) ?? ""
    guard let line = text.split(separator: "\n").first(where: { $0.hasPrefix("Screenshot: ") })
    else {
      throw InspectorFailure("AI context does not reference its screenshot file.")
    }
    let path = String(line.dropFirst("Screenshot: ".count))
    let root = directory.standardizedFileURL.resolvingSymlinksInPath()
    let file = URL(filePath: path).standardizedFileURL.resolvingSymlinksInPath()
    guard path.hasPrefix("/"), file.path.hasPrefix(root.path + "/"),
      file.pathExtension.lowercased() == "png"
    else {
      throw InspectorFailure("Screenshot reference escaped the owned cache.")
    }
    guard let data = try? Data(contentsOf: file),
      data == board.pasteboardItems?.first?.data(forType: .png),
      NSBitmapImageRep(data: data) != nil
    else {
      throw InspectorFailure("Screenshot file is missing or differs from the pasteboard PNG.")
    }
    return file
  }
  private func check(_ value: Bool, _ message: String) throws {
    if !value { throw InspectorFailure(message) }
  }
  private func wait(_ predicate: () async throws -> Bool) async throws {
    for _ in 0..<Int(150 * ProbeTimeout.scale) {
      if try await predicate() { return }
      try await Task.sleep(for: .milliseconds(100))
    }
    throw InspectorFailure("AI copy probe condition did not settle.")
  }
  private func pick(_ inspector: InspectorModel, _ selector: String) async throws {
    let targetSelector = selector == "#ai-card" ? "#ai-save" : selector
    inspector.pick()
    let accepted: Bool = await withCheckedContinuation { continuation in
      engine.runtime.inspectorProbePointer(
        inTabID: inspector.target.tabID.uuidString, selector: targetSelector, frames: [],
        click: true,
        modifiers: 0
      ) { continuation.resume(returning: $0) }
    }
    try check(accepted, "Trusted AI fixture selection failed.")
    try await wait {
      guard inspector.selection?.locked == true,
        let state = try await inspector.evaluate("globalThis.__shaarInspectorV2.read().selection")
          as? [String: Any]
      else { return false }
      return state["id"] as? Int == inspector.selection?.id
    }
    if selector == "#ai-card" {
      guard
        let ancestor = inspector.selection?.ancestors.first(where: { $0.label.hasPrefix("main") })
      else { throw InspectorFailure("Container breadcrumb is missing.") }
      inspector.selectAncestor(ancestor.id)
      try await wait {
        inspector.selection?.id == ancestor.id && inspector.selection?.tag == "main"
      }
    }

  }
  private func captureRedesign(_ inspector: InspectorModel) async throws {
    let detailed = inspector.aiCopy.detailed
    defer {
      inspector.aiCopy.detailed = detailed
      inspector.presentation.dismiss()
    }
    await inspector.styles.refresh(force: true)
    try check(inspector.styles.failure == nil, "Redesign CSS snapshot is unavailable.")
    var images: [String] = []
    for (name, tab, menu) in [
      ("design", InspectorModel.Tab.design, false), ("code", .styles, false),
      ("notes", .notes, false), ("copy-menu", .design, true),
    ] {
      inspector.tab = tab
      inspector.presentation.dismiss()
      inspector.aiCopy.detailed = menu
      inspector.presentation.copyMenuOpen = menu
      for width in [CGFloat(320), 420] {
        let stem = "\(phase)-inspector-redesign-\(name)-\(Int(width))"
        try await capture(inspector, stem: stem, width: width)
        images += [stem + "-light.png", stem + "-dark.png"]
      }
    }
    try JSONSerialization.data(
      withJSONObject: ["passed": true, "offscreen": true, "images": images],
      options: [.prettyPrinted, .sortedKeys]
    )
    .write(to: root.appending(path: "\(phase)-inspector-redesign-receipt.json"))
  }

  private func capture(_ inspector: InspectorModel, stem: String, width: CGFloat) async throws {
    for (name, scheme) in [("light", ColorScheme.light), ("dark", .dark)] {
      let previous = NSApp.keyWindow
      let layout = InspectorLayoutSnapshot()
      let host = NSHostingView(
        rootView: InspectorPanel(model: inspector, layout: layout).frame(width: width, height: 960)
          .environment(
            \.colorScheme, scheme))
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: width, height: 960), styleMask: .borderless,
        backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      window.contentView = host
      window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
      defer {
        window.contentView = nil
        window.close()
      }
      host.layoutSubtreeIfNeeded()
      try await Task.sleep(for: .milliseconds(100))
      host.layoutSubtreeIfNeeded()
      guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
        throw InspectorFailure("AI notes capture could not render.")
      }
      host.cacheDisplay(in: host.bounds, to: bitmap)
      try bitmap.representation(using: .png, properties: [:])?.write(
        to: root.appending(path: "\(stem)-\(name).png"))
      try check(!window.isVisible, "AI notes capture ordered a window.")
      try check(NSApp.keyWindow === previous, "Redesign capture changed the key window.")
      try check(
        abs(layout.panelSize.width - width) < 0.5
          && abs(layout.contentFrame.width - width) < 0.5
          && layout.tabFrames.count == 6
          && layout.tabFrames.values.allSatisfy { $0.minX >= -0.5 && $0.maxX <= width + 0.5 },
        "Inspector tabs escaped their panel width.")
      if inspector.presentation.copyMenuOpen {
        let frame = layout.copyMenuFrame
        try check(
          frame.width >= 180 && frame.minX >= 0 && frame.maxX <= width + 0.5 && frame.maxY <= 960,
          "Copy menu escaped its panel bounds: \(frame).")
      }
    }
  }
}
