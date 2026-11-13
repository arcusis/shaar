// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import { type SitePage, siteOrigin } from "../content";
import { escapeHtml } from "../html";
import { Footer, Navigation } from "./navigation";

export function Layout(
  page: SitePage,
  content: string,
  fontFiles = ["clash-display.woff2", "satoshi.woff2"],
): string {
  const title = page.path === "/" ? page.title : `${page.title} · Shaar`;
  return `<!doctype html>
<!-- This Source Code Form is subject to the terms of the Mozilla Public
License, v. 2.0. If a copy of the MPL was not distributed with this
file, You can obtain one at https://mozilla.org/MPL/2.0/. -->
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="color-scheme" content="light"><title>${escapeHtml(title)}</title>
<meta name="description" content="${escapeHtml(page.description)}"><link rel="canonical" href="${siteOrigin}${page.path}">
${page.path === "/404.html" ? '<meta name="robots" content="noindex">' : ""}
<meta property="og:type" content="website"><meta property="og:title" content="${escapeHtml(title)}"><meta property="og:description" content="${escapeHtml(page.description)}"><meta property="og:url" content="${siteOrigin}${page.path}"><meta property="og:image" content="${siteOrigin}/assets/shaar-icon.png"><meta property="og:image:alt" content="Shaar app icon">
<meta name="twitter:card" content="summary"><meta name="twitter:title" content="${escapeHtml(title)}"><meta name="twitter:description" content="${escapeHtml(page.description)}"><meta name="twitter:image" content="${siteOrigin}/assets/shaar-icon.png"><meta name="twitter:image:alt" content="Shaar app icon"><link rel="icon" href="/assets/shaar-logo.svg" type="image/svg+xml">
${fontFiles.map((file) => `<link rel="preload" href="/assets/fonts/${escapeHtml(file)}" as="font" type="font/woff2" crossorigin>`).join("")}
<link rel="stylesheet" href="/assets/styles.css"><script src="/assets/client.js" defer></script>${page.path === "/" ? '<script src="/assets/home.js" defer></script>' : ""}
</head><body id="top">${Navigation(page.path)}<main id="main" tabindex="-1"${page.path !== "/" ? ' class="document-main"' : ""}>${content}</main>${Footer()}</body></html>`;
}

export function DocumentPage(page: SitePage, fontFiles?: string[]): string {
  return Layout(
    page,
    `<header class="document-heading"><h1>${escapeHtml(page.heading)}</h1><p class="document-intro">${escapeHtml(page.description)}</p></header><div class="prose">${page.body}</div>`,
    fontFiles,
  );
}
