// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import assert from "node:assert/strict";
import test from "node:test";
import { siteOrigin } from "../src/content";
import { notFoundPage, Pages } from "../src/pages";
import { sitemapXML } from "../src/sitemap";

test("sitemap includes canonical pages and excludes the not-found page", () => {
  const pages = [...Pages("", "", ""), notFoundPage];
  const urls = [...sitemapXML(pages).matchAll(/<loc>(.*?)<\/loc>/g)].map((match) => match[1]);

  assert.deepEqual(urls, [
    `${siteOrigin}/`,
    ...Pages("", "", "").map((page) => `${siteOrigin}${page.path}`),
  ]);
  assert.ok(!urls.includes(`${siteOrigin}/404.html`));
});
