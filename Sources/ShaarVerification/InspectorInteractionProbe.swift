// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import Foundation
import SwiftUI

@testable import ArcusisBrowser

enum InspectorInteractionProbeOptions {
  static let domEventsArgument = "--probe-shaar-inspector-dom-input"

  static func usesDOMEvents(arguments: [String]) -> Bool {
    arguments.contains(domEventsArgument)
  }
}

enum InspectorInteractionEvidence {
  static func acceptsInput(trusted: Bool?, activated: Int?, usesDOMEvents: Bool) -> Bool {
    trusted == !usesDOMEvents && activated == 0
  }
}

/// Synthesized AppKit events use the real native hit-test and renderer overlay.
/// Does not prove physical desktop input or visible-window presentation.
@MainActor
struct InspectorInteractionProbe {
  let model: InspectorModel
  let view: NSView
  private var usesDOMEvents: Bool {
    InspectorInteractionProbeOptions.usesDOMEvents(arguments: CommandLine.arguments)
  }

  func run(record: (String) -> Void) async throws {
    defer { model.close() }
    let start = Date()
    try await wait("product script installation") {
      try await model.evaluate("!!globalThis.__shaarInspectorV2") as? Bool == true
    }
    guard Date().timeIntervalSince(start) < 2 else {
      throw InspectorFailure("Product Inspector installation exceeded two seconds.")
    }
    record("promptInstallation")
    _ = try await model.evaluate(Self.fixture)
    for id in ["input-button", "input-span", "input-link", "input-field"] {
      await model.pick()?.value
      try await click(id)
      do {
        try await wait("panel selection for \(id)") {
          model.selection?.identifier == id && model.mode == .locked
        }
      } catch {
        let state = try? await model.evaluate(
          "({events:globalThis.inspectorInputEvents,ready:document.readyState,visibility:document.visibilityState,state:globalThis.__shaarInspectorV2.read(),overlay:globalThis.__shaarInspectorV2.overlay()})"
        )
        FileHandle.standardError.write(
          Data(
            "Inspector input failure: \(String(describing: state)); model=\(model.failure ?? "none")\n"
              .utf8))
        throw error
      }
      guard
        let overlay = try await model.evaluate("globalThis.__shaarInspectorV2.overlay()")
          as? [String: Any], overlay["painted"] as? Bool == true,
        model.selection?.box.width ?? 0 > 0,
        model.selection?.typography.preview.isEmpty == false || id == "input-field"
      else { throw InspectorFailure("Selected element has no panel details or overlay.") }
      record("selected.\(id)")
      if id == "input-button" { try capturePanel() }
    }
    let trusted = try await model.evaluate("globalThis.inspectorInputTrusted") as? Bool
    guard InspectorInteractionEvidence.acceptsInput(
      trusted: trusted,
      activated: try await model.evaluate("globalThis.inspectorInputActivated || 0") as? Int,
      usesDOMEvents: usesDOMEvents)
    else { throw InspectorFailure("Input was untrusted or activated the inspected page.") }
    model.close()
    try await wait("overlay removal after close") {
      try await model.evaluate("!document.querySelector('[data-shaar-inspector]')") as? Bool == true
    }
    try await click("input-button")
    try await wait("ordinary page click after close") {
      try await model.evaluate("globalThis.inspectorInputActivated === 1") as? Bool == true
    }
    guard !model.isOpen, model.selection == nil,
      NSApp.windows.allSatisfy({ !$0.isVisible })
    else { throw InspectorFailure("Inspector did not close or exposed a native window.") }
    record("closeRestoresPageInput")
    record(usesDOMEvents ? "untrustedDOMEventsOnly" : "trustedAppKitEvents")
  }

