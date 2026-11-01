// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import { type SitePage, siteOrigin } from "../content";
import { escapeHtml } from "../html";
import { Footer, Navigation } from "./navigation";

export function Layout(page: SitePage, content: string): string {
  const title = page.path === "/" ? page.title : `${page.title} · Shaar`;
  return `<!doctype html>
<!-- This Source Code Form is subject to the terms of the Mozilla Public
License, v. 2.0. If a copy of the MPL was not distributed with this
file, You can obtain one at https://mozilla.org/MPL/2.0/. -->
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="color-scheme" content="light"><title>${escapeHtml(title)}</title>
<meta name="description" content="${escapeHtml(page.description)}"><link rel="canonical" href="${siteOrigin}${page.path}">
<meta property="og:type" content="website"><meta property="og:title" content="${escapeHtml(title)}"><meta property="og:description" content="${escapeHtml(page.description)}"><meta property="og:url" content="${siteOrigin}${page.path}"><meta property="og:image" content="${siteOrigin}/assets/shaar-icon.png">
<meta name="twitter:card" content="summary"><link rel="icon" href="/assets/shaar-logo.svg" type="image/svg+xml">
<link rel="preload" href="/assets/fonts/clash-display.woff2" as="font" type="font/woff2" crossorigin><link rel="preload" href="/assets/fonts/satoshi.woff2" as="font" type="font/woff2" crossorigin>
<link rel="stylesheet" href="/assets/styles.css"><script src="/assets/client.js"></script>
</head><body id="top">${Navigation(page.path)}<main id="main" tabindex="-1"${page.path !== "/" ? ' class="document-main"' : ""}>${content}</main>${Footer()}</body></html>`;
}

export function DocumentPage(page: SitePage): string {
  return Layout(
    page,
    `<header class="document-heading"><h1>${escapeHtml(page.heading)}</h1><p class="document-intro">${escapeHtml(page.description)}</p></header><div class="prose">${page.body}</div>`,
  );
}
