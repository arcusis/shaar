// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import { parseHTML } from "linkedom";
import { HomePage } from "../src/components/home";
import { tourCards, tourFeatures } from "../src/components/tour";
import { release } from "../src/content";
import { Pages } from "../src/pages";
import { initializeTour } from "../src/tour";

test("homepage tour keeps a short list of distinct screenshots and a thumbnail grid", () => {
  const document = parseHTML(HomePage()).document;
  assert.ok(tourFeatures.length >= 8 && tourFeatures.length <= 10);
  const articles = [...document.querySelectorAll<HTMLElement>("[data-tour-feature]")];
  const cards = [...document.querySelectorAll<HTMLElement>(".tour-card")];
  assert.equal(articles.length, tourFeatures.length);
  assert.equal(cards.length, tourCards.length);
  assert.equal(document.querySelector("[data-tour-preview], .tour-preview"), null);
  assert.equal(document.querySelector(".tour-capture-gap"), null);

  const files: string[] = [];
  for (const [nodes, items] of [
    [articles, tourFeatures],
    [cards, tourCards],
  ] as const) {
    for (const node of nodes) {
      const item = items.find((entry) => entry.id === node.id);
      assert.ok(item, node.id);
      const shot = node.querySelector("img");
      assert.equal(shot?.getAttribute("src"), `/assets/screens/${item.shot.file}`, node.id);
      assert.equal(shot?.getAttribute("width"), String(Math.round(item.shot.width / 2)), node.id);
      assert.ok(shot?.getAttribute("alt"));
      files.push(item.shot.file);
    }
  }
  assert.equal(new Set(files).size, files.length, "each section needs its own screenshot");
  const text = document.documentElement.textContent ?? "";
  assert.equal(text.includes("REFERENCE CAPTURE"), false);
  assert.equal(text.includes("45 bytes"), false);
  assert.equal(text.includes("parity-user"), false);
  assert.equal(text.includes("127.0.0.1"), false);
  assert.equal(text.includes("0.1.0"), false);
  assert.match(text, /v0\.2\.0 beta available/);
  assert.match(text, /Current release 0\.2\.0/);
  assert.match(text, /Shaar 0\.2\.0 · MPL-2\.0/);
  assert.equal(text.includes("Preview what's coming"), false);
  assert.equal(text.includes("Preview 0.2.0"), false);
});

test("download and changelog treat 0.2.0 as the current release", () => {
  const pages = Pages("", "", "");
  const download = pages.find((page) => page.path === "/download/");
  const changelog = pages.find((page) => page.path === "/changelog/");
  assert.ok(download);
  assert.ok(changelog);
  assert.match(download.body, new RegExp(release.dmg.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")));
  assert.match(download.body, /Shaar-0\.2\.0-macos\.zip/);
  assert.match(download.body, /Shaar 0\.2\.0/);
  assert.equal(download.body.includes("0.1.0"), false);
  assert.equal(download.body.includes("Coming in"), false);
  assert.equal(changelog.body.includes("Coming soon"), false);
  assert.equal(changelog.body.includes("0.1.0"), false);
  assert.match(changelog.body, /Current release/);
});

test("tour reveal stays inert when motion is reduced", () => {
  const dom = parseHTML(HomePage());
  Object.assign(globalThis, {
    document: dom.document,
    window: {
      matchMedia: () => ({ matches: true, addEventListener: () => {} }),
      addEventListener: () => {},
      requestAnimationFrame: () => 0,
    },
  });
  initializeTour();
  assert.equal(dom.document.documentElement.dataset.tourMotion, undefined);
  assert.ok(dom.document.querySelector("#spaces img"));
  assert.ok(dom.document.querySelector("#hebrew img"));
});

test("tour stays readable without JavaScript and honors reduced motion", () => {
  const document = parseHTML(HomePage()).document;
  assert.ok(document.querySelector("#spaces h3"));
  assert.ok(document.querySelector("#hebrew img"));
  assert.ok(document.querySelector("#downloads img"));
  const styles = readFileSync(new URL("../src/styles.css", import.meta.url), "utf8");
  assert.match(styles, /@media \(prefers-reduced-motion: reduce\)/);
  assert.equal(styles.includes(".tour-preview"), false);
});
