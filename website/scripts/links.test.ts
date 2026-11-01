// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { checkLinks, localTarget } from "./links";

test("link checker resolves directory URLs and catches broken links and fragments", () => {
  const root = mkdtempSync(join(tmpdir(), "shaar-links-"));
  try {
    mkdirSync(join(root, "download"));
    writeFileSync(
      join(root, "index.html"),
      '<h1 id="home">Home</h1><a href="/download/">Download</a><a href="/download/#install">Install</a><a href="/download/#missing">Broken fragment</a><a href="/missing/">Broken page</a><img src="/image.png">',
    );
    writeFileSync(
      join(root, "download/index.html"),
      '<h1 id="install">Install</h1><a href="/#home">Home</a>',
    );
    writeFileSync(join(root, "image.png"), "fixture");
    const result = checkLinks(root);
    assert.equal(result.pages, 2);
    assert.deepEqual(result.errors, [
      "index.html: missing fragment /download/#missing",
      "index.html: missing target /missing/",
      "index.html: image missing alt",
    ]);
    assert.equal(
      localTarget(root, new URL("https://shaar.arcusis.com/%2f..%2foutside.txt")),
      undefined,
    );
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("link checker rejects unsafe schemes and duplicate ids", () => {
  const root = mkdtempSync(join(tmpdir(), "shaar-links-"));
  try {
    writeFileSync(
      join(root, "index.html"),
      '<h1 id="same">Home</h1><p id="same">Duplicate</p><a href="javascript:void(0)">Unsafe</a>',
    );
    assert.deepEqual(checkLinks(root).errors, [
      "index.html: duplicate id same",
      "index.html: empty or unsafe link",
    ]);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});
