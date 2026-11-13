// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

test("demo launcher input keeps a visible keyboard focus indicator", () => {
  const styles = readFileSync(new URL("../src/styles.css", import.meta.url), "utf8");
  assert.match(
    styles,
    /\.demo-launcher-field input:focus-visible\s*\{[^}]*outline:\s*2px solid var\(--forest\)/s,
  );
});
