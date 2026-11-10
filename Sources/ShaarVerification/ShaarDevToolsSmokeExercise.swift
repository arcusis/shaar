// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import Foundation
import ShaarEngineABI

@testable import ArcusisBrowser

/// The packaged smoke's previously skipped DevTools actions. Windows stay hidden.
@MainActor enum ShaarDevToolsSmokeExercise {
  /// True when a row expand did not reveal the node and getDocument(depth: 8) did.
  private static var loadedDocumentDeeply = false
  private static var expandFailure: String?

  static func run(
    shell: ShaarDevToolsModel, inspector: InspectorModel, context: NativeBrowserContext,
    report: ShaarDevToolsSmokeReport
  ) async {
    loadedDocumentDeeply = false
    expandFailure = nil
    await inspectorPanes(shell: shell, inspector: inspector, context: context, report: report)
    await copySelector(shell: shell, inspector: inspector, report: report)
    await runAudit(shell: shell, context: context, report: report)
    await dragDOM(shell: shell, context: context, report: report)
    await showCertificate(shell: shell, context: context, report: report)
  }

  static func dragSplit(
    shell: ShaarDevToolsModel, context: NativeBrowserContext, report: ShaarDevToolsSmokeReport
  ) async {
    guard let handle = await horizontalSplit(in: context) else {
      report.fail("resize", "The split handle is not in the view, so it could not be dragged")
      return
    }
    let before = shell.rightWidth
    if await drag(handle, by: -80, shell: shell, context: context) {
      report.pass(
        "resize",
        "Dragging the split handle changed the side panel from \(points(before)) to \(points(shell.rightWidth))"
      )
      return
    }
    guard let narrowed = await horizontalSplit(in: context) else {
      report.fail("resize", "The split handle is not in the view, so it could not be dragged")
      return
    }
    let stuck = shell.rightWidth
    if await drag(narrowed, by: 80, shell: shell, context: context) {
      report.pass(
        "resize",
        "Dragging the split handle changed the side panel from \(points(stuck)) to \(points(shell.rightWidth))"
      )
      return
    }
    report.fail(
      "resize",
      "Dragging the split handle left the width at \(points(shell.rightWidth)) from \(points(before))"
    )
  }

  private static func points(_ width: CGFloat) -> Int { Int(width.rounded()) }

  private static func drag(
    _ handle: ShaarDevToolsSplitHandleView, by width: CGFloat, shell: ShaarDevToolsModel,
    context: NativeBrowserContext
  ) async -> Bool {
    let before = shell.rightWidth
    guard ShaarDevToolsSmokeAccess.drag(handle, by: CGSize(width: width, height: 0)) else {
      return false
    }
    await ShaarDevToolsSmoke.settle(context)
    return abs(shell.rightWidth - before) > 20
  }

  private static func horizontalSplit(
    in context: NativeBrowserContext
  ) async -> ShaarDevToolsSplitHandleView? {
    let appeared = await ShaarDevToolsSmoke.wait(attempts: 30) {
      splitHandle(in: context.hosting)?.vertical == false
    }
    guard appeared, let handle = splitHandle(in: context.hosting), !handle.vertical else {
      return nil
    }
    return handle
  }

  private static func splitHandle(in root: NSView) -> ShaarDevToolsSplitHandleView? {
    let handles = splitHandles(in: root)
    if let horizontal = handles.first(where: { !$0.vertical }) { return horizontal }
    return handles.first
  }

  private static func splitHandles(in root: NSView) -> [ShaarDevToolsSplitHandleView] {
    var found: [ShaarDevToolsSplitHandleView] = []
    if let handle = root as? ShaarDevToolsSplitHandleView { found.append(handle) }
    for child in root.subviews { found.append(contentsOf: splitHandles(in: child)) }
    return found
  }

