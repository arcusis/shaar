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
  category: string;
  title: string;
  description: string;
  choices: readonly [string, string, string][];
  shot?: TourShot;
  captureNote?: string;
  note?: string;
}

// Each shot is a shaar.48 capture from thefourcraft/web-screens-020. Widevine and
// Developer Tools have no frame in that set, so those sections do not borrow another screen.
export const tourFeatures: TourFeature[] = [
  {
    id: "spaces",
    category: "01 / Make room",
    title: "A Space for every part of your day",
    description:
      "Keep tabs, pinned pages and folders in a colored Space. Switch without losing your place.",
    shot: {
      file: "spaces.webp",
      width: 2880,
      height: 1920,
      alt: "Shaar in the Hasbara Space on hasbara.co.il, with the sidebar open",
    },
    choices: [
      ["Hasbara", "Hasbara Space · research stays here", "blue"],
      ["Work", "Work Space · Arcusis and GitHub tabs", "green"],
      ["Freight", "Freight Space · its own tabs and color", "amber"],
    ],
  },
  {
    id: "profiles",
    category: "01 / Make room",
    title: "Profiles keep accounts apart",
    description:
      "Cookies, sign-ins, history and extensions belong to a profile. Spaces can share one profile or use separate ones.",
    shot: {
      file: "profiles.webp",
      width: 1800,
      height: 1464,
      alt: "Shaar Settings showing the Work profile, with three Spaces, and a separate Personal profile",
    },
    choices: [
      ["Work", "Work profile · Work and Freight Spaces", "green"],
      ["Personal", "Personal profile · Hasbara Space", "blue"],
    ],
  },
  {
    id: "launcher",
    category: "02 / Move quickly",
    title: `${commandInterfaceName} is one shortcut away`,
    description:
      "Command-T searches open tabs, history, bookmarks and browser actions. Use arrows and Return to jump in.",
    shot: {
      file: "command-t.webp",
      width: 2880,
      height: 1920,
      alt: `${commandInterfaceName} searching for freight across open tabs, history and Spaces on arcusis.com`,
    },
    choices: [
      ["Open tabs", "2 open tabs ready to switch", "green"],
      ["History", "Recent pages ready to revisit", "blue"],
      ["Commands", "Browser actions ready to run", "amber"],
    ],
  },
  {
    id: "extensions",
    category: "02 / Move quickly",
    title: "Bring your extensions",
    description:
      "Install from Chrome Web Store. Shaar asks for consent before adding an extension to a profile.",
    shot: {
      file: "web-store-bitwarden-consent.webp",
      width: 1100,
      height: 1300,
      alt: "Shaar consent sheet for adding Bitwarden Password Manager from the Chrome Web Store to the Work profile",
    },
    choices: [
      ["Web Store", "Chrome Web Store · choose Add to Chrome", "green"],
      ["Review", "Shaar consent sheet · review permissions", "amber"],
      ["Installed", "Extension available in this profile", "blue"],
    ],
  },
  {
    id: "downloads",
    category: "02 / Move quickly",
    title: "Downloads stay in reach",
    description:
      "The Downloads drawer shows progress, then lets you open a file or reveal it in Finder.",
    shot: {
      file: "downloads-light.webp",
      width: 640,
      height: 520,
      alt: "Shaar Downloads drawer with Shaar-0.2.0.dmg downloading",
    },
    choices: [
      ["Downloading", "Shaar.dmg · downloading 64%", "amber"],
      ["Complete", "Shaar.dmg · ready to open", "green"],
      ["In Finder", "Shaar.dmg · shown in Finder", "blue"],
    ],
  },
  {
    id: "private",
    category: "03 / Browse with control",
    title: "A private window has its own session",
    description:
      "Private windows isolate cookies, history and cache from normal browsing. Close them to end that session.",
    shot: {
      file: "private-window-light.webp",
      width: 2200,
      height: 1440,
      alt: "Shaar private window on its start page, with private protections listed",
    },
    choices: [
      ["Normal", "Normal window · profile history on", "green"],
      ["Private", "Private window · separate temporary session", "blue"],
      ["Close", "Private session ended", "amber"],
    ],
  },
  {
    id: "dialogs",
    category: "03 / Browse with control",
    title: "Web dialogs feel at home",
    description: "JavaScript alert, confirm and prompt requests appear as native Shaar sheets.",
    shot: {
      file: "javascript-dialog.webp",
      width: 1040,
      height: 880,
      alt: "Shaar JavaScript alert sheet from arcusis.com saying Welcome to Shaar 0.2.0",
    },
    choices: [
      ["Alert", "This page says: Your changes are saved.", "green"],
      ["Confirm", "This page asks: Continue? · Cancel or OK", "amber"],
      ["Prompt", "This page asks for a name · type a reply", "blue"],
    ],
  },
  {
    id: "basic-auth",
    category: "03 / Browse with control",
    title: "Protected sites can ask you to sign in",
    description: "HTTP Basic authentication opens a dedicated username and password sheet.",
    shot: {
      file: "basic-auth.webp",
      width: 1040,
      height: 880,
      alt: "Shaar sign-in sheet asking for a username and password for arcusis.com, realm Members",
    },
    choices: [
      ["Request", "Protected page requests credentials", "amber"],
      ["Sign in", "Username and password sent to this site", "green"],
      ["Cancel", "Sign-in request dismissed", "blue"],
    ],
  },
  {
    id: "permissions",
    category: "03 / Browse with control",
    title: "Site access stays your choice",
    description:
      "Camera, microphone, location, notifications and MIDI requests each get a clear site permission prompt.",
    shot: {
      file: "permission-camera-mic-location.webp",
      width: 1000,
      height: 1120,
      alt: "Shaar permission prompt asking to allow camera, microphone and location for arcusis.com",
    },
    choices: [
      ["Camera", "Camera access requested by this site", "green"],
      ["Mic", "Microphone access requested by this site", "blue"],
      ["Location", "Location access requested by this site", "amber"],
      ["Alerts", "Notification access requested by this site", "green"],
      ["MIDI", "MIDI device access requested by this site", "blue"],
    ],
  },
  {
    id: "autofill",
    category: "03 / Browse with control",
    title: "Save details. Fill them when needed.",
    description:
      "Shaar can ask to save passwords, payment cards and addresses, then offer saved details on return visits.",
    shot: {
      file: "save-password.webp",
      width: 720,
      height: 392,
      alt: "Shaar save-password prompt for parity-user on a local page, with Not now, Never for this site and Save",
    },
    choices: [
      ["Passwords", "Save password? · Save, Not now or Never", "green"],
      ["Cards", "Save payment card? · Review before saving", "blue"],
      ["Addresses", "Save address? · Review before saving", "amber"],
      ["Autofill", "Saved details ready for a matching form", "green"],
    ],
  },
  {
    id: "protocols",
    category: "03 / Browse with control",
    title: "Web links can open apps with consent",
    description: "A site asking to handle a protocol gets an explicit Shaar confirmation first.",
    shot: {
      file: "protocol-handler.webp",
      width: 1000,
      height: 1080,
      alt: "Shaar consent sheet asking whether to open one mailto link from arcusis.com in Mail",
    },
    choices: [
      ["Request", "This site wants to open a link in another app", "amber"],
      ["Allow", "Open link with the selected app", "green"],
      ["Cancel", "Stay in Shaar", "blue"],
    ],
  },
  {
    id: "devices",
    category: "03 / Browse with control",
    title: "Pick the device you mean",
    description: "Bluetooth and Serial requests show a device picker, with a clear way to cancel.",
    shot: {
      file: "device-chooser-bluetooth.webp",
      width: 1000,
      height: 840,
      alt: "Shaar Bluetooth device chooser for arcusis.com, explaining that macOS has not allowed Bluetooth for Shaar",
    },
    choices: [
      ["Bluetooth", "Choose a nearby Bluetooth device", "blue"],
      ["Serial", "Choose a connected Serial device", "amber"],
      ["Cancel", "No device shared with this site", "green"],
    ],
  },
  {
    id: "video",
    category: "04 / Watch and work",
    title: "The web can play",
    description:
      "Video and audio play in page. Move a video into picture-in-picture and keep it visible while you browse.",
    shot: {
      file: "picture-in-picture.webp",
      width: 712,
      height: 400,
      alt: "Shaar picture-in-picture controls, with pause, ten-second skip and close",
    },
    choices: [
      ["Play", "Video playing in its tab", "green"],
      ["Picture in Picture", "Video floats above other windows", "blue"],
      ["Pause", "Playback paused", "amber"],
    ],
  },
  {
    id: "widevine",
    category: "04 / Watch and work",
    title: "Ready for protected playback",
    description:
      "The engine supports Widevine playback when a licensed CDM is included in the build.",
    captureNote:
      "No Widevine screenshot in the 0.2.0 set. The public build does not include a licensed CDM.",
    choices: [
      ["Open video", "Standard video plays now", "green"],
      ["Protected title", "Widevine CDM required for this title", "amber"],
    ],
    note: "DRM support is coming to the public build, pending CDM licensing.",
  },
  {
    id: "sleeping-tabs",
    category: "05 / Stay in flow",
    title: "Quiet tabs can sleep",
    description:
      "Choose when inactive tabs sleep and which sites stay awake. Active, pinned and playing tabs remain awake.",
    shot: {
      file: "sleeping-tabs-settings.webp",
      width: 1800,
      height: 1464,
      alt: "Shaar Settings, General, showing sleeping tabs, a two-hour discard time and sites that never sleep",
    },
    choices: [
      ["Active", "This tab stays awake", "green"],
      ["Inactive", "Inactive tab is sleeping to save memory", "blue"],
      ["Pinned", "Pinned tab stays awake", "amber"],
    ],
  },
  {
    id: "https-first",
    category: "05 / Stay in flow",
    title: "A safer route comes first",
    description:
      "Shaar tries HTTPS before an insecure public page and warns before continuing over HTTP.",
    shot: {
      file: "https-first-warning.webp",
      width: 2880,
      height: 1920,
      alt: "Shaar warning that trackertest.org does not support a secure connection, with Continue to site and Go back",
    },
    choices: [
      ["HTTPS", "Secure connection available", "green"],
      ["HTTP warning", "Insecure connection · review before continuing", "amber"],
      ["Back", "Return to a safer page", "blue"],
    ],
  },
  {
    id: "devtools",
    category: "05 / Stay in flow",
    title: "Developer Tools are one F12 away",
    description:
      "Inspect Elements, Console, Network and more in Chromium Developer Tools, alongside Shaar panels.",
    captureNote:
      "No Developer Tools screenshot in the 0.2.0 set. The offscreen host does not paint the F12 panel.",
    choices: [
      ["Elements", "Inspect page structure and styles", "green"],
      ["Console", "Read messages and run JavaScript", "blue"],
      ["Network", "See page requests and timing", "amber"],
      ["Shaar", "Viewport, network rules and focus tools", "green"],
    ],
  },
  {
    id: "stop-loading",
    category: "05 / Stay in flow",
    title: "Stop a page when you need to",
    description: "The toolbar can stop a loading page without closing its tab. Reload when ready.",
    shot: {
      file: "stop-loading.webp",
      width: 2880,
      height: 1920,
      alt: "Shaar toolbar showing Stop while arcusis.com is open in the Work Space",
    },
    choices: [
      ["Loading", "Page is loading · Stop available", "amber"],
      ["Stop", "Loading stopped · tab stays open", "blue"],
      ["Reload", "Page loading again", "green"],
    ],
  },
  {
    id: "restore",
    category: "05 / Stay in flow",
    title: "Pick up where you left off",
    description:
      "Quit and relaunch to restore your session. Reopen a closed tab or window when you change your mind.",
    shot: {
      file: "sleeping-tabs-settings.webp",
      width: 1800,
      height: 1464,
      alt: "Shaar Settings, General, with On startup set to Restore windows and tabs",
    },
    choices: [
      ["Relaunch", "Spaces and tabs restored", "green"],
      ["Reopen tab", "Closed tab returned", "blue"],
      ["Reopen window", "Closed window and its tabs returned", "amber"],
    ],
  },
  {
    id: "hebrew",
    category: "06 / Made for both",
    title: "At home in Hebrew",
    description:
      "Shaar supports Hebrew and right-to-left interface layouts, including browser sheets and Developer Tools.",
    shot: {
      file: "hebrew-window.webp",
      width: 2880,
      height: 1920,
      alt: "Shaar in Hebrew, with the sidebar on the right, showing arcusis.com",
    },
    choices: [
      ["English", "Settings · Profiles · Downloads", "green"],
      ["עברית", "הגדרות · פרופילים · הורדות", "blue"],
    ],
  },
];

