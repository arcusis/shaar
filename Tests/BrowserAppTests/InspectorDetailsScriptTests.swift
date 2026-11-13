// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import JavaScriptCore
import Testing
@testable import ArcusisBrowser

struct InspectorDetailsScriptTests {
  @Test func explicitlyExcludedContentEditableIsNotInSequentialTabOrder() throws {
    let context = try #require(JSContext())
    let setup = #"""
      globalThis.window = {frames: [], addEventListener() {}, getComputedStyle() { return {visibility: 'visible'}; }};
      const parent = {isContentEditable: false};
      const node = {
        localName: 'div', id: '', tabIndex: -1, isContentEditable: true, parentElement: parent,
        attributes: [], ownerDocument: null,
        getClientRects() { return [{}]; }, matches() { return false; }, closest() { return null; },
        hasAttribute(name) { return name === 'contenteditable' || name === 'tabindex'; }
      };
      const document = {
        addEventListener() {}, removeEventListener() {}, querySelectorAll() { return [node]; }
      };
      node.ownerDocument = document;
      document.defaultView = window;
      window.document = document;
      globalThis.__shaarInspectorV2 = {element() { return node; }, onStop() {}};
      """#
    #expect(context.evaluateScript(setup)?.toBool() == true)
    #expect(context.evaluateScript(InspectorDetailsScript.install)?.toBool() == true)
    let tabOrder = context.evaluateScript("__shaarInspectorDetails.accessibility().tabOrder")

    #expect(tabOrder?.isNull == true)
    #expect(context.exception == nil)
  }
}