  private static func inspectorPanes(
    shell: ShaarDevToolsModel, inspector: InspectorModel, context: NativeBrowserContext,
    report: ShaarDevToolsSmokeReport
  ) async {
    guard await openElements(shell, context: context) else {
      failPanes(shell.dom.failure ?? "The DOM document did not load", report: report)
      return
    }
    guard let main = await element(shell.dom, className: "grid") else {
      failPanes("Could not find main.grid. \(census(shell.dom))", report: report)
      return
    }
    if loadedDocumentDeeply {
      let reason = expandFailure ?? "requestChildNodes did not fill the row"
      report.fail(
        "dom-expand",
        "Expanding a DOM row did not load children (\(reason)). A deeper document load found the node."
      )
    }
    guard await lock(main, shell: shell, inspector: inspector) else {
      failPanes("Could not lock main.grid", report: report)
      return
    }
    await showTab("Code", tab: .styles, inspector: inspector, context: context)
    await inspector.styles.refresh(force: true)
    recordStyles(inspector, report: report)
    recordComputed(inspector, expectDisplay: "grid", report: report)
    recordBox(inspector, report: report)
    await recordForce(inspector, report: report)
    await showTab("A11y", tab: .accessibility, inspector: inspector, context: context)
    await inspector.details.refresh(force: true)
    recordAccessibility(inspector, report: report)
    await recordStale(shell: shell, inspector: inspector, report: report)
    ShaarDevToolsSmokeLook.survey(
      panel: "Inspector", contentIdentifier: "shaar.devtools.domTree", in: context.hosting,
      failure: inspector.styles.failure ?? inspector.details.failure, report: report)
    ShaarDevToolsSmokeLook.focus(panel: "Inspector", in: context.hosting, report: report)
  }

  private static func recordStyles(
    _ inspector: InspectorModel, report: ShaarDevToolsSmokeReport
  ) {
    if let failure = inspector.styles.failure, inspector.styles.rules.isEmpty {
      report.fail("inspector-styles", failure)
      return
    }
    let matched = inspector.styles.rules.contains { rule in
      rule.selector.localizedCaseInsensitiveContains("grid")
    }
    if matched {
      let source = loadedDocumentDeeply ? " after a deeper document load" : ""
      report.pass("inspector-styles", "Styles lists the .grid rule\(source)")
    } else if inspector.styles.rules.isEmpty {
      report.fail("inspector-styles", "Styles loaded nothing for main.grid")
    } else {
      report.fail(
        "inspector-styles", "Styles did not list the .grid rule", severity: .wrong)
    }
  }

  private static func recordComputed(
    _ inspector: InspectorModel, expectDisplay: String, report: ShaarDevToolsSmokeReport
  ) {
    let display = computed("display", inspector.styles)
    let padding = computed("padding-top", inspector.styles)
    if display == expectDisplay, padding?.contains("16") == true {
      report.pass(
        "inspector-computed",
        "Computed display is \(expectDisplay) and padding-top is \(padding ?? "")")
      return
    }
    if display == nil, padding == nil {
      report.fail("inspector-computed", inspector.styles.failure ?? "Computed styles did not load")
      return
    }
    report.fail(
      "inspector-computed",
      "Computed display is \(display ?? "missing") and padding-top is \(padding ?? "missing"). The page sets grid and 16px.",
      severity: .wrong)
  }

  private static func recordBox(_ inspector: InspectorModel, report: ShaarDevToolsSmokeReport) {
    let padding = inspector.selection?.box.padding ?? []
    if padding.count == 4, padding.allSatisfy({ $0.contains("16") }) {
      report.pass("inspector-box", "Box model padding is \(padding.joined(separator: " "))")
      return
    }
    if padding.isEmpty {
      report.fail("inspector-box", "Box model did not load")
      return
    }
    report.fail(
      "inspector-box",
      "Box model padding is \(padding.joined(separator: " ")). The page sets 16px.",
      severity: .wrong)
  }

  private static func recordForce(
    _ inspector: InspectorModel, report: ShaarDevToolsSmokeReport
  ) async {
    await inspector.styles.togglePseudo("hover")
    guard inspector.styles.forcedPseudos.contains("hover") else {
      report.fail(
        "inspector-force", inspector.styles.failure ?? "Force state did nothing")
      return
    }
    await inspector.styles.togglePseudo("hover")
    if inspector.styles.forcedPseudos.contains("hover") {
      report.fail(
        "inspector-force", "Force state stayed on after toggling :hover off", severity: .wrong)
    } else {
      report.pass("inspector-force", "Force state toggled :hover on and off")
    }
  }

  private static func recordAccessibility(
    _ inspector: InspectorModel, report: ShaarDevToolsSmokeReport
  ) {
    guard let data = inspector.details.accessibility else {
      report.fail(
        "inspector-a11y", inspector.details.failure ?? "Accessibility tree did not load")
      return
    }
    if data.role == "Unavailable" {
      report.fail("inspector-a11y", "Accessibility tree role is unavailable")
      return
    }
    if data.role.lowercased() != "main" {
      report.fail(
        "inspector-a11y", "Accessibility role is \(data.role) for <main>", severity: .wrong)
      return
    }
    if data.ignored == true {
      report.fail(
        "inspector-a11y", "<main> is marked out of the accessibility tree", severity: .wrong)
      return
    }
    report.pass("inspector-a11y", "Accessibility tree role is main")
  }

