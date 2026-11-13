// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import assert from "node:assert/strict";
import test from "node:test";
import { parseHTML } from "linkedom";
import { ShaarDemo } from "../src/components/demo";

test("all demo page captures, including the initial one, load lazily", () => {
  const document = parseHTML(ShaarDemo()).document;
  const images = document.querySelectorAll(".demo-page-image");

  assert.ok(images.length > 0);
  for (const image of images) assert.equal(image.getAttribute("loading"), "lazy");
});
