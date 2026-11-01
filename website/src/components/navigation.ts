// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import { release, repository } from "../content";
import { escapeHtml } from "../html";

const primaryLinks = [
  ["/#spaces", "Features"],
  ["/changelog/", "Changelog"],
  ["/building/", "Build"],
  [repository, "GitHub"],
] as const;

function navigationLink(href: string, label: string, currentPath: string): string {
  return `<a href="${href}"${href === currentPath ? ' aria-current="page"' : ""}>${escapeHtml(label)}</a>`;
}

function links(currentPath: string): string {
  return primaryLinks.map(([href, label]) => navigationLink(href, label, currentPath)).join("");
}

export function Wordmark(): string {
  return `<a class="wordmark" href="/" aria-label="Shaar home"><img src="/assets/shaar-logo.svg" width="26" height="26" alt="">Shaar</a>`;
}

function downloadButton(): string {
  return `<a class="button button-small" href="/download/">Download</a>`;
}

// Nav that sits inside the home hero frame.
export function HeroNavigation(): string {
  return `<nav class="hero-nav" aria-label="Main navigation">${Wordmark()}<div class="hero-nav-links">${links("/")}</div>${downloadButton()}</nav>`;
}

// Sticky bar. On the home page it slides in once the hero frame scrolls away.
export function Navigation(currentPath: string): string {
  const home = currentPath === "/";
  return `<a class="skip-link" href="#main">Skip to content</a>
    <header class="site-header"${home ? " data-home" : ""}>
      <div class="site-header-inner">${Wordmark()}
        <nav class="desktop-nav" aria-label="${home ? "Sticky navigation" : "Main navigation"}">${links(currentPath)}</nav>
        <div class="nav-actions">${downloadButton()}<button class="menu-control" type="button" aria-expanded="false" aria-controls="mobile-navigation" hidden>Menu</button></div>
      </div>
      <nav class="mobile-nav" id="mobile-navigation" aria-label="Mobile navigation">${links(currentPath)}${navigationLink("/privacy/", "Privacy", currentPath)}</nav>
    </header>`;
}

export function Footer(): string {
  const groups = [
    [
      "Get",
      [
        ["/download/", "Download for Mac"],
        ["/changelog/", "Changelog"],
        ["/building/", "Build from source"],
      ],
    ],
    [
      "Learn",
      [
        ["/privacy/", "Privacy"],
        ["/verification/", "Security"],
        ["/license/", "License & credits"],
        ["/notice/", "Notices"],
      ],
    ],
    [
      "Source",
      [
        [repository, "GitHub"],
        [`${repository}/issues`, "Issues"],
        [`${repository}/blob/production/CONTRIBUTING.md`, "Contribute"],
      ],
    ],
  ] as const;
  return `<footer class="site-footer"><div class="footer-grid">
      <div class="footer-brand">${Wordmark()}<p>A Mac browser with room for everything.</p></div>
      ${groups.map(([title, items]) => `<div class="footer-group"><h2>${title}</h2>${items.map(([href, label]) => `<a href="${href}">${label}</a>`).join("")}</div>`).join("")}
    </div>
    <div class="footer-bottom"><small>© 2026 Arcusis. All rights reserved.</small><span class="mono">Shaar ${release.version} · MPL-2.0</span><a class="mono" href="#top">Back to top ↑</a></div></footer>`;
}