  private static func recordStale(
    shell: ShaarDevToolsModel, inspector: InspectorModel, report: ShaarDevToolsSmokeReport
  ) async {
    guard let body = await element(shell.dom, tag: "body") else {
      report.fail("inspector-stale", "Could not find body to check a stale computed value")
      return
    }
    guard await lock(body, shell: shell, inspector: inspector) else {
      report.fail("inspector-stale", "Could not lock body")
      return
    }
    inspector.tab = .styles
    await inspector.styles.refresh(force: true)
    let display = computed("display", inspector.styles)
    if display == "block" {
      report.pass("inspector-stale", "Computed display changed to block for body")
    } else if display == "grid" {
      report.fail(
        "inspector-stale", "Computed display stayed grid after selecting body", severity: .wrong)
    } else {
      report.fail(
        "inspector-stale", "Computed display is \(display ?? "missing") for body", severity: .wrong)
    }
  }

  private static func copySelector(
    shell: ShaarDevToolsModel, inspector: InspectorModel, report: ShaarDevToolsSmokeReport
  ) async {
    guard let node = await element(shell.dom, id: "long") else {
      report.fail("dom-selector", "Copy selector had no #long element. \(census(shell.dom))")
      return
    }
    let board = NSPasteboard(name: NSPasteboard.Name("shaar.devtools.smoke.selector"))
    let css = await ShaarDOMContextMenu.copySelector(
      for: node.id, model: shell.dom, inspector: inspector, pasteboard: board)
    let stored = board.string(forType: .string) ?? ""
    guard !css.isEmpty, stored == css else {
      report.fail("dom-selector", "The copy-selector menu did nothing")
      return
    }
    let encoded = String(decoding: (try? JSONEncoder().encode(css)) ?? Data(), as: UTF8.self)
    let matches =
      (try? await inspector.evaluate(
        "document.querySelector(\(encoded)) === document.getElementById('long')")) as? Bool
    if matches == true {
      report.pass("dom-selector", "Copy selector wrote \(css) and it matches #long")
    } else {
      report.fail(
        "dom-selector", "Copy selector wrote \(css), which does not match #long", severity: .wrong)
    }
  }

  private static func runAudit(
    shell: ShaarDevToolsModel, context: NativeBrowserContext, report: ShaarDevToolsSmokeReport
  ) async {
    shell.section = .audits
    await ShaarDevToolsSmoke.settle(context)
    let pressed = ShaarDevToolsSmokeAccess.press(
      identifier: "shaar.devtools.runAudit", in: context.hosting)
    if !pressed { shell.pageAudit.run() }
    let finished = await ShaarDevToolsSmoke.wait(attempts: 400) {
      !shell.pageAudit.busy && (shell.pageAudit.report != nil || shell.pageAudit.failure != nil)
    }
    guard finished, let audit = shell.pageAudit.report else {
      report.fail("audit-run", shell.pageAudit.failure ?? "Run audit did nothing")
      return
    }
    let listed = shell.auditRows.count
    if audit.violations > 0, listed == 0, !audit.truncated {
      report.fail(
        "audit-run",
        "Run audit counted \(audit.violations) violations and listed none",
        severity: .wrong)
      return
    }
    await ShaarDevToolsSmoke.settle(context)
    let painted = ShaarDevToolsSmokeAccess.renderedText(context.hosting)
    if ShaarDevToolsSmokeAccess.shows("Run an audit to check", in: painted),
      !ShaarDevToolsSmokeAccess.shows("violations", in: painted)
    {
      report.fail(
        "audit-run", "Run audit finished and the panel still says to run one", severity: .wrong)
      return
    }
    if audit.violations == 0, listed == 0,
      !ShaarDevToolsSmokeAccess.shows("No axe-core", in: painted),
      !ShaarDevToolsSmokeAccess.shows("violations", in: painted)
    {
      ShaarDevToolsSmokeLook.recordBlank(panel: "Audits", in: context.hosting, report: report)
    }
    report.pass(
      "audit-run",
      "Run audit finished. \(audit.violations) violations, \(audit.incomplete) need review, \(listed) listed."
    )
  }

