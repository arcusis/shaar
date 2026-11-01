// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import { release, repository, type SitePage } from "../content";
import { escapeHtml } from "../html";
import { type BrowserScene, BrowserWindow } from "./browser";
import { Landscape } from "./landscape";
import { Layout } from "./layout";
import { HeroNavigation } from "./navigation";

function DownloadButton(dark = true): string {
  return `<a class="split-button${dark ? "" : " split-button-light"}" href="/download/"><span class="split-main"><span aria-hidden="true">↓</span> Download for Mac</span><span class="split-meta">Apple silicon</span></a>`;
}

function Hero(): string {
  return `<section class="hero-frame" aria-labelledby="hero-title">${Landscape()}${HeroNavigation()}
    <div class="hero-copy">
      <h1 id="hero-title">Your web,<br>in its place.</h1>
      <p class="hero-lede">Spaces, profiles and a keyboard-first launcher, in a native Mac browser on the Chromium engine your sites expect. Free and open source.</p>
      <div class="hero-actions">${DownloadButton()}<a class="ghost-button" href="${repository}">Read the source</a></div>
      <p class="hero-meta mono">macOS 26+ · v${release.version} public beta · ${release.size}</p>
    </div>
  </section>
  <div class="hero-window">${BrowserWindow("spaces", 0, "Shaar window with a Work Space: pinned sites, tabs and Space dots in the sidebar")}</div>`;
}

interface Step {
  id: string;
  scene: BrowserScene;
  space: number;
  title: string;
  body: string;
  keys?: string;
  label: string;
}

const steps: Step[] = [
  {
    id: "step-spaces",
    scene: "spaces",
    space: 0,
    title: "A Space for every part of your day.",
    body: "Work, personal, the side project. Each Space keeps its own tabs, pins, folders and color, so switching contexts never means losing your place.",
    keys: "⌃⌥ [ ]",
    label: "Sidebar showing the Work Space with its pinned sites and tabs",
  },
  {
    id: "step-profiles",
    scene: "profiles",
    space: 1,
    title: "Profiles keep sign-ins apart.",
    body: "Cookies, history and extensions stay with their profile. Point two Spaces at one profile when you want the same accounts, with guided sign-in for Google and Microsoft.",
    label: "Sidebar showing the Personal Space on its own profile",
  },
  {
    id: "step-launcher",
    scene: "launcher",
    space: 0,
    title: "⌘T knows what's next.",
    body: "One field for open tabs, favorites, history, bookmarks and browser actions. Arrow keys to choose, Return to go. Opening it never creates a stray tab.",
    keys: "⌘ T",
    label: "Command-T launcher listing open tabs, favorites and actions",
  },
  {
    id: "step-clean",
    scene: "clean",
    space: 2,
    title: "Links without the baggage.",
    body: "Copy the current page without utm, fbclid and other tracking parameters. Paste a link people can actually read.",
    keys: "⌘ ⇧ C",
    label: "A copied link with its tracking parameters removed",
  },
];

function StepCopy(step: Step, index: number): string {
  const keys = step.keys ? `<p class="step-keys mono">${escapeHtml(step.keys)}</p>` : "";
  return `<article class="step" id="${step.id}" data-step="${index}"><p class="step-number mono">0${index + 1}</p><h3>${escapeHtml(step.title)}</h3><p>${escapeHtml(step.body)}</p>${keys}</article>`;
}

function StepRail(): string {
  return `<ol class="step-rail" aria-hidden="true">${steps.map((_step, index) => `<li data-step="${index}"><span class="mono">0${index + 1}</span></li>`).join("")}</ol>`;
}

function Story(): string {
  const windows = steps
    .map(
      (step, index) =>
        `<div class="story-window" data-step="${index}">${BrowserWindow(step.scene, step.space, step.label)}</div>`,
    )
    .join("");
  return `<section class="story" id="spaces" aria-labelledby="story-title">
    <header class="section-head"><p class="kicker mono">Spaces · Profiles · ⌘T</p><h2 id="story-title">Everything has a place.</h2><p>The sidebar habits you already have, rebuilt natively for the Mac.</p></header>
    <div class="story-grid" data-active="0">${StepRail()}<div class="story-steps">${steps.map(StepCopy).join("")}</div><div class="story-stage"><div class="story-sticky">${windows}</div></div></div>
  </section>`;
}

