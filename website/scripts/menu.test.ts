// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import assert from "node:assert/strict";
import test from "node:test";
import { parseHTML } from "linkedom";
import { Navigation } from "../src/components/navigation";
import { initializeMenu } from "../src/menu";

test("mobile navigation opens and Escape closes it with focus restored", () => {
  const document = parseHTML(Navigation("/privacy/")).document;
  const button = document.querySelector<HTMLButtonElement>(".menu-control");
  const navigation = document.querySelector<HTMLElement>(".mobile-nav");
  assert.ok(button);
  assert.ok(navigation);
  let focusCalls = 0;
  button.focus = () => {
    focusCalls += 1;
  };

  initializeMenu(document);
  assert.equal(button.hidden, false);
  button.click();
  assert.equal(navigation.dataset.open, "true");
  assert.equal(button.getAttribute("aria-expanded"), "true");
  assert.equal(button.textContent, "Close");

  const window = document.defaultView;
  assert.ok(window);
  const keyboardEvent = new window.Event("keydown", { bubbles: true });
  Object.defineProperty(keyboardEvent, "key", { value: "Escape" });
  document.dispatchEvent(keyboardEvent);

  assert.equal(navigation.dataset.open, undefined);
  assert.equal(button.getAttribute("aria-expanded"), "false");
  assert.equal(button.textContent, "Menu");
  assert.equal(focusCalls, 1);

  button.click();
  navigation.querySelector<HTMLAnchorElement>('a[aria-current="page"]')?.click();
  assert.equal(navigation.dataset.open, undefined);
  assert.equal(button.getAttribute("aria-expanded"), "false");
});
