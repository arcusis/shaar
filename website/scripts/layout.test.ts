// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import assert from "node:assert/strict";
import test from "node:test";
import { parseHTML } from "linkedom";
import { Layout } from "../src/components/layout";
import type { SitePage } from "../src/content";

test("layout defers the client script", () => {
  const page: SitePage = {
    path: "/",
    title: "Shaar",
    heading: "Shaar",
    description: "A browser.",
    body: "",
  };
  const document = parseHTML(Layout(page, "")).document;
  const script = document.querySelector('script[src="/assets/client.js"]');
  assert.ok(script);
  assert.equal(script.hasAttribute("defer"), true);
});