  private static func dragDOM(
    shell: ShaarDevToolsModel, context: NativeBrowserContext, report: ShaarDevToolsSmokeReport
  ) async {
    guard await openElements(shell, context: context) else {
      report.fail("dom-drag", shell.dom.failure ?? "The DOM document did not load")
      return
    }
    guard let long = await element(shell.dom, id: "long") else {
      report.fail(
        "dom-drag", shell.dom.failure ?? "DOM drag had no #long element. \(census(shell.dom))")
      return
    }
    await shell.dom.loadChildrenIfNeeded(long.id)
    guard let parent = shell.dom.nodes[long.id] else {
      report.fail("dom-drag", "DOM drag lost #long")
      return
    }
    let rows = elementChildren(of: parent, model: shell.dom)
    guard rows.count >= 2 else {
      report.fail("dom-drag", "DOM drag had no loaded element siblings")
      return
    }
    await shell.dom.loadChildrenIfNeeded(rows[0].id)
    await shell.dom.loadChildrenIfNeeded(rows[1].id)
    guard let loaded = shell.dom.nodes[long.id] else {
      report.fail("dom-drag", "DOM drag lost #long")
      return
    }
    let fresh = elementChildren(of: loaded, model: shell.dom)
    guard fresh.count >= 2 else {
      report.fail("dom-drag", "DOM drag had no loaded element siblings")
      return
    }
    shell.dom.select(long.id)
    if !shell.dom.expanded.contains(long.id) { await shell.dom.toggleExpanded(long.id) }
    if !shell.dom.expanded.contains(fresh[0].id) { await shell.dom.toggleExpanded(fresh[0].id) }
    _ = ShaarDevToolsSmokeAccess.capture(
      context.hosting, to: report.directory.appending(path: "panel-elements-dom-drag.png"))
    let draggedKey = signature(fresh[1], model: shell.dom)
    let beforeKey = signature(fresh[0], model: shell.dom)
    guard draggedKey != beforeKey else {
      let rows = fresh.prefix(2).map {
        "\($0.id): \($0.childrenIDs.count)/\($0.childCount) children, \(signature($0, model: shell.dom))"
      }
      report.fail("dom-drag", "DOM drag had no distinct row text. \(rows.joined(separator: "; "))")
      return
    }
    let beforeOrder = fresh.map { signature($0, model: shell.dom) }
    var request: (Int, Int, Int?)?
    let applied = ShaarDOMDrag.apply(
      draggedID: fresh[1].id, rowID: fresh[0].id, kind: .before, nodes: shell.dom.nodes
    ) { id, parentID, sibling in
      request = (id, parentID, sibling)
    }
    guard applied, let request else {
      report.fail("dom-drag", "DOM drag did nothing")
      return
    }
    await shell.dom.move(request.0, to: request.1, before: request.2)
    guard shell.dom.failure == nil else {
      report.fail("dom-drag", shell.dom.failure ?? "DOM drag lost the parent")
      return
    }
    guard let moved = await element(shell.dom, id: "long") else {
      report.fail("dom-drag", "DOM drag lost #long")
      return
    }
    await shell.dom.loadChildrenIfNeeded(moved.id)
    guard let movedParent = shell.dom.nodes[moved.id] else {
      report.fail("dom-drag", "DOM drag lost #long")
      return
    }
    for row in elementChildren(of: movedParent, model: shell.dom).prefix(4) {
      await shell.dom.loadChildrenIfNeeded(row.id)
    }
    guard let reloaded = shell.dom.nodes[moved.id] else {
      report.fail("dom-drag", "DOM drag lost #long")
      return
    }
    let after = elementChildren(of: reloaded, model: shell.dom).map {
      signature($0, model: shell.dom)
    }
    let draggedIndex = after.firstIndex(of: draggedKey)
    let beforeIndex = after.firstIndex(of: beforeKey)
    if let draggedIndex, let beforeIndex, draggedIndex < beforeIndex, after != beforeOrder {
      report.pass("dom-drag", "Dragged \(draggedKey) before \(beforeKey)")
    } else {
      report.fail("dom-drag", "DOM drag left the sibling order unchanged")
    }
  }

  private static func showCertificate(
    shell: ShaarDevToolsModel, context: NativeBrowserContext, report: ShaarDevToolsSmokeReport
  ) async {
    shell.section = .security
    await ShaarDevToolsSmoke.settle(context)
    guard let certificate = shell.securitySummary.certificate else {
      report.manual(
        "certificate",
        "needs-manual. The fixture is HTTP, and Show certificate opens the system certificate sheet."
      )
      return
    }
    let subject = certificate.subject.isEmpty ? "the leaf" : certificate.subject
    report.manual(
      "certificate",
      "needs-manual. \(subject) is on the Security panel. The system certificate sheet cannot open while windows stay hidden."
    )
  }

