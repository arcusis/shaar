// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import assert from "node:assert/strict";
import test from "node:test";
import { parseHTML } from "linkedom";
import { ShaarDemo } from "../src/components/demo";
import { initializeDemo } from "../src/demo";

test("Escape closes Site controls and restores focus to its button", () => {
  const dom = parseHTML(ShaarDemo());
  Object.assign(globalThis, {
    document: dom.document,
    Element: dom.Element,
    HTMLElement: dom.HTMLElement,
    HTMLButtonElement: dom.HTMLButtonElement,
    HTMLImageElement: dom.HTMLImageElement,
    HTMLInputElement: dom.HTMLInputElement,
  });

  const button = dom.document.querySelector<HTMLButtonElement>("[data-controls]");
  const popover = dom.document.querySelector<HTMLElement>(".demo-popover");
  assert.ok(button);
  assert.ok(popover);
  let focusCalls = 0;
  button.focus = () => {
    focusCalls += 1;
  };

  initializeDemo();
  button.click();
  assert.equal(popover.hidden, false);

  const keyEvent = new dom.Event("keydown", { bubbles: true });
  Object.defineProperty(keyEvent, "key", { value: "Escape" });
  dom.document.dispatchEvent(keyEvent);

  assert.equal(popover.hidden, true);
  assert.equal(button.getAttribute("aria-expanded"), "false");
  assert.equal(focusCalls, 1);
});
