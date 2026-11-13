// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import assert from "node:assert/strict";
import test from "node:test";
import { parseHTML } from "linkedom";
import { Layout } from "../src/components/layout";
import type { SitePage } from "../src/content";

test("layout provides matching Twitter metadata for page shares", () => {
  const page: SitePage = {
    path: "/privacy/",
    title: "Privacy",
    heading: "Privacy",
    description: "Privacy details for Shaar.",
    body: "",
  };
  const document = parseHTML(Layout(page, "")).document;

  assert.equal(
    document.querySelector('meta[name="twitter:card"]')?.getAttribute("content"),
    "summary",
  );
  assert.equal(
    document.querySelector('meta[name="twitter:title"]')?.getAttribute("content"),
    "Privacy · Shaar",
  );
  assert.equal(
    document.querySelector('meta[name="twitter:description"]')?.getAttribute("content"),
    page.description,
  );
  assert.equal(
    document.querySelector('meta[name="twitter:image"]')?.getAttribute("content"),
    "https://shaar.arcusis.com/assets/shaar-icon.png",
  );
  assert.equal(
    document.querySelector('meta[property="og:image:alt"]')?.getAttribute("content"),
    "Shaar",
  );
  assert.equal(
    document.querySelector('meta[name="twitter:image:alt"]')?.getAttribute("content"),
    "Shaar",
  );
});
