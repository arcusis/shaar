// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import { release, repository, type SitePage, screens } from "../content";
import { escapeHtml } from "../html";
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
      <p class="hero-eyebrow mono"><span class="status-dot" aria-hidden="true"></span>A native macOS browser · Public beta</p>
      <h1 id="hero-title">Your gateway<br>to the web.</h1>
      <p class="hero-lede">Spaces for every part of your day.<br>A familiar Chromium engine. A Mac through and through.</p>
      <div class="hero-actions">${DownloadButton()}<a class="ghost-button" href="#spaces">Take a look ↘</a></div>
      <p class="hero-meta mono">macOS 26+ · Free &amp; open source · v${release.version}</p>
    </div>
    <div class="hero-bottom"><p class="mono">Shaar <span lang="he" dir="rtl">שער</span> <span class="hero-gloss">/ gateway</span></p>${SkyControl()}</div>
  </section>
  <div class="hero-window">${Screenshot("hero", "screenshot screenshot-hero")}</div>
  <div class="beta-strip"><p><span class="status-dot" aria-hidden="true"></span>New here? So are we. Shaar is in early public beta.</p><a href="/changelog/">Meet version ${release.version} ↗</a></div>`;
}

interface Step {
  id: string;
  screen: keyof typeof screens;
  label: string;
  title: string;
  body: string;
  detail: string;
}

const steps: Step[] = [
  {
    id: "step-spaces",
    screen: "spaces",
    label: "Spaces",
    title: "A place for every context.",
    body: "Work, personal, the next big idea. Give each Space its own tabs, pinned pages, folders and color. Switch contexts without losing your place.",
    detail: "⌃⌥ [ ]  switches Spaces",
  },
  {
    id: "step-profiles",
    screen: "profiles",
    label: "Profiles",
    title: "Accounts in their own profiles.",
    body: "Profiles keep cookies, sign-ins, history and extensions separate. Share a profile between Spaces when you want the same accounts.",
    detail: "Guided sign-in for Google and Microsoft",
  },
  {
    id: "step-launcher",
    screen: "launcher",
    label: "Command-T",
    title: "Less searching. More finding.",
    body: "Open a tab. Find a page. Run an action. Your keyboard-first launcher brings tabs, history, bookmarks and browser commands into one place.",
    detail: "⌘ T to start · ↑↓ to choose · ↩ to go",
  },
  {
    id: "step-extensions",
    screen: "extensions",
    label: "Extensions",
    title: "Bring your essentials along.",
    body: "Install extensions from the Chrome Web Store and manage them per profile. Keep the tools you use close to the browsing they belong to.",
    detail: "A native SwiftUI and AppKit shell, with Chromium underneath",
  },
];

function StepCopy(step: Step, index: number): string {
  return `<article class="step" id="${step.id}" data-step="${index}"><p class="step-number mono">0${index + 1} · ${escapeHtml(step.label)}</p><h3>${escapeHtml(step.title)}</h3><p>${escapeHtml(step.body)}</p><p class="step-keys mono">${escapeHtml(step.detail)}</p></article>`;
}

function Story(): string {
  const rail = steps
    .map((_step, index) => `<li data-step="${index}"><span class="mono">0${index + 1}</span></li>`)
    .join("");
  const shots = steps
    .map(
      (step, index) =>
        `<figure class="story-window" data-step="${index}">${Screenshot(step.screen)}</figure>`,
    )
    .join("");
  return `<section class="story" id="spaces" aria-labelledby="story-title">
    <header class="section-head"><p class="kicker mono">A little organization. A lot of room.</p><h2 id="story-title">The web is wide.<br>Make yourself at home.</h2><p>Tabs in their place. Accounts in their own profiles. Your next page, a keystroke away.</p></header>
    <div class="story-grid" data-active="0"><ol class="step-rail" aria-hidden="true">${rail}</ol><div class="story-steps">${steps.map(StepCopy).join("")}</div><div class="story-stage"><div class="story-sticky">${shots}</div></div></div>
  </section>`;
}

function OpenSource(): string {
  const facts = ["Native macOS shell", "Chromium engine", "MPL-2.0", "Early public beta"];
  return `<section class="open-source" aria-labelledby="open-title">
    <p class="kicker mono">Out in the open</p>
    <div class="open-source-grid"><h2 id="open-title">A browser you<br>can look into.</h2>
      <div><p>Shaar is independent and open source. Read the code, build it yourself, or help shape what comes next.</p>
        <p class="open-links"><a class="text-link" href="${repository}">Explore the source ↗</a><a class="text-link" href="/privacy/">Read the privacy details ↗</a></p></div></div>
    <ul class="open-facts">${facts.map((fact) => `<li class="mono">${fact}</li>`).join("")}</ul>
  </section>`;
}

function Finale(): string {
  return `<section class="finale" aria-labelledby="finale-title"><img src="/assets/shaar-icon.png" width="88" height="88" alt="" loading="lazy">
    <p class="kicker mono">Your next Space is waiting</p><h2 id="finale-title">Come on in.</h2>${DownloadButton()}
    <p class="finale-meta mono">Free · macOS 26+ · Apple silicon · <a href="/changelog/">What's new in ${release.version}</a></p></section>`;
}

export function HomePage(): string {
  const page: SitePage = {
    path: "/",
    title: "Shaar — your gateway to the web",
    description:
      "A native macOS browser built on Chromium. Spaces, separate profiles and a keyboard-first launcher. Free and open source. Early public beta.",
    eyebrow: "",
    heading: "",
    body: "",
  };
  return Layout(page, `${Hero()}${Story()}${OpenSource()}${Finale()}`);
}
