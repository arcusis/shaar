// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import assert from "node:assert/strict";
import test from "node:test";
import { websiteScreenAssets } from "./screen-assets";

test("site build includes only screenshots referenced by page content", () => {
  const assets = websiteScreenAssets();

  assert.equal(assets.length, new Set(assets).size);
  assert.ok(assets.includes("spaces.png"));
  assert.ok(assets.includes("page-arcusis.webp"));
  assert.ok(assets.includes("fav-arcusis.png"));
  assert.ok(!assets.includes("hero.png"));
  assert.ok(!assets.includes("page-arcusis.png"));
  assert.ok(!assets.includes("page-github.png"));
});
