// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import { repository } from "../content";
import { escapeHtml } from "../html";

function navigationLink(href: string, label: string, currentPath: string): string {
  return `<a href="${href}"${href === currentPath ? ' aria-current="page"' : ""}>${escapeHtml(label)}</a>`;
}

export function Navigation(currentPath: string): string {
  const links =
    navigationLink("/#features", "Explore", currentPath) +
    navigationLink("/changelog/", "Changelog", currentPath) +
    navigationLink("/building/", "Build", currentPath);
  return `<a class="skip-link" href="#main">Skip to content</a>
    <header class="site-header">
      <a class="wordmark" href="/" aria-label="Shaar home"><img src="/assets/shaar-logo.svg" width="36" height="36" alt="">Shaar<span class="wordmark-hebrew" lang="he" dir="rtl">שער</span></a>
      <nav class="desktop-nav" aria-label="Main navigation">${links}</nav>
      <div class="nav-actions">
        <button class="theme-control" type="button" aria-label="Switch color theme" hidden><span aria-hidden="true">◐</span></button>
        <a class="button button-small" href="/download/"${currentPath === "/download/" ? ' aria-current="page"' : ""}>Get Shaar <span aria-hidden="true">↗</span></a>
        <button class="menu-control" type="button" aria-expanded="false" aria-controls="mobile-navigation" hidden>Menu</button>
      </div>
      <nav class="mobile-nav" id="mobile-navigation" aria-label="Mobile navigation">${links}${navigationLink("/privacy/", "Privacy", currentPath)}</nav>
    </header>`;
}

export function Footer(): string {
  const groups = [
    [
      "Get started",
      [
        ["/download/", "Download"],
        ["/changelog/", "Changelog"],
        ["/building/", "Build from source"],
      ],
    ],
    [
      "Know your browser",
      [
        ["/privacy/", "Privacy"],
        ["/verification/", "Security & verification"],
        ["/license/", "License & credits"],
        ["/notice/", "Third-party notices"],
      ],
    ],
    [
      "In the open",
      [
        [repository, "Source code ↗"],
        [`${repository}/issues`, "Issues & ideas ↗"],
        [`${repository}/blob/production/CONTRIBUTING.md`, "Contribute ↗"],
      ],
    ],
  ] as const;
  return `<footer class="site-footer"><div class="footer-top"><a class="wordmark" href="/"><img src="/assets/shaar-logo.svg" width="40" height="40" alt="">Shaar</a><p>Your gateway to the web.</p></div>
    <div class="footer-links">${groups.map(([title, links]) => `<div><h2>${title}</h2>${links.map(([href, label]) => `<a href="${href}">${label}</a>`).join("")}</div>`).join("")}</div>
    <div class="footer-bottom"><small>© 2026 Arcusis. All rights reserved.</small><span>Made for macOS. Open source, MPL-2.0.</span><a href="#top">Back to top ↑</a></div></footer>`;
}
