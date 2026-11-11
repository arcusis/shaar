// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

enum ShaarDevToolsRecorderKind: String, Equatable, Sendable {
  case click
  case change
  case navigation
}

struct ShaarDevToolsRecorderStep: Equatable, Identifiable, Sendable {
  var id: UUID
  var kind: ShaarDevToolsRecorderKind
  var selector: String
  var value: String
}

enum ShaarRecorderNotice: Equatable {
  case needsPage
  case needsFolder
  case saved
  case failed(String)
}

struct ShaarRecorderFailure: LocalizedError {
  var errorDescription: String?
  init(_ message: String) { errorDescription = message }
}

enum ShaarDevToolsRecorder {
  static let installSource = """
    (() => {
      if (window.__shaarFlowInstalled) {
        window.__shaarFlow = [];
        return true;
      }
      window.__shaarFlowInstalled = true;
      window.__shaarFlow = [];
      const selectorFor = (node) => {
        const element = node && node.nodeType === 1 ? node : node && node.parentElement;
        if (!element) return "";
        if (element.id) return "#" + CSS.escape(element.id);
        const name = element.getAttribute && element.getAttribute("name");
        if (name) return element.tagName.toLowerCase() + "[name=\\"" + CSS.escape(name) + "\\"]";
        if (element === document.body) return "body";
        const parent = element.parentElement;
        if (!parent) return element.tagName.toLowerCase();
        const tag = element.tagName;
        const same = Array.from(parent.children).filter((child) => child.tagName === tag);
        const piece = tag.toLowerCase();
        const parentSelector = selectorFor(parent);
        if (same.length < 2) return parentSelector + " > " + piece;
        return parentSelector + " > " + piece + ":nth-of-type(" + (same.indexOf(element) + 1) + ")";
      };
      const onClick = (event) => {
        const selector = selectorFor(event.target);
        if (!selector) return;
        window.__shaarFlow.push({ kind: "click", selector: selector, value: "" });
      };
      const onChange = (event) => {
        const element = event.target;
        const selector = selectorFor(element);
        if (!selector) return;
        const value = element && "value" in element ? String(element.value) : "";
        window.__shaarFlow.push({ kind: "change", selector: selector, value: value });
      };
      const rememberURL = () => {
        window.__shaarFlow.push({ kind: "navigation", selector: "", value: location.href });
      };
      window.__shaarFlowOnClick = onClick;
      window.__shaarFlowOnChange = onChange;
      window.__shaarFlowRememberURL = rememberURL;
      window.__shaarFlowPushState = history.pushState;
      window.__shaarFlowReplaceState = history.replaceState;
      document.addEventListener("click", onClick, true);
      document.addEventListener("change", onChange, true);
      history.pushState = function () {
        const result = window.__shaarFlowPushState.apply(this, arguments);
        rememberURL();
        return result;
      };
      history.replaceState = function () {
        const result = window.__shaarFlowReplaceState.apply(this, arguments);
        rememberURL();
        return result;
      };
      window.addEventListener("hashchange", rememberURL);
      window.addEventListener("popstate", rememberURL);
      return true;
    })()
    """

  static let uninstallSource = """
    (() => {
      if (!window.__shaarFlowInstalled) return false;
      document.removeEventListener("click", window.__shaarFlowOnClick, true);
      document.removeEventListener("change", window.__shaarFlowOnChange, true);
      window.removeEventListener("hashchange", window.__shaarFlowRememberURL);
      window.removeEventListener("popstate", window.__shaarFlowRememberURL);
      if (window.__shaarFlowPushState) history.pushState = window.__shaarFlowPushState;
      if (window.__shaarFlowReplaceState) history.replaceState = window.__shaarFlowReplaceState;
      window.__shaarFlowInstalled = false;
      return true;
    })()
    """

  static let drainSource = """
    (() => {
      const events = Array.isArray(window.__shaarFlow) ? window.__shaarFlow.slice() : [];
      window.__shaarFlow = [];
      return events;
    })()
    """

  static func replaySource(_ steps: [ShaarDevToolsRecorderStep]) -> String {
    let payload = steps.map { step in
      ["kind": step.kind.rawValue, "selector": step.selector, "value": step.value]
    }
    let encoded = json(payload) ?? "[]"
    return """
      (async () => {
        const steps = \(encoded);
        for (const step of steps) {
          if (step.kind === "navigation") {
            if (location.href !== step.value) location.assign(step.value);
            continue;
          }
          const element = document.querySelector(step.selector);
          if (!element) throw new Error("Missing " + step.selector);
          if (step.kind === "click") {
            element.click();
            continue;
          }
          element.focus();
          element.value = step.value;
          element.dispatchEvent(new Event("input", { bubbles: true }));
          element.dispatchEvent(new Event("change", { bubbles: true }));
        }
        return true;
      })()
      """
  }

