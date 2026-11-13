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

test("layout preloads only font files available to the build", () => {
  const page: SitePage = {
    path: "/",
    title: "Shaar",
    heading: "Shaar",
    description: "A browser.",
    body: "",
  };
  const document = parseHTML(Layout(page, "", [])).document;
  assert.equal(document.querySelectorAll('link[rel="preload"][as="font"]').length, 0);

  const withOneFont = parseHTML(Layout(page, "", ["satoshi.woff2"])).document;
  assert.equal(
    withOneFont.querySelector('link[rel="preload"][as="font"]')?.getAttribute("href"),
    "/assets/fonts/satoshi.woff2",
  );
  assert.equal(withOneFont.querySelectorAll('link[rel="preload"][as="font"]').length, 1);
});
