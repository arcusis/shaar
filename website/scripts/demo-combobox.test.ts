// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import assert from "node:assert/strict";
import test from "node:test";
import { parseHTML } from "linkedom";
import { ShaarDemo } from "../src/components/demo";
import { initializeDemo } from "../src/demo";

test("search launcher exposes its listbox and active result to assistive technology", () => {
  const dom = parseHTML(ShaarDemo());
  Object.assign(globalThis, {
    document: dom.document,
    Element: dom.Element,
    HTMLElement: dom.HTMLElement,
    HTMLButtonElement: dom.HTMLButtonElement,
    HTMLImageElement: dom.HTMLImageElement,
    HTMLInputElement: dom.HTMLInputElement,
  });
  const trigger = dom.document.querySelector<HTMLButtonElement>("[data-launcher]");
  const input = dom.document.querySelector<HTMLInputElement>(".demo-launcher input");
  const results = dom.document.querySelector<HTMLElement>(".demo-results");
  assert.ok(trigger);
  assert.ok(input);
  assert.ok(results);

  initializeDemo();
  assert.equal(input.getAttribute("role"), "combobox");
  assert.equal(input.getAttribute("aria-controls"), results.id);
  trigger.click();
  assert.equal(input.getAttribute("aria-expanded"), "true");

  const activeId = input.getAttribute("aria-activedescendant");
  assert.ok(activeId);
  assert.equal(results.querySelector(`#${activeId}`)?.getAttribute("aria-selected"), "true");

  const keyEvent = new dom.Event("keydown", { bubbles: true });
  Object.defineProperty(keyEvent, "key", { value: "ArrowDown" });
  input.dispatchEvent(keyEvent);
  const nextActiveId = input.getAttribute("aria-activedescendant");
  assert.notEqual(nextActiveId, activeId);
  assert.equal(results.querySelector(`#${nextActiveId}`)?.getAttribute("aria-selected"), "true");
});
