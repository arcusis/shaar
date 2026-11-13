// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { prepareFonts } from "./fonts";

test("invalid cached font manifest falls back to system fonts", async () => {
  const root = mkdtempSync(join(tmpdir(), "shaar-fonts-"));
  const cache = join(root, "cache");
  mkdirSync(cache);
  writeFileSync(join(cache, "fonts.json"), "not JSON");
  try {
    assert.deepEqual(await prepareFonts(cache, join(root, "output")), []);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("missing cached font file falls back to system fonts", async () => {
  const root = mkdtempSync(join(tmpdir(), "shaar-fonts-"));
  const cache = join(root, "cache");
  mkdirSync(cache);
  writeFileSync(
    join(cache, "fonts.json"),
    JSON.stringify([{ family: "Satoshi", file: "satoshi.woff2", weight: "300 900" }]),
  );
  try {
    assert.deepEqual(await prepareFonts(cache, join(root, "output")), []);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("cached font manifest rejects unexpected font paths", async () => {
  const root = mkdtempSync(join(tmpdir(), "shaar-fonts-"));
  const cache = join(root, "cache");
  mkdirSync(cache);
  writeFileSync(
    join(cache, "fonts.json"),
    JSON.stringify([{ family: "Satoshi", file: "../outside.woff2", weight: "300 900" }]),
  );
  try {
    assert.deepEqual(await prepareFonts(cache, join(root, "output")), []);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("cached font manifest rejects inherited family names", async () => {
  const root = mkdtempSync(join(tmpdir(), "shaar-fonts-"));
  const cache = join(root, "cache");
  mkdirSync(cache);
  writeFileSync(join(cache, "[object Object].woff2"), "not a site font");
  writeFileSync(
    join(cache, "fonts.json"),
    JSON.stringify([{ family: "__proto__", file: "[object Object].woff2", weight: "300 900" }]),
  );
  try {
    assert.deepEqual(await prepareFonts(cache, join(root, "output")), []);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});
