// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

test("Biome excludes the generated font cache", () => {
  const config = JSON.parse(readFileSync(new URL("../biome.json", import.meta.url), "utf8"));
  assert.ok(config.files.includes.includes("!.font-cache"));
});
