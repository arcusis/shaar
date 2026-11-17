// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import { commandInterfaceName } from "../content";
import { escapeHtml } from "../html";

interface TourShot {
  file: string;
  width: number;
  height: number;
  alt: string;
}

interface TourFeature {
  id: string;
  title: string;
  description: string;
  shot: TourShot;
}

interface TourCard {
  id: string;
  title: string;
  description: string;
  shot: TourShot;
}

// Bitmap width and height are the 2x capture. The page renders them at half
// that size so the pixels stay sharp. Each file is a distinct shaar.48 frame.
export const tourFeatures: TourFeature[] = [
  {
    id: "spaces",
    title: "A Space for every part of your day",
    description:
      "Keep tabs, pinned pages and folders in a colored Space. Switch without losing your place.",
    shot: {
      file: "spaces.webp",
      width: 2880,
      height: 1920,
      alt: "Shaar in the Hasbara Space on hasbara.co.il, with the sidebar open",
    },
  },
  {
    id: "profiles",
    title: "Profiles keep accounts apart",
    description:
      "Cookies, sign-ins, history and extensions belong to a profile. Spaces can share one profile or use separate ones.",
    shot: {
      file: "profiles.webp",
      width: 1800,
      height: 1464,
      alt: "Shaar Settings showing the Work profile, with three Spaces, and a separate Personal profile",
    },
  },
  {
    id: "launcher",
    title: `${commandInterfaceName} is one shortcut away`,
    description:
      "Command-T searches open tabs, history, bookmarks and browser actions. Use arrows and Return to jump in.",
    shot: {
      file: "command-t.webp",
      width: 2880,
      height: 1920,
      alt: `${commandInterfaceName} searching for freight across open tabs, history and Spaces on arcusis.com`,
    },
  },
  {
    id: "private",
    title: "A private window has its own session",
    description:
      "Private windows isolate cookies, history and cache from normal browsing. Close them to end that session.",
    shot: {
      file: "private-window-light.webp",
      width: 2200,
      height: 1440,
      alt: "Shaar private window on its start page, with private protections listed",
    },
  },
  {
    id: "hebrew",
    title: "At home in Hebrew",
    description:
      "Shaar supports Hebrew and right-to-left layouts, including the sidebar and sheets.",
    shot: {
      file: "hebrew-window.webp",
      width: 2880,
      height: 1920,
      alt: "Shaar in Hebrew, with the sidebar on the right, showing arcusis.com",
    },
  },
  {
    id: "https-first",
    title: "A safer route comes first",
    description:
      "Shaar tries HTTPS before an insecure public page and warns before continuing over HTTP.",
    shot: {
      file: "https-first-warning.webp",
      width: 2880,
      height: 1920,
      alt: "Shaar warning that trackertest.org does not support a secure connection, with Continue to site and Go back",
    },
  },
  {
    id: "sleeping-tabs",
    title: "Quiet tabs can sleep",
    description:
      "Choose when inactive tabs sleep and which sites stay awake. Active, pinned and playing tabs remain awake. On startup, Shaar can restore your windows and tabs.",
    shot: {
      file: "sleeping-tabs-settings.webp",
      width: 1800,
      height: 1464,
      alt: "Shaar Settings, General, with sleeping tabs and On startup set to Restore windows and tabs",
    },
  },
];