interface Tile {
  title: string;
  body: string;
  visual: string;
  wide?: boolean;
}

const tiles: Tile[] = [
  {
    title: "Chromium inside. Mac outside.",
    body: "A SwiftUI and AppKit shell on a pinned Chromium engine. Sites behave the way they do in Chrome; the window feels like it belongs on macOS.",
    wide: true,
    visual: `<div class="layers"><p><span class="mono">Shell</span>SwiftUI · AppKit</p><p><span class="mono">Bridge</span>Objective-C++</p><p><span class="mono">Engine</span>Chromium 155</p></div>`,
  },
  {
    title: "Your extensions come along.",
    body: "Install from the Chrome Web Store and keep each one with the profile it belongs to.",
    visual: `<ul class="ext-list"><li><span class="favicon">u</span>uBlock Origin Lite<i class="toggle is-on"></i></li><li><span class="favicon">1</span>1Password<i class="toggle is-on"></i></li><li><span class="favicon">G</span>Grammarly<i class="toggle"></i></li></ul>`,
  },
  {
    title: "Private when you need it.",
    body: "Private windows for browsing you would rather not keep.",
    visual: `<div class="private-chip"><span class="private-dot"></span>Private window</div>`,
  },
  {
    title: "Downloads, in one place.",
    body: "Every file in one profile-scoped panel, with progress, pause and resume.",
    visual: `<ul class="download-list"><li><span>report-q3.pdf</span><em class="mono">2.4 MB</em></li><li><span>Shaar_0.1.0.dmg</span><i class="progress"><b></b></i></li></ul>`,
  },
  {
    title: "Keeps itself current.",
    body: "Signed, notarized releases arrive through Sparkle. No account, no store.",
    visual: `<div class="update-note"><img src="/assets/shaar-logo.svg" width="28" height="28" alt=""><p><strong>A new Shaar is ready</strong><span>Install and relaunch</span></p></div>`,
  },
  {
    title: "A search engine per profile.",
    body: "Work searches go where work searches go. Pick an engine for each profile.",
    visual: `<ul class="engine-list"><li><span class="mono">Arcusis</span>Google</li><li><span class="mono">Personal</span>DuckDuckGo</li></ul>`,
  },
  {
    title: "Open to read.",
    wide: true,
    body: "Every line is public under MPL-2.0. Build it yourself in a few minutes.",
    visual: `<pre class="code-chip"><code><span>$</span> git clone github.com/arcusis/shaar
<span>$</span> bash scripts/bundle-app.sh --with-engine</code></pre>`,
  },
];

function Bento(): string {
  return `<section class="bento-section" aria-labelledby="bento-title">
    <header class="section-head"><h2 id="bento-title">Built for every day.</h2><p>The parts you notice after a week, not in a demo.</p></header>
    <div class="bento">${tiles.map((tile) => `<article class="tile${tile.wide ? " tile-wide" : ""}"><div class="tile-visual">${tile.visual}</div><h3>${escapeHtml(tile.title)}</h3><p>${escapeHtml(tile.body)}</p></article>`).join("")}</div>
  </section>`;
}

function Finale(): string {
  return `<section class="finale" aria-labelledby="finale-title"><img src="/assets/shaar-icon.png" width="88" height="88" alt="" loading="lazy">
    <h2 id="finale-title">Come on through.</h2><p>Free for Mac. No account.</p>${DownloadButton()}
    <p class="finale-meta mono">Shaar ${release.version} · ${release.label} · <a href="/changelog/">What's new</a></p></section>`;
}

export function HomePage(): string {
  const page: SitePage = {
    path: "/",
    title: "Shaar — a Mac browser with room for everything",
    description:
      "A native macOS browser on Chromium. Spaces, separate profiles and a keyboard-first launcher. Free and open source, in public beta.",
    eyebrow: "",
    heading: "",
    body: "",
  };
  return Layout(page, `${Hero()}${Story()}${Bento()}${Finale()}`);
}
