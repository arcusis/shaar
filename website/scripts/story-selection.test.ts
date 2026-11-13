// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import assert from "node:assert/strict";
import test from "node:test";
import { nearestStep } from "../src/story";

test("story selects the step nearest the viewport center regardless of observer order", () => {
  const steps = [
    { id: "far", getBoundingClientRect: () => ({ top: -20, height: 100 }) },
    { id: "near", getBoundingClientRect: () => ({ top: 40, height: 100 }) },
    { id: "middle", getBoundingClientRect: () => ({ top: 140, height: 100 }) },
  ];

  assert.equal(nearestStep(steps, 100)?.id, "near");
});
