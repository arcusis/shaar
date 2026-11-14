// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import assert from "node:assert/strict";
import { createRequire } from "node:module";
import test from "node:test";
import { accessibilityStandards } from "../src/a11y";

const require = createRequire(import.meta.url);
const axe = require("axe-core");

test("accessibility audit covers WCAG 2.2 AA tags supported by axe", () => {
  assert.ok(accessibilityStandards.includes("wcag22aa"));
  const supportedTags = new Set(axe.getRules().flatMap((rule: { tags: string[] }) => rule.tags));
  for (const tag of accessibilityStandards) assert.ok(supportedTags.has(tag), tag);
});
