// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import assert from "node:assert/strict";
import test from "node:test";
import {
  applyMotionPreferenceChange,
  resetPointerOnLeave,
  updateSceneVisibility,
} from "../src/scene";

test("returning to a visible tab does not animate an offscreen scene", () => {
  const visibility = { inViewport: true, documentVisible: true };
  assert.equal(updateSceneVisibility(visibility, { inViewport: false }), false);
  assert.equal(updateSceneVisibility(visibility, { documentVisible: false }), false);
  assert.equal(updateSceneVisibility(visibility, { documentVisible: true }), false);
  assert.equal(updateSceneVisibility(visibility, { inViewport: true }), true);
});

test("motion preference changes stop or resume hero animation", () => {
  let cancelled = 0;
  let wakes = 0;
  let redraws = 0;
  const cancel = (frame: number) => {
    cancelled = frame;
  };
  const wake = () => {
    wakes += 1;
  };
  const redraw = () => {
    redraws += 1;
  };

  assert.equal(applyMotionPreferenceChange(false, true, 12, cancel, wake, redraw), true);
  assert.equal(cancelled, 12);
  assert.equal(redraws, 1);
  assert.equal(applyMotionPreferenceChange(true, false, 0, cancel, wake, redraw), false);
  assert.equal(wakes, 1);
});

test("pointer leave redraws the scene when reduced motion disables animation", () => {
  const pointer = { x: 12, y: 24, targetX: 0.2, targetY: -0.1 };
  let redraws = 0;

  resetPointerOnLeave(pointer, true, () => {
    redraws += 1;
  });

  assert.deepEqual(pointer, { x: -9999, y: -9999, targetX: 0, targetY: 0 });
  assert.equal(redraws, 1);
});

test("pointer leave does not schedule an extra redraw during animation", () => {
  let redraws = 0;
  resetPointerOnLeave({ x: 12, y: 24, targetX: 0.2, targetY: -0.1 }, false, () => {
    redraws += 1;
  });

  assert.equal(redraws, 0);
});
