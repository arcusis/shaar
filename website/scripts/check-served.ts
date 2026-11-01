// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import assert from "node:assert/strict";

const origin = process.env.SITE_CHECK_ORIGIN ?? "http://localhost:8787";
const paths = [
  "/",
  "/download/",
  "/changelog/",
  "/building/",
  "/privacy/",
  "/verification/",
  "/license/",
  "/notice/",
];
for (const path of paths) {
  const response = await fetch(`${origin}${path}`);
  assert.equal(response.status, 200, path);
  assert.match(response.headers.get("content-type") ?? "", /text\/html/, path);
  assert.match(response.headers.get("content-security-policy") ?? "", /script-src 'self'/, path);
  assert.equal(response.headers.get("x-content-type-options"), "nosniff", path);
  assert.match(await response.text(), /<h1[ >]/, path);
}
const redirect = await fetch(`${origin}/download`, { redirect: "manual" });
assert.equal(redirect.status, 307);
assert.equal(new URL(redirect.headers.get("location") ?? "", origin).pathname, "/download/");
const missing = await fetch(`${origin}/this-page-does-not-exist/`);
assert.equal(missing.status, 404);
assert.match(await missing.text(), /This path ends here/);
const appcast = await fetch(`${origin}/appcast.xml`);
assert.equal(appcast.status, 404, "The website must not serve a replacement appcast.");
for (const path of [
  "/assets/client.js",
  "/assets/styles.css",
  "/assets/shaar-logo.svg",
  "/assets/manrope.woff2",
  "/assets/newsreader-italic.woff2",
  "/robots.txt",
  "/sitemap.xml",
]) {
  const response = await fetch(`${origin}${path}`);
  assert.equal(response.status, 200, path);
}
console.log(
  "Wrangler HTTP checks passed: 8 pages, headers, assets, directory redirect, 404, and appcast boundary.",
);
