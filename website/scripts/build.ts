// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import { copyFile, mkdir, readFile, rm, writeFile } from "node:fs/promises";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { build } from "esbuild";
import { HomePage } from "../src/components/home";
import { DocumentPage } from "../src/components/layout";
import { siteOrigin } from "../src/content";
import { notFoundPage, Pages } from "../src/pages";

const root = fileURLToPath(new URL("../", import.meta.url));
const repositoryRoot = resolve(root, "..");
const output = resolve(root, "dist");
const notice =
  "This Source Code Form is subject to the terms of the Mozilla Public\nLicense, v. 2.0. If a copy of the MPL was not distributed with this\nfile, You can obtain one at https://mozilla.org/MPL/2.0/.";

async function writeAsset(path: string, content: string): Promise<void> {
  const destination = resolve(output, path);
  await mkdir(resolve(destination, ".."), { recursive: true });
  await writeFile(destination, content);
}

await rm(output, { recursive: true, force: true });
await mkdir(resolve(output, "assets"), { recursive: true });
await mkdir(resolve(output, "licenses"), { recursive: true });

const license = await readFile(resolve(repositoryRoot, "LICENSE"), "utf8");
const projectNotice = await readFile(resolve(repositoryRoot, "NOTICE"), "utf8");
const thirdParty = await readFile(resolve(repositoryRoot, "THIRD_PARTY_NOTICES.md"), "utf8");
const pages = Pages(license, projectNotice, thirdParty);

await writeAsset("index.html", HomePage());
for (const page of pages) await writeAsset(`${page.path.slice(1)}index.html`, DocumentPage(page));
await writeAsset("404.html", DocumentPage(notFoundPage));

for (const name of ["command-t", "spaces-overview", "profile-extensions", "shaar-icon"]) {
  await copyFile(
    resolve(repositoryRoot, `.github/assets/${name}.png`),
    resolve(output, `assets/${name}.png`),
  );
}
await writeAsset(
  "assets/shaar-logo.svg",
  `<!-- ${notice} -->\n${await readFile(resolve(repositoryRoot, "Branding/shaar-logo.svg"), "utf8")}`,
);
await copyFile(resolve(root, "src/styles.css"), resolve(output, "assets/styles.css"));

for (const [family, file, name] of [
  ["manrope", "manrope-latin-wght-normal.woff2", "manrope.woff2"],
  ["newsreader", "newsreader-latin-wght-italic.woff2", "newsreader-italic.woff2"],
]) {
  await copyFile(
    resolve(root, `node_modules/@fontsource-variable/${family}/files/${file}`),
    resolve(output, `assets/${name}`),
  );
  const licenseName = family === "manrope" ? "Manrope" : "Newsreader";
  await copyFile(
    resolve(root, `node_modules/@fontsource-variable/${family}/LICENSE`),
    resolve(output, `licenses/${licenseName}-OFL.txt`),
  );
}
await writeAsset("licenses/MPL-2.0.txt", license);

await build({
  entryPoints: [resolve(root, "src/client.ts")],
  outfile: resolve(output, "assets/client.js"),
  bundle: true,
  minify: true,
  format: "iife",
  target: "es2022",
  banner: { js: `/* ${notice} */` },
});

await writeAsset(
  "_headers",
  `/*
  Content-Security-Policy: default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self'; font-src 'self'; connect-src 'none'; object-src 'none'; base-uri 'none'; frame-ancestors 'none'; form-action 'none'
  X-Content-Type-Options: nosniff
  Referrer-Policy: strict-origin-when-cross-origin
  Permissions-Policy: camera=(), microphone=(), geolocation=()
`,
);
await writeAsset("robots.txt", `User-agent: *\nAllow: /\nSitemap: ${siteOrigin}/sitemap.xml\n`);
await writeAsset(
  "sitemap.xml",
  `<?xml version="1.0" encoding="UTF-8"?><urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">${["/", ...pages.map((page) => page.path)].map((path) => `<url><loc>${siteOrigin}${path}</loc></url>`).join("")}</urlset>`,
);
console.log(`Built ${pages.length + 2} pages into website/dist/ (including 404).`);
