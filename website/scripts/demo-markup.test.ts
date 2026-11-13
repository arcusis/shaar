// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import assert from "node:assert/strict";
import test from "node:test";
import { parseHTML } from "linkedom";
import { ShaarDemo } from "../src/components/demo";

test("search launcher triggers expose their dialog popup type", () => {
  const document = parseHTML(ShaarDemo()).document;
  const triggers = document.querySelectorAll("[data-launcher]");

  assert.equal(triggers.length, 4);
  for (const trigger of triggers) assert.equal(trigger.getAttribute("aria-haspopup"), "dialog");
});
