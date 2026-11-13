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
      "index.html: image missing or whitespace-only alt",
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
test("link checker rejects whitespace-only image alternatives but allows decorative images", () => {
  const root = mkdtempSync(join(tmpdir(), "shaar-links-"));
  try {
    writeFileSync(
      join(root, "index.html"),
      '<h1>Home</h1><img src="/decorative.png" alt=""><img src="/unclear.png" alt="   ">',
    );
    writeFileSync(join(root, "decorative.png"), "fixture");
    writeFileSync(join(root, "unclear.png"), "fixture");
    assert.deepEqual(checkLinks(root).errors, ["index.html: image missing or whitespace-only alt"]);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("link checker validates every responsive image source", () => {
  const root = mkdtempSync(join(tmpdir(), "shaar-links-"));
  try {
    writeFileSync(
      join(root, "index.html"),
      '<h1>Home</h1><img src="/missing-fallback.png" alt="" srcset="/medium.png 2x, /large.png 3x">',
    );
    assert.deepEqual(checkLinks(root).errors, [
      "index.html: missing target /missing-fallback.png",
      "index.html: missing target /medium.png",
      "index.html: missing target /large.png",
    ]);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("link checker validates the image fallback when srcset is present", () => {
  const root = mkdtempSync(join(tmpdir(), "shaar-links-"));
  try {
    writeFileSync(
      join(root, "index.html"),
      '<h1>Home</h1><img src="/fallback.png" alt="" srcset="/small.png 1x">',
    );
    writeFileSync(join(root, "small.png"), "fixture");
    assert.deepEqual(checkLinks(root).errors, ["index.html: missing target /fallback.png"]);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("link checker verifies image map associations", () => {
  const root = mkdtempSync(join(tmpdir(), "shaar-links-"));
  try {
    mkdirSync(join(root, "north"));
    writeFileSync(join(root, "north/index.html"), "<h1>North</h1>");
    writeFileSync(join(root, "map.png"), "fixture");
    writeFileSync(
      join(root, "index.html"),
      '<h1>Home</h1><img src="/map.png" alt="Map" usemap="#regions"><map name="regions"><area href="/north/" alt="North"></map><img src="/map.png" alt="Map" usemap="#missing">',
    );
    assert.deepEqual(checkLinks(root).errors, [
      "index.html: image references missing map #missing",
    ]);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("link checker reports images that target a missing map", () => {
  const root = mkdtempSync(join(tmpdir(), "shaar-links-"));
  try {
    writeFileSync(
      join(root, "index.html"),
      '<h1>Home</h1><img src="/map.png" alt="Map" usemap="#missing-map">',
    );
    writeFileSync(join(root, "map.png"), "fixture");
    assert.deepEqual(checkLinks(root).errors, [
      "index.html: image references missing map #missing-map",
    ]);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("link checker validates inline SVG image files and use fragments", () => {
  const root = mkdtempSync(join(tmpdir(), "shaar-links-"));
  try {
    writeFileSync(
      join(root, "index.html"),
      '<h1>Home</h1><svg><image href="/missing.png"/><use href="/symbols.svg#missing"/></svg>',
    );
    writeFileSync(join(root, "symbols.svg"), '<svg><symbol id="present"/></svg>');
    assert.deepEqual(checkLinks(root).errors, [
      "index.html: missing target /missing.png",
      "index.html: missing fragment /symbols.svg#missing",
    ]);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});


test("link checker validates quoted CSS imports outside comments", () => {
  const root = mkdtempSync(join(tmpdir(), "shaar-links-"));
  try {
    writeFileSync(join(root, "index.html"), "<h1>Home</h1>");
    writeFileSync(
      join(root, "styles.css"),
      '@import "/missing-import.css"; @import/**/"/missing-comment-separated.css"; /* @import "/commented.css"; */ .x { content: "@import \'/string.css\'"; }',
    );
    assert.deepEqual(checkLinks(root).errors, [
      "styles.css: missing/nonlocal CSS asset /missing-import.css",
      "styles.css: missing/nonlocal CSS asset /missing-comment-separated.css",
    ]);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("link checker validates embedded object resources", () => {
  const root = mkdtempSync(join(tmpdir(), "shaar-links-"));
  try {
    writeFileSync(
      join(root, "index.html"),
      '<h1>Home</h1><embed src="/missing-embed.pdf"><object data="/missing-object.svg"></object>',
    );
    assert.deepEqual(checkLinks(root).errors, [
      "index.html: missing target /missing-embed.pdf",
      "index.html: missing target /missing-object.svg",
    ]);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});
test("link checker catches missing poster when video source exists", () => {
  const root = mkdtempSync(join(tmpdir(), "shaar-links-"));
  try {
    writeFileSync(
      join(root, "index.html"),
      '<h1>Home</h1><video src="/clip.mp4" poster="/missing-poster.png"></video>',
    );
    writeFileSync(join(root, "clip.mp4"), "fixture");
    assert.deepEqual(checkLinks(root).errors, ["index.html: missing target /missing-poster.png"]);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("link checker validates image map destinations", () => {
  const root = mkdtempSync(join(tmpdir(), "shaar-links-"));
  try {
    writeFileSync(
      join(root, "index.html"),
      '<h1>Home</h1><img src="/map.png" alt="Map" usemap="#places"><map name="places"><area href="/missing-place/" alt="Missing place"></map>',
    );
    writeFileSync(join(root, "map.png"), "fixture");
    assert.deepEqual(checkLinks(root).errors, ["index.html: missing target /missing-place/"]);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("link checker requires alternative text for image map links", () => {
  const root = mkdtempSync(join(tmpdir(), "shaar-links-"));
  try {
    mkdirSync(join(root, "place"));
    writeFileSync(join(root, "place/index.html"), "<h1>Place</h1>");
    writeFileSync(
      join(root, "index.html"),
      '<h1>Home</h1><img src="/map.png" alt="Map" usemap="#places"><map name="places"><area href="/place/"></map>',
    );
    writeFileSync(join(root, "map.png"), "fixture");
    assert.deepEqual(checkLinks(root).errors, ["index.html: image map area missing alt"]);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("link checker rejects empty alternative text on image map links", () => {
  const root = mkdtempSync(join(tmpdir(), "shaar-links-"));
  try {
    mkdirSync(join(root, "place"));
    writeFileSync(join(root, "place/index.html"), "<h1>Place</h1>");
    writeFileSync(
      join(root, "index.html"),
      '<h1>Home</h1><img src="/map.png" alt="Map" usemap="#places"><map name="places"><area href="/place/" alt="   "></map>',
    );
    writeFileSync(join(root, "map.png"), "fixture");
    assert.deepEqual(checkLinks(root).errors, ["index.html: image map area missing alt"]);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("link checker validates social preview image targets", () => {
  const root = mkdtempSync(join(tmpdir(), "shaar-links-"));
  try {
    writeFileSync(
      join(root, "index.html"),
      '<meta property="og:image" content="/social.png"><meta name="twitter:image" content="/missing.png"><h1>Home</h1>',
    );
    writeFileSync(join(root, "social.png"), "fixture");
    assert.deepEqual(checkLinks(root).errors, ["index.html: missing target /missing.png"]);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("link checker validates inline SVG resource references", () => {
  const root = mkdtempSync(join(tmpdir(), "shaar-links-"));
  try {
    writeFileSync(
      join(root, "index.html"),
      '<h1>Home</h1><div id="icon"></div><svg><use href="#icon"></use><use href="#missing"></use><image xlink:href="/missing.svg"></image></svg>',
    );
    assert.deepEqual(checkLinks(root).errors, [
      "index.html: missing fragment #missing",
      "index.html: missing target /missing.svg",
    ]);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});
test("link checker validates image submit controls and their alternative text", () => {
  const root = mkdtempSync(join(tmpdir(), "shaar-links-"));
  try {
    writeFileSync(join(root, "index.html"), '<h1>Home</h1><input type="image" src="/submit.png">');
    assert.deepEqual(checkLinks(root).errors, [
      "index.html: missing target /submit.png",
      "index.html: image submit control missing alt",
    ]);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("link checker rejects empty alternative text on image submit controls", () => {
  const root = mkdtempSync(join(tmpdir(), "shaar-links-"));
  try {
    writeFileSync(
      join(root, "index.html"),
      '<h1>Home</h1><input type="image" src="/submit.png" alt="  ">',
    );
    writeFileSync(join(root, "submit.png"), "fixture");
    assert.deepEqual(checkLinks(root).errors, ["index.html: image submit control missing alt"]);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("link checker reports malformed quoted CSS imports", () => {
  const root = mkdtempSync(join(tmpdir(), "shaar-links-"));
  try {
    writeFileSync(join(root, "index.html"), "<h1>Home</h1>");
    writeFileSync(join(root, "styles.css"), '@import "http://[";');
    assert.deepEqual(checkLinks(root).errors, ["styles.css: missing/nonlocal CSS asset http://["]);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("link checker ignores CSS URLs inside comments", () => {
  const root = mkdtempSync(join(tmpdir(), "shaar-links-"));
  try {
    writeFileSync(join(root, "index.html"), "<h1>Home</h1>");
    writeFileSync(
      join(root, "styles.css"),
      `/* url("/removed-image.png") */ body::before { content: "url('/also-not-a-resource.png')"; }`,
    );
    assert.deepEqual(checkLinks(root).errors, []);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});