  static func document(for steps: [ShaarDevToolsRecorderStep]) -> Data {
    let payload: [String: Any] = [
      "kind": "shaar-flow",
      "steps": steps.map { step in
        ["kind": step.kind.rawValue, "selector": step.selector, "value": step.value]
      },
    ]
    return
      (try? JSONSerialization.data(
        withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])) ?? Data()
  }

  static func steps(from value: Any?) -> [ShaarDevToolsRecorderStep] {
    rows(from: value).compactMap(step(from:))
  }

  private static func rows(from value: Any?) -> [[String: Any]] {
    if let rows = value as? [[String: Any]] { return rows }
    guard let rows = value as? [Any] else { return [] }
    return rows.compactMap { $0 as? [String: Any] }
  }

  private static func step(from item: [String: Any]) -> ShaarDevToolsRecorderStep? {
    guard let kind = ShaarDevToolsRecorderKind(rawValue: item["kind"] as? String ?? "") else {
      return nil
    }
    let selector = item["selector"] as? String ?? ""
    let value = item["value"] as? String ?? ""
    if kind == .navigation {
      guard !value.isEmpty else { return nil }
    } else if selector.isEmpty {
      return nil
    }
    return ShaarDevToolsRecorderStep(
      id: UUID(), kind: kind, selector: selector, value: value)
  }

  private static func json(_ object: Any) -> String? {
    guard let data = try? JSONSerialization.data(withJSONObject: object),
      let text = String(data: data, encoding: .utf8)
    else { return nil }
    return text
  }
}

@MainActor @Observable final class ShaarDevToolsRecorderModel {
  private(set) var steps: [ShaarDevToolsRecorderStep] = []
  private(set) var recording = false
  private(set) var notice: ShaarRecorderNotice?
  @ObservationIgnored var evaluate: (@MainActor (String) async throws -> Any?)?
  @ObservationIgnored private var poll: Task<Void, Never>?

  func attach(_ inspector: InspectorModel) {
    evaluate = { [weak inspector] expression in
      guard let inspector else {
        throw ShaarRecorderFailure(ShellL10n.string("Recorder needs a page."))
      }
      return try await inspector.evaluate(expression)
    }
  }

  func detach() {
    let installed = evaluate
    evaluate = nil
    reset()
    guard let installed else { return }
    Task { _ = try? await installed(ShaarDevToolsRecorder.uninstallSource) }
  }

  func retarget(tabChanged: Bool, committed: Bool) {
    if tabChanged {
      reset()
      return
    }
    guard committed, recording else { return }
    Task { await reinstall() }
  }

  func apply(_ value: Any?) {
    append(ShaarDevToolsRecorder.steps(from: value))
  }

  func deleteStep(_ id: UUID) {
    steps.removeAll { $0.id == id }
  }

  func start() async {
    guard !recording else { return }
    guard let evaluate else {
      notice = .needsPage
      return
    }
    do {
      _ = try await evaluate(ShaarDevToolsRecorder.installSource)
      recording = true
      notice = nil
      await pull()
      guard recording else {
        await uninstall()
        return
      }
      poll?.cancel()
      poll = Task { await pollLoop() }
    } catch {
      recording = false
      notice = .failed(error.localizedDescription)
    }
  }

  func stop() async {
    recording = false
    poll?.cancel()
    poll = nil
    await pull()
    await uninstall()
  }

  func pull() async {
    guard let evaluate else { return }
    do {
      let value = try await evaluate(ShaarDevToolsRecorder.drainSource)
      append(ShaarDevToolsRecorder.steps(from: value))
    } catch {
      recording = false
      poll?.cancel()
      poll = nil
      notice = .failed(error.localizedDescription)
    }
  }

  func replay() async {
    if recording { await stop() }
    guard !steps.isEmpty else { return }
    guard let evaluate else {
      notice = .needsPage
      return
    }
    do {
      _ = try await evaluate(ShaarDevToolsRecorder.replaySource(steps))
      notice = nil
    } catch {
      notice = .failed(error.localizedDescription)
    }
  }

  func exportFile(in directory: URL) throws -> URL {
    let url = directory.appending(path: "shaar-flow-\(UUID().uuidString).json")
    try ShaarDevToolsRecorder.document(for: steps).write(to: url, options: .atomic)
    return url
  }

  func noteMissingFolder() {
    notice = .needsFolder
  }

  func noteSaved() {
    notice = .saved
  }

  func noteFailure(_ message: String) {
    notice = .failed(message)
  }

  func reset() {
    poll?.cancel()
    poll = nil
    recording = false
    steps = []
    notice = nil
  }

  private func uninstall() async {
    guard let evaluate else { return }
    _ = try? await evaluate(ShaarDevToolsRecorder.uninstallSource)
  }

  private func reinstall() async {
    guard recording else { return }
    await pull()
    guard recording, let evaluate else { return }
    _ = try? await evaluate(ShaarDevToolsRecorder.installSource)
  }

  private func pollLoop() async {
    while recording, !Task.isCancelled {
      try? await Task.sleep(for: .milliseconds(400))
      if Task.isCancelled || !recording { return }
      await pull()
    }
  }

  private func append(_ incoming: [ShaarDevToolsRecorderStep]) {
    guard !incoming.isEmpty else { return }
    steps.append(contentsOf: incoming)
  }
}