function screenshot(feature: TourFeature): string {
  const label = feature.category.replace(/^\d+ \/ /, "");
  const shot = feature.shot;
  if (!shot) {
    return `<p class="tour-capture-gap">${escapeHtml(feature.captureNote ?? "")}</p><figcaption class="mono">Shaar 0.2.0 · ${escapeHtml(label)}</figcaption>`;
  }
  return `<img src="/assets/screens/${shot.file}" width="${shot.width}" height="${shot.height}" loading="lazy" decoding="async" alt="${escapeHtml(shot.alt)}"><figcaption class="mono">Shaar 0.2.0 · ${escapeHtml(label)}</figcaption>`;
}

function preview(feature: TourFeature, choiceIndex: number): string {
  const [label, message] = feature.choices[choiceIndex];
  const types: Record<string, string> = {
    spaces: "sidebar",
    profiles: "sidebar",
    launcher: "search",
    extensions: "sheet",
    downloads: "progress",
    private: "sidebar",
    dialogs: "sheet",
    "basic-auth": "sheet",
    permissions: "sheet",
    autofill: "sheet",
    protocols: "sheet",
    devices: "sheet",
    video: "media",
    widevine: "media",
    "sleeping-tabs": "sidebar",
    "https-first": "sheet",
    devtools: "search",
    "stop-loading": "progress",
    restore: "sidebar",
    hebrew: "sidebar",
  };
  const type = types[feature.id];
  const detail = `<strong>${escapeHtml(label)}</strong><span>${escapeHtml(message)}</span>`;
  let scene: string;
  if (type === "sidebar") {
    scene = `<div class="tour-preview-sidebar"><i></i><i></i><i></i></div><div class="tour-preview-content">${detail}<div class="tour-preview-lines"><i></i><i></i></div></div>`;
  } else if (type === "search") {
    scene = `<div class="tour-preview-search"><span aria-hidden="true">⌕</span>${escapeHtml(label)}</div><div class="tour-preview-content">${detail}<div class="tour-preview-lines"><i></i><i></i></div></div>`;
  } else if (type === "progress") {
    scene = `<div class="tour-preview-content">${detail}<div class="tour-preview-track" data-progress="${choiceIndex}"><i></i></div></div>`;
  } else if (type === "media") {
    scene = `<div class="tour-preview-player"><span aria-hidden="true">${choiceIndex === 2 ? "Ⅱ" : "▶"}</span></div><div class="tour-preview-content">${detail}</div>`;
  } else {
    scene = `<div class="tour-preview-sheet"><div class="tour-preview-glyph" aria-hidden="true">${feature.id === "https-first" ? "https" : feature.id === "extensions" ? "+" : "?"}</div><div class="tour-preview-content">${detail}</div><div class="tour-preview-actions"><i></i><i></i></div></div>`;
  }
  return `<div class="tour-preview tour-preview-kind-${type}" data-tour-preview="${choiceIndex}"${choiceIndex === 0 ? "" : " hidden"} aria-hidden="true"><div class="tour-preview-chrome"><span></span><span></span><span></span><small>SHAAR</small></div><div class="tour-preview-scene">${scene}</div></div>`;
}

