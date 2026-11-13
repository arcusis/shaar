// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import assert from "node:assert/strict";
import test from "node:test";
import { parseHTML } from "linkedom";
import { HomePage } from "../src/components/home";
import { DocumentPage } from "../src/components/layout";
import { siteOrigin } from "../src/content";
import { notFoundPage, Pages } from "../src/pages";

test("every generated page has a language, title, description, canonical URL, and main landmark", () => {
  const rendered = [
    HomePage(),
    ...Pages("License", "Notice", "Third-party notices").map((page) => DocumentPage(page)),
    DocumentPage(notFoundPage),
  ];

  for (const html of rendered) {
    const document = parseHTML(html).document;
    const canonical = document.querySelector('link[rel="canonical"]');
    assert.equal(document.documentElement.getAttribute("lang"), "en");
    assert.ok(document.querySelector("title")?.textContent?.trim());
    assert.ok(document.querySelector('meta[name="description"]')?.getAttribute("content"));
    assert.ok(canonical?.getAttribute("href")?.startsWith(siteOrigin));
    assert.equal(document.querySelectorAll("main").length, 1);
  }
});