  private func click(_ id: String) async throws {
    guard
      let box = try await model.evaluate(
        "(()=>{const r=document.getElementById('\(id)').getBoundingClientRect();return {x:r.x+r.width/2,y:r.y+r.height/2}})()"
      ) as? [String: Double], let x = box["x"], let y = box["y"],
      let window = view.window, !window.isVisible, let content = window.contentView
    else { throw InspectorFailure("Hidden native input target is unavailable.") }
    if usesDOMEvents {
      // Explicit fallback for locked desktops: preserve DOM hit-testing and all
      // product overlay handlers, without claiming trusted/native input delivery.
      _ = try await model.evaluate(
        """
        (()=>{const x=\(x),y=\(y);const node=document.elementFromPoint(x,y);
        for(const type of ['pointermove','pointerdown','pointerup'])node.dispatchEvent(new PointerEvent(type,{clientX:x,clientY:y,button:0,bubbles:true,composed:true}));
        node.dispatchEvent(new MouseEvent('click',{clientX:x,clientY:y,button:0,bubbles:true,composed:true}));return true;})()
        """)
      return
    }
    content.layoutSubtreeIfNeeded()
    let local = NSPoint(x: x, y: view.isFlipped ? y : view.bounds.height - y)
    let location = view.convert(local, to: nil)
    guard let receiver = content.hitTest(content.convert(location, from: nil)),
      receiver === view || receiver.isDescendant(of: view)
    else { throw InspectorFailure("Native hit test did not reach the page.") }
    FileHandle.standardError.write(
      Data("Inspector input receiver: \(type(of: receiver)) \(id)\n".utf8))
    for type in [NSEvent.EventType.mouseMoved, .leftMouseDown, .leftMouseUp] {
      guard
        let event = NSEvent.mouseEvent(
          with: type, location: location, modifierFlags: [],
          timestamp: ProcessInfo.processInfo.systemUptime,
          windowNumber: window.windowNumber, context: nil, eventNumber: 0,
          clickCount: type == .mouseMoved ? 0 : 1, pressure: type == .leftMouseDown ? 1 : 0)
      else { throw InspectorFailure("Could not construct AppKit mouse event.") }
      switch type {
      case .mouseMoved: receiver.mouseMoved(with: event)
      case .leftMouseDown: receiver.mouseDown(with: event)
      default: receiver.mouseUp(with: event)
      }
    }
  }

  private func capturePanel() throws {
    let arguments = CommandLine.arguments
    guard let index = arguments.firstIndex(of: "--probe-output"),
      arguments.indices.contains(index + 1)
    else { throw InspectorFailure("Inspector input evidence output is missing.") }
    let host = NSHostingView(rootView: InspectorPanel(model: model).frame(width: 320, height: 780))
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 320, height: 780), styleMask: .borderless,
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    defer {
      window.contentView = nil
      window.close()
    }
    host.layoutSubtreeIfNeeded()
    guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
      throw InspectorFailure("Inspector panel bitmap is unavailable.")
    }
    host.cacheDisplay(in: host.bounds, to: bitmap)
    guard let data = bitmap.representation(using: .png, properties: [:]) else {
      throw InspectorFailure("Inspector panel PNG encoding failed.")
    }
    let url = URL(filePath: arguments[index + 1]).deletingLastPathComponent()
      .appending(path: "inspector-panel-\(model.target.tabID).png")
    try data.write(to: url)
    FileHandle.standardError.write(Data("Offscreen Inspector panel: \(url.path)\n".utf8))
  }

  private func wait(_ name: String, until ready: () async throws -> Bool) async throws {
    let deadline = Date().addingTimeInterval(3)
    while try await !ready() {
      guard Date() < deadline else { throw InspectorFailure("Timed out waiting for \(name).") }
      try await Task.sleep(for: .milliseconds(50))
    }
  }

  private static let fixture = #"""
    (()=>{
      const old=document.getElementById('inspector-input-fixture');old?.remove();
      const root=document.createElement('div');root.id='inspector-input-fixture';
      root.style.cssText='position:fixed;left:20px;top:20px;z-index:100000;background:white;color:black;padding:10px;display:grid;gap:10px';
      root.innerHTML='<button id="input-button">Button</button><div><span id="input-span">Nested text</span></div><a id="input-link" href="#input">Link</a><input id="input-field" value="Input">';
      document.body.append(root);globalThis.inspectorInputActivated=0;globalThis.inspectorInputEvents=[];
      for(const type of ['pointermove','pointerdown','pointerup','click'])document.addEventListener(type,e=>{globalThis.inspectorInputTrusted=e.isTrusted;globalThis.inspectorInputEvents.push({type:e.type,trusted:e.isTrusted,x:e.clientX,y:e.clientY,target:e.target.id,shield:e.target.hasAttribute('data-shaar-inspector')});},{capture:true});
      root.querySelector('button').onclick=()=>globalThis.inspectorInputActivated++;
      return true;
    })()
    """#
}
