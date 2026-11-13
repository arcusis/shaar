// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import assert from "node:assert/strict";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { existsSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { fetchFontAsset, prepareFonts } from "./fonts";

test("font requests abort after their configured timeout", async () => {
  const originalFetch = globalThis.fetch;
  globalThis.fetch = (_input, init) =>
    new Promise((_resolve, reject) => {
      const signal = init?.signal;
      if (!signal) {
        reject(new Error("Missing request timeout signal"));
        return;
      }
      signal.addEventListener("abort", () => reject(signal.reason), { once: true });
    });
  try {
    await assert.rejects(fetchFontAsset("https://fonts.test/font.woff2", 5), {
      name: "TimeoutError",
    });
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test("CSS and font downloads all use timeout signals", async () => {
  const root = mkdtempSync(join(tmpdir(), "shaar-fonts-"));
  const originalFetch = globalThis.fetch;
  const font = readFileSync(
    new URL(
      "../node_modules/@fontsource-variable/geist-mono/files/geist-mono-latin-wght-normal.woff2",
      import.meta.url,
    ),
  );
  const signals: (AbortSignal | null | undefined)[] = [];
  globalThis.fetch = async (input, init) => {
    signals.push(init?.signal);
    if (String(input).includes("api.fontshare.com")) {
      const family = String(input).includes("clash-display") ? "Clash Display" : "Satoshi";
      const file = String(input).includes("clash-display") ? "clash-display" : "satoshi";
      return new Response(
        `@font-face{font-family:'${family}';src:url('https://fonts.test/${file}.woff2');font-weight:300 900;font-style:normal;}`,
      );
    }
    return new Response(new Uint8Array(font));
  };
  try {
    assert.equal((await prepareFonts(join(root, "cache"), join(root, "output"))).length, 2);
    assert.equal(signals.length, 4);
    assert.ok(signals.every((signal) => signal instanceof AbortSignal));
  } finally {
    globalThis.fetch = originalFetch;
    rmSync(root, { recursive: true, force: true });
  }
});

function fontshareFetch(body: string | ArrayBuffer): typeof fetch {
  return async (input) => {
    const url = String(input);
    if (!url.includes("api.fontshare.com")) return new Response(body);
    const family = url.includes("clash-display") ? "Clash Display" : "Satoshi";
    const file = url.includes("clash-display") ? "clash-display" : "satoshi";
    return new Response(
      `@font-face{font-family:'${family}';src:url('https://fonts.test/${file}.woff2');font-weight:300 900;font-style:normal;}`,
    );
  };
}

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

test("empty cached font manifest is removed so the next build can retry", async () => {
  const root = mkdtempSync(join(tmpdir(), "shaar-fonts-"));
  const cache = join(root, "cache");
  mkdirSync(cache);
  writeFileSync(join(cache, "fonts.json"), "[]");
  try {
    assert.deepEqual(await prepareFonts(cache, join(root, "output")), []);
    assert.equal(existsSync(join(cache, "fonts.json")), false);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("unremovable cached manifest still falls back to system fonts", async () => {
  const root = mkdtempSync(join(tmpdir(), "shaar-fonts-"));
  const cache = join(root, "cache");
  mkdirSync(cache);
  mkdirSync(join(cache, "fonts.json"));
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

test("a successful non-WOFF2 response falls back without caching it", async () => {
  const root = mkdtempSync(join(tmpdir(), "shaar-fonts-"));
  const cache = join(root, "cache");
  const output = join(root, "output");
  const originalFetch = globalThis.fetch;
  globalThis.fetch = fontshareFetch("<!doctype html><title>Unavailable</title>");
  try {
    assert.deepEqual(await prepareFonts(cache, output), []);
    assert.equal(existsSync(join(cache, "fonts.json")), false);
    assert.equal(existsSync(join(output, "satoshi.woff2")), false);
    assert.equal(existsSync(join(output, "clash-display.woff2")), false);
  } finally {
    globalThis.fetch = originalFetch;
    rmSync(root, { recursive: true, force: true });
  }
});

test("a WOFF2 signature with an empty header falls back without caching it", async () => {
  const root = mkdtempSync(join(tmpdir(), "shaar-fonts-"));
  const cache = join(root, "cache");
  const output = join(root, "output");
  const originalFetch = globalThis.fetch;
  const malformed = new Uint8Array(48);
  malformed.set(Buffer.from("wOF2"));
  new DataView(malformed.buffer).setUint32(8, malformed.byteLength);
  globalThis.fetch = fontshareFetch(malformed.buffer);
  try {
    assert.deepEqual(await prepareFonts(cache, output), []);
    assert.equal(existsSync(join(cache, "fonts.json")), false);
    assert.equal(existsSync(join(output, "clash-display.woff2")), false);
  } finally {
    globalThis.fetch = originalFetch;
    rmSync(root, { recursive: true, force: true });
  }
});

test("a cached non-WOFF2 file falls back instead of being copied", async () => {
  const root = mkdtempSync(join(tmpdir(), "shaar-fonts-"));
  const cache = join(root, "cache");
  const output = join(root, "output");
  mkdirSync(cache);
  writeFileSync(
    join(cache, "fonts.json"),
    JSON.stringify([{ family: "Satoshi", file: "satoshi.woff2", weight: "300 900" }]),
  );
  writeFileSync(join(cache, "satoshi.woff2"), "<!doctype html>");
  try {
    assert.deepEqual(await prepareFonts(cache, output), []);
    assert.equal(existsSync(join(output, "satoshi.woff2")), false);
    assert.equal(existsSync(join(cache, "fonts.json")), false);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("valid WOFF2 assets are cached and copied", async () => {
  const root = mkdtempSync(join(tmpdir(), "shaar-fonts-"));
  const cache = join(root, "cache");
  const output = join(root, "output");
  const originalFetch = globalThis.fetch;
  const font = readFileSync(
    new URL(
      "../node_modules/@fontsource-variable/geist-mono/files/geist-mono-latin-wght-normal.woff2",
      import.meta.url,
    ),
  );
  globalThis.fetch = fontshareFetch(new Uint8Array(font).buffer);
  try {
    const faces = await prepareFonts(cache, output);
    assert.equal(faces.length, 2);
    assert.deepEqual(readFileSync(join(output, "clash-display.woff2")), font);
    assert.deepEqual(readFileSync(join(output, "satoshi.woff2")), font);
  } finally {
    globalThis.fetch = originalFetch;
    rmSync(root, { recursive: true, force: true });
  }
});

test("unparseable font CSS falls back without caching an empty manifest", async () => {
  const root = mkdtempSync(join(tmpdir(), "shaar-fonts-"));
  const cache = join(root, "cache");
  const originalFetch = globalThis.fetch;
  globalThis.fetch = async () => new Response("<!doctype html><title>Unavailable</title>");
  try {
    assert.deepEqual(await prepareFonts(cache, join(root, "output")), []);
    assert.equal(existsSync(join(cache, "fonts.json")), false);
  } finally {
    globalThis.fetch = originalFetch;
    rmSync(root, { recursive: true, force: true });
  }
});

test("incomplete font CSS falls back without caching a partial manifest", async () => {
  const root = mkdtempSync(join(tmpdir(), "shaar-fonts-"));
  const cache = join(root, "cache");
  const originalFetch = globalThis.fetch;
  const font = readFileSync(
    new URL(
      "../node_modules/@fontsource-variable/geist-mono/files/geist-mono-latin-wght-normal.woff2",
      import.meta.url,
    ),
  );
  globalThis.fetch = async (input) => {
    const url = String(input);
    if (url.includes("api.fontshare.com")) {
      if (url.includes("clash-display"))
        return new Response(
          "@font-face{font-family:'Clash Display';src:url('https://fonts.test/clash.woff2');font-weight:300 900;font-style:normal;}",
        );
      return new Response("<!doctype html><title>Unavailable</title>");
    }
    return new Response(new Uint8Array(font));
  };
  try {
    assert.deepEqual(await prepareFonts(cache, join(root, "output")), []);
    assert.equal(existsSync(join(cache, "fonts.json")), false);
  } finally {
    globalThis.fetch = originalFetch;
    rmSync(root, { recursive: true, force: true });
  }
});
