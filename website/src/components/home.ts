// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import { release, repository, type SitePage } from "../content";
import { escapeHtml } from "../html";
import { Landscape } from "./landscape";
import { Layout } from "./layout";

function Hero(): string {
  return `<section class="hero" aria-labelledby="hero-title">${Landscape()}
    <div class="hero-copy"><p class="eyebrow"><span class="status-dot" aria-hidden="true"></span>A native macOS browser · Public beta</p>
      <h1 id="hero-title">Make room<br><em>for your web.</em></h1>
      <p class="hero-description">Spaces for every part of your day.<br>A familiar Chromium engine. A Mac through and through.</p>
      <div class="hero-actions"><a class="button" href="/download/">Download for Mac <span aria-hidden="true">↓</span></a><a class="text-link" href="#features">Take a look <span aria-hidden="true">↘</span></a></div>
      <p class="hero-meta">macOS 26+ · Apple silicon · Free & open source</p>
    </div>
    <div class="hero-bottom"><span>Shaar <span lang="he" dir="rtl">שער</span> <span class="hero-translation">/ gateway</span></span><button class="motion-control" type="button" hidden>Pause landscape <span aria-hidden="true">Ⅱ</span></button></div>
  </section>`;
}

interface StoryContent {
  number: string;
  id: string;
  label: string;
  title: string;
  description: string;
  detail: string;
  image: string;
  alt: string;
  width: number;
  height: number;
  reverse?: boolean;
}

function FeatureStory(story: StoryContent): string {
  return `<section class="feature-story${story.reverse ? " story-reverse" : ""}" aria-labelledby="${story.id}">
    <div class="story-copy"><p class="eyebrow"><span>${story.number}</span> ${story.label}</p><h2 id="${story.id}">${story.title}</h2><p>${story.description}</p><p class="story-detail">${story.detail}</p></div>
    <figure class="story-figure"><div class="image-mat"><img src="/assets/${story.image}.png" alt="${escapeHtml(story.alt)}" width="${story.width}" height="${story.height}" loading="lazy" decoding="async"></div><figcaption>${story.label} <span aria-hidden="true">↗</span></figcaption></figure>
  </section>`;
}

function Features(): string {
  const stories: StoryContent[] = [
    {
      number: "01",
      id: "spaces",
      label: "Spaces & profiles",
      title: "A place for<br><em>every context.</em>",
      description:
        "Work, personal, the next big idea. Give each Space its own tabs, pinned pages, folders and color. Switch contexts without losing your place.",
      detail:
        "Profiles keep cookies, sign-ins, history and extensions separate. Share a profile between Spaces when you want the same accounts.",
      image: "spaces-overview",
      alt: "Shaar Library showing differently colored Spaces, profile labels, pinned tabs and folders",
      width: 1400,
      height: 958,
    },
    {
      number: "02",
      id: "launcher",
      label: "Command-T",
      title: "Less searching.<br><em>More finding.</em>",
      description:
        "Open a tab. Find a page. Run an action. Your keyboard-first launcher brings tabs, history, bookmarks and browser commands into one place.",
      detail: "Press <kbd>⌘</kbd> <kbd>T</kbd> to start. Arrow keys to choose. Return to go.",
      image: "command-t",
      alt: "Command-T launcher with tabs, history, bookmarks and action filters, plus keyboard navigation hints",
      width: 1600,
      height: 1040,
      reverse: true,
    },
    {
      number: "03",
      id: "extensions",
      label: "Your extensions",
      title: "Bring your<br><em>essentials along.</em>",
      description:
        "Install extensions from the Chrome Web Store and manage them per profile. Keep the tools you use close to the browsing they belong to.",
      detail:
        "A native SwiftUI and AppKit shell, with Chromium underneath. Familiar websites and extensions, in a browser made for the Mac.",
      image: "profile-extensions",
      alt: "Shaar Settings showing Chrome Web Store extensions managed separately for each profile",
      width: 440,
      height: 230,
    },
  ];
  return `<div class="section-frame" id="features"><div class="section-intro"><p class="eyebrow">A little organization. A lot of room.</p><h2>The web is wide.<br><em>Make yourself at home.</em></h2><p>Tabs in their place. Accounts in their own profiles.<br>Your next page, a keystroke away.</p></div>${stories.map(FeatureStory).join("")}</div>`;
}

function OpenSource(): string {
  return `<section class="open-source section-frame" aria-labelledby="open-title"><p class="eyebrow">Out in the open</p><div class="open-source-copy"><h2 id="open-title">A browser you<br><em>can look into.</em></h2><div><p>Shaar is independent and open source. Read the code, build it yourself, or help shape what comes next.</p><a class="text-link" href="${repository}">Explore the source <span aria-hidden="true">↗</span></a><a class="text-link" href="/privacy/">Read the privacy details <span aria-hidden="true">↗</span></a></div></div><div class="open-facts"><span>Native macOS shell</span><span>Chromium engine</span><span>MPL-2.0</span><span>Early public beta</span></div></section>`;
}

function DownloadInvitation(): string {
  return `<section class="download-invitation" aria-labelledby="download-title"><img src="/assets/shaar-logo.svg" alt="" width="72" height="72" loading="lazy"><p class="eyebrow">Your next Space is waiting</p><h2 id="download-title">Come on in.</h2><a class="button" href="/download/">Get Shaar for Mac <span aria-hidden="true">↓</span></a><p>Free · macOS 26+ · Apple silicon</p><a class="text-link" href="/changelog/">What's new in ${release.version} <span aria-hidden="true">↗</span></a></section>`;
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
  return Layout(
    page,
    `${Hero()}<div class="beta-strip"><p><span class="status-dot" aria-hidden="true"></span>New here? So are we. Shaar is in early public beta.</p><a href="/changelog/">Meet version ${release.version} <span aria-hidden="true">↗</span></a></div>${Features()}${OpenSource()}${DownloadInvitation()}`,
  );
}
