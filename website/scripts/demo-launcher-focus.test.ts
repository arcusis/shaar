// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import assert from "node:assert/strict";
import test from "node:test";
import { parseHTML } from "linkedom";
import { ShaarDemo } from "../src/components/demo";
import { initializeDemo } from "../src/demo";

test("address launcher keeps its visible host as its accessible name", () => {
  const dom = parseHTML(ShaarDemo());
  const trigger = dom.document.querySelector<HTMLButtonElement>(".demo-address");

  assert.ok(trigger);
  assert.equal(trigger.getAttribute("aria-label"), null);
  assert.equal(trigger.querySelector("[data-host]")?.textContent, "arcusis.com");
});

test("Escape from the search launcher restores focus to its trigger", () => {
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
  const launcher = dom.document.querySelector<HTMLElement>(".demo-launcher");
  const input = dom.document.querySelector<HTMLInputElement>(".demo-launcher input");
  assert.ok(trigger);
  assert.ok(launcher);
  assert.ok(input);
  let focusCalls = 0;
  trigger.focus = () => {
    focusCalls += 1;
  };

  initializeDemo();
  trigger.click();
  assert.equal(launcher.hidden, false);

  const keyEvent = new dom.Event("keydown", { bubbles: true });
  Object.defineProperty(keyEvent, "key", { value: "Escape" });
  input.dispatchEvent(keyEvent);

  assert.equal(launcher.hidden, true);
  assert.equal(focusCalls, 1);
});
