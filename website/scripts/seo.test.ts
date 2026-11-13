// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import assert from "node:assert/strict";
import test from "node:test";
import { parseHTML } from "linkedom";
import { Layout } from "../src/components/layout";
import { notFoundPage } from "../src/pages";

test("404 page tells search engines not to index it", () => {
  const document = parseHTML(Layout(notFoundPage, "")).document;
  assert.equal(document.querySelector('meta[name="robots"]')?.getAttribute("content"), "noindex");
});
