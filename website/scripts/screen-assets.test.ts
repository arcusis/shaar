// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import assert from "node:assert/strict";
import { statSync } from "node:fs";
import test from "node:test";
import { fileURLToPath } from "node:url";
import { HomePage } from "../src/components/home";
import { tourCards, tourFeatures } from "../src/components/tour";
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
  for (const feature of [...tourFeatures, ...tourCards]) {
    assert.ok(assets.includes(feature.shot.file), feature.id);
  }
});

test("homepage tour uses smaller lossless WebP screenshots", () => {
  const home = HomePage();
  assert.equal(home.includes("REFERENCE CAPTURE"), false);
  assert.equal(home.includes("capture pending"), false);
  const seen = new Set<string>();

  for (const feature of [...tourFeatures, ...tourCards]) {
    const shot = feature.shot;
    if (seen.has(shot.file)) continue;
    seen.add(shot.file);
    assert.ok(shot.file.endsWith(".webp"), feature.id);
    assert.ok(home.includes(`/assets/screens/${shot.file}`), feature.id);
    const webpSize = statSync(
      fileURLToPath(new URL(`../screens/${shot.file}`, import.meta.url)),
    ).size;
    const png = shot.file.replace(/\.webp$/, ".png");
    const pngSize = statSync(fileURLToPath(new URL(`../screens/${png}`, import.meta.url))).size;
    assert.ok(webpSize < pngSize, `${shot.file} should be smaller than ${png}`);
  }
});