function feature(feature: TourFeature, index: number): string {
  const first = feature.choices[0];
  return `<article class="tour-feature" id="${feature.id}" aria-labelledby="${feature.id}-title" data-tour-feature data-tone="${first[2]}">
    <div class="tour-copy"><span class="tour-count mono">${String(index + 1).padStart(2, "0")} <span aria-hidden="true">/</span> ${tourFeatures.length}</span><p class="tour-category mono">${escapeHtml(feature.category)}</p>
      <h3 id="${feature.id}-title">${escapeHtml(feature.title)}</h3><p class="tour-description">${escapeHtml(feature.description)}</p>
      <div class="tour-interaction"><p class="tour-try mono">INTERACTIVE PREVIEW <span aria-hidden="true">↘</span></p><div class="tour-options" role="group" aria-label="${escapeHtml(feature.title)} options">${feature.choices.map(([label, message, tone], choiceIndex) => `<button type="button" data-choice="${choiceIndex}" data-message="${escapeHtml(message)}" data-tone="${tone}" aria-pressed="${choiceIndex === 0}">${escapeHtml(label)}</button>`).join("")}</div><div class="tour-preview-stack">${feature.choices.map((_, choiceIndex) => preview(feature, choiceIndex)).join("")}</div><div class="tour-live" role="status" aria-live="polite"><span class="tour-live-dot" aria-hidden="true"></span><span data-tour-output>${escapeHtml(first[1])}</span></div></div>
      ${feature.note ? `<p class="tour-note">${escapeHtml(feature.note)}</p>` : ""}
    </div><figure class="tour-image">${screenshot(feature)}</figure>
  </article>`;
}

export function FeatureTour(): string {
  return `<section class="tour" aria-labelledby="tour-title"><div class="tour-intro"><p class="mono">THE 0.2.0 FIELD GUIDE</p><h2 id="tour-title">Everything you need.\nNothing in your way.</h2><p>Explore the moments that make Shaar feel like your browser. Each control below is a small, interactive preview; screenshots show the real Mac app.</p></div><div class="tour-list">${tourFeatures.map(feature).join("")}</div></section>`;
}
