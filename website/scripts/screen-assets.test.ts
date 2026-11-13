// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import assert from "node:assert/strict";
import { statSync } from "node:fs";
import test from "node:test";
import { fileURLToPath } from "node:url";
import { HomePage } from "../src/components/home";
import { screens } from "../src/content";
import { websiteScreenAssets } from "./screen-assets";

test("site build includes only screenshots referenced by page content", () => {
  const assets = websiteScreenAssets();

  assert.equal(assets.length, new Set(assets).size);
  assert.ok(assets.includes("spaces.webp"));
  assert.ok(assets.includes("page-arcusis.webp"));
  assert.ok(assets.includes("fav-arcusis.png"));
  assert.ok(!assets.includes("hero.png"));
  assert.ok(!assets.includes("page-arcusis.png"));
  assert.ok(!assets.includes("page-github.png"));
});

test("homepage story uses smaller lossless WebP screenshot assets", () => {
  const home = HomePage();
  const storyScreens = Object.entries(screens).filter(([name]) => name !== "hero");

  for (const [, screen] of storyScreens) {
    assert.ok(screen.file.endsWith(".webp"), screen.file);
    assert.ok(home.includes(`/assets/screens/${screen.file}`), screen.file);
    const webpSize = statSync(
      fileURLToPath(new URL(`../screens/${screen.file}`, import.meta.url)),
    ).size;
    const png = screen.file.replace(/\.webp$/, ".png");
    const pngSize = statSync(fileURLToPath(new URL(`../screens/${png}`, import.meta.url))).size;
    assert.ok(webpSize < pngSize, `${screen.file} should be smaller than ${png}`);
  }
});
