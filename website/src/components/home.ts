// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import { release, repository, type SitePage, screens } from "../content";
import { escapeHtml } from "../html";
import { ShaarDemo } from "./demo";
import { Landscape, SkyControl } from "./landscape";
import { Layout } from "./layout";
import { HeroNavigation } from "./navigation";

function DownloadButton(): string {
  return `<a class="split-button" href="/download/"><span class="split-main"><span aria-hidden="true">↓</span> Download for Mac</span><span class="split-meta">Apple silicon</span></a>`;
}

function Screenshot(name: keyof typeof screens, className = "screenshot"): string {
  const shot = screens[name];
  const loading = name === "hero" ? "" : ' loading="lazy"';
  return `<img class="${className}" src="/assets/screens/${shot.file}" width="${shot.width}" height="${shot.height}" alt="${escapeHtml(shot.alt)}" decoding="async"${loading}>`;
}

function Hero(): string {
  return `<section class="hero-frame" aria-labelledby="hero-title">${Landscape()}${HeroNavigation()}
    <div class="hero-copy">
      <h1 id="hero-title">Your gateway<br>to the web</h1>
      <p class="hero-lede">A Mac browser that keeps work, personal life and side projects in separate Spaces, each with its own tabs, profile and color. It runs on Chromium, so your sites and extensions work.</p>
      <div class="hero-actions">${DownloadButton()}<a class="ghost-button" href="#spaces">See how it works</a></div>
      <p class="hero-meta mono">macOS 26 or later · Free and open source · v${release.version} beta</p>
    </div>
    <div class="hero-bottom"><p>Shaar (<span lang="he" dir="rtl">שער</span>) means gateway in Hebrew</p>${SkyControl()}</div>
  </section>
  <div class="hero-window">${ShaarDemo()}</div>
  <div class="beta-strip"><p>Shaar is in public beta. Expect bugs, and report them on GitHub.</p><a href="/changelog/">Release notes for ${release.version}</a></div>`;
}

interface Step {
  id: string;
  screen: keyof typeof screens;
  title: string;
  body: string;
  keys?: string[];
}

const steps: Step[] = [
  {
    id: "step-spaces",
    screen: "spaces",
    title: "A Space for each part of your day",
    body: "Each Space has its own tabs, pinned pages, folders and color. Switching Spaces leaves every tab where you left it.",
    keys: ["⌃", "⌥", "[", "]"],
  },
  {
    id: "step-profiles",
    screen: "profiles",
    title: "Accounts stay in their profile",
    body: "A profile keeps its own cookies, sign-ins, history and extensions. Two Spaces can share one profile when you want the same accounts in both, and Shaar guides you through Google and Microsoft sign-in.",
  },
  {
    id: "step-launcher",
    screen: "launcher",
    title: "Command-T finds tabs, pages and commands",
    body: "Type to search open tabs, history, bookmarks and browser actions. Arrow keys pick a result and Return opens it.",
    keys: ["⌘", "T"],
  },
  {
    id: "step-site",
    screen: "siteControls",
    title: "Site permissions in one panel",
    body: "The button next to the address opens camera, microphone, location and notification settings for the site, its certificate, and Reload, Hard Reload or Clear Site Data.",
  },
  {
    id: "step-extensions",
    screen: "extensions",
    title: "Extensions from the Chrome Web Store",
    body: "Install any extension from the Chrome Web Store and turn it on or off for each profile.",
  },
];

function Keys(keys: string[] | undefined): string {
  if (!keys) return "";
  return `<p class="step-keys">${keys.map((key) => `<kbd>${escapeHtml(key)}</kbd>`).join("")}</p>`;
}

function StepCopy(step: Step, index: number): string {
  return `<article class="step" id="${step.id}" data-step="${index}"><h3>${escapeHtml(step.title)}</h3><p>${escapeHtml(step.body)}</p>${Keys(step.keys)}<figure class="step-shot">${Screenshot(step.screen)}</figure></article>`;
}

function Story(): string {
  const shots = steps
    .map(
      (step, index) =>
        `<figure class="story-window" data-step="${index}">${Screenshot(step.screen)}</figure>`,
    )
    .join("");
  return `<section class="story" id="spaces" aria-labelledby="story-title">
    <header class="section-head"><h2 id="story-title">Tabs, accounts and pages, each in its place</h2><p>Spaces hold your tabs, profiles hold your accounts, and Command-T finds any page.</p></header>
    <div class="story-grid" data-active="0"><div class="story-steps">${steps.map(StepCopy).join("")}</div><div class="story-stage" aria-hidden="true"><div class="story-sticky">${shots}</div></div></div>
  </section>`;
}

function OpenSource(): string {
  return `<section class="open-source" aria-labelledby="open-title">
    <div class="open-source-grid"><h2 id="open-title">Open source under MPL-2.0</h2>
      <div><p>Shaar is independent. The full source is on GitHub, so you can read it, build the app yourself, or file an issue.</p>
        <p class="open-links"><a class="text-link" href="${repository}">Source on GitHub</a><a class="text-link" href="/privacy/">Privacy details</a></p></div></div>
  </section>`;
}

function Finale(): string {
  return `<section class="finale" aria-labelledby="finale-title"><img src="/assets/shaar-icon.png" width="88" height="88" alt="" loading="lazy">
    <h2 id="finale-title">Download Shaar for Mac</h2>${DownloadButton()}
    <p class="finale-meta mono">Free · macOS 26 or later · Apple silicon · <a href="/changelog/">What's new in ${release.version}</a></p></section>`;
}

export function HomePage(): string {
  const page: SitePage = {
    path: "/",
    title: "Shaar · Your gateway to the web",
    description:
      "Shaar is a Mac browser built on Chromium with Spaces, separate profiles and a Command-T launcher. Free and open source, in public beta.",
    heading: "",
    body: "",
  };
  return Layout(page, `${Hero()}${Story()}${OpenSource()}${Finale()}`);
}