export const tourCards: TourCard[] = [
  {
    id: "stop-loading",
    title: "Stop a page when you need to",
    description: "The toolbar can stop a loading page without closing its tab. Reload when ready.",
    shot: {
      file: "stop-loading.webp",
      width: 680,
      height: 115,
      alt: "Shaar toolbar with Back, Forward and Stop while arcusis.com is loading in the Work Space",
    },
  },
  {
    id: "extensions",
    title: "Bring your extensions",
    description: "Chrome Web Store installs ask for consent before they join a profile.",
    shot: {
      file: "web-store-bitwarden-consent.webp",
      width: 872,
      height: 670,
      alt: "Shaar consent sheet for adding Bitwarden Password Manager from the Chrome Web Store to the Work profile",
    },
  },
  {
    id: "downloads",
    title: "Downloads stay in reach",
    description:
      "The Downloads drawer shows progress, then lets you open a file or reveal it in Finder.",
    shot: {
      file: "downloads-light.webp",
      width: 427,
      height: 130,
      alt: "Shaar Downloads row for Shaar-0.2.0.dmg while it is downloading",
    },
  },
  {
    id: "dialogs",
    title: "Web dialogs feel at home",
    description: "JavaScript alert, confirm and prompt requests appear as native Shaar sheets.",
    shot: {
      file: "javascript-dialog.webp",
      width: 808,
      height: 295,
      alt: "Shaar JavaScript alert sheet from arcusis.com saying Welcome to Shaar 0.2.0",
    },
  },
  {
    id: "basic-auth",
    title: "Protected sites can ask you to sign in",
    description: "HTTP Basic authentication opens a username and password sheet.",
    shot: {
      file: "basic-auth.webp",
      width: 812,
      height: 489,
      alt: "Shaar sign-in sheet asking for a username and password for arcusis.com, realm Members",
    },
  },
  {
    id: "permissions",
    title: "Site access stays your choice",
    description: "Camera, microphone and location requests get one clear permission sheet.",
    shot: {
      file: "permission-camera-mic-location.webp",
      width: 832,
      height: 683,
      alt: "Shaar permission prompt asking to allow camera, microphone and location for arcusis.com",
    },
  },
  {
    id: "protocols",
    title: "Web links can open apps with consent",
    description: "A site asking to handle a protocol gets an explicit confirmation first.",
    shot: {
      file: "protocol-handler.webp",
      width: 832,
      height: 620,
      alt: "Shaar consent sheet asking whether to open one mailto link from arcusis.com in Mail",
    },
  },
  {
    id: "devices",
    title: "Pick the device you mean",
    description:
      "A Bluetooth request shows the device sheet, including when macOS has not allowed access yet.",
    shot: {
      file: "device-chooser-bluetooth.webp",
      width: 832,
      height: 436,
      alt: "Shaar Bluetooth device sheet for arcusis.com, explaining that macOS has not allowed Bluetooth for Shaar",
    },
  },
  {
    id: "video",
    title: "Picture in picture",
    description: "Move a video out of the page and keep it visible while you browse.",
    shot: {
      file: "picture-in-picture.webp",
      width: 712,
      height: 400,
      alt: "Shaar picture-in-picture controls, with pause, ten-second skip and close",
    },
  },
];

function shotImage(shot: TourShot): string {
  const width = Math.round(shot.width / 2);
  const height = Math.round(shot.height / 2);
  return `<img src="/assets/screens/${shot.file}" width="${width}" height="${height}" loading="lazy" decoding="async" alt="${escapeHtml(shot.alt)}">`;
}

function feature(item: TourFeature, index: number): string {
  const count = String(index + 1).padStart(2, "0");
  const total = String(tourFeatures.length).padStart(2, "0");
  return `<article class="tour-feature" id="${item.id}" aria-labelledby="${item.id}-title" data-tour-feature>
    <div class="tour-copy"><span class="tour-count mono">${count} <span aria-hidden="true">/</span> ${total}</span>
      <h3 id="${item.id}-title">${escapeHtml(item.title)}</h3><p class="tour-description">${escapeHtml(item.description)}</p>
    </div><figure class="tour-image">${shotImage(item.shot)}<figcaption class="mono">Shaar 0.2.0</figcaption></figure>
  </article>`;
}

function card(item: TourCard): string {
  return `<article class="tour-card" id="${item.id}" aria-labelledby="${item.id}-title">
    <figure><div class="tour-shot">${shotImage(item.shot)}</div><figcaption class="mono">Shaar 0.2.0</figcaption></figure>
    <h3 id="${item.id}-title">${escapeHtml(item.title)}</h3><p>${escapeHtml(item.description)}</p>
  </article>`;
}

export function FeatureTour(): string {
  return `<section class="tour" aria-labelledby="tour-title"><div class="tour-intro"><p class="mono">SHAAR 0.2.0</p><h2 id="tour-title">Everything you need.\nNothing in your way.</h2><p>Seven parts of the Mac app, then the sheets and controls that sit beside them. Every picture is a real Shaar window.</p></div><div class="tour-list">${tourFeatures.map(feature).join("")}</div><div class="tour-more"><h3 id="tour-more-title">Also in this release</h3><div class="tour-grid">${tourCards.map(card).join("")}</div></div></section>`;
}