  private static func openElements(
    _ shell: ShaarDevToolsModel, context: NativeBrowserContext
  ) async -> Bool {
    shell.section = .elements
    await ShaarDevToolsSmoke.settle(context)
    let ready = await ShaarDevToolsSmoke.wait(attempts: 80) {
      shell.dom.rootID != nil || shell.dom.failure != nil
    }
    return ready && shell.dom.rootID != nil
  }

  private static func showTab(
    _ label: String, tab: InspectorModel.Tab, inspector: InspectorModel,
    context: NativeBrowserContext
  ) async {
    let pressed = ShaarDevToolsSmokeAccess.press(label: label, in: context.hosting)
    if !pressed || inspector.tab != tab { inspector.tab = tab }
    await ShaarDevToolsSmoke.settle(context)
  }

  private static func lock(
    _ node: ShaarDOMNode, shell: ShaarDevToolsModel, inspector: InspectorModel
  ) async -> Bool {
    shell.dom.select(node.id)
    do { try await inspector.selectDOMNode(node.id) } catch { return false }
    return await ShaarDevToolsSmoke.wait(attempts: 30) { inspector.selection?.locked == true }
  }

  private static func element(
    _ model: ShaarDOMTreeModel, id: String? = nil, className: String? = nil, tag: String? = nil
  ) async -> ShaarDOMNode? {
    if let found = storedElement(model, id: id, className: className, tag: tag) { return found }
    if let found = await expandedElement(model, id: id, className: className, tag: tag) {
      return found
    }
    await model.loadDocument(depth: 8)
    loadedDocumentDeeply = true
    return storedElement(model, id: id, className: className, tag: tag)
  }

  private static func expandedElement(
    _ model: ShaarDOMTreeModel, id: String?, className: String?, tag: String?
  ) async -> ShaarDOMNode? {
    var seen: Set<Int> = []
    for _ in 0..<8 {
      let pending = model.nodes.values.filter { node in
        node.nodeType == 1 && node.childCount > node.childrenIDs.count && !seen.contains(node.id)
      }
      if pending.isEmpty { break }
      for node in pending.prefix(24) {
        seen.insert(node.id)
        if let reason = await model.loadChildrenIfNeeded(node.id) {
          expandFailure = reason
        }
      }
      if let found = storedElement(model, id: id, className: className, tag: tag) { return found }
    }
    return nil
  }

  private static func census(_ model: ShaarDOMTreeModel) -> String {
    let sample = model.nodes.values.filter { $0.nodeType == 1 }.prefix(8).map { node in
      let id = node.attributes.first { $0.name == "id" }?.value ?? ""
      return "\(node.name)#\(id) \(node.childrenIDs.count)/\(node.childCount)"
    }.joined(separator: ", ")
    return "\(model.nodes.count) nodes: \(sample)"
  }

  private static func storedElement(
    _ model: ShaarDOMTreeModel, id: String?, className: String?, tag: String?
  ) -> ShaarDOMNode? {
    model.nodes.values.first { node in
      guard node.nodeType == 1 else { return false }
      if let tag, node.name.lowercased() != tag { return false }
      if let id, !node.attributes.contains(where: { $0.name == "id" && $0.value == id }) {
        return false
      }
      if let className {
        let names =
          node.attributes.first { $0.name == "class" }?
          .value.split(whereSeparator: \.isWhitespace) ?? []
        if !names.contains(Substring(className)) { return false }
      }
      return id != nil || className != nil || tag != nil
    }
  }

  private static func elementChildren(
    of parent: ShaarDOMNode, model: ShaarDOMTreeModel
  ) -> [ShaarDOMNode] {
    parent.childrenIDs.compactMap { model.nodes[$0] }.filter { $0.nodeType == 1 }
  }

  private static func signature(_ node: ShaarDOMNode, model: ShaarDOMTreeModel) -> String {
    let id = node.attributes.first { $0.name == "id" }?.value ?? ""
    let className = node.attributes.first { $0.name == "class" }?.value ?? ""
    let text = node.childrenIDs.compactMap { model.nodes[$0]?.value }.joined(separator: " ")
    return "\(node.name.lowercased())|\(id)|\(className)|\(node.value)|\(text)"
  }

  private static func computed(_ name: String, _ model: InspectorStylesModel) -> String? {
    model.computed.first { $0.name == name }?.value
  }

  private static func failPanes(_ detail: String, report: ShaarDevToolsSmokeReport) {
    for name in [
      "inspector-styles", "inspector-computed", "inspector-box", "inspector-force",
      "inspector-a11y", "inspector-stale",
    ] {
      report.fail(name, detail)
    }
  }
}
