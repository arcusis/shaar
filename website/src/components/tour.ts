// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import { existsSync } from "node:fs";
import { commandInterfaceName, screens } from "../content";
import { escapeHtml } from "../html";

interface TourFeature {
  id: string;
  category: string;
  title: string;
  description: string;
  capture: string;
  fallback: keyof typeof screens;
  choices: readonly [string, string, string][];
  note?: string;
}

// Capture names are stable handoff points for web-screens-020. Matching WebP or
// PNG files in website/screens/ replace fallbacks without changing markup.
export const tourFeatures: TourFeature[] = [
  {
    id: "spaces",
    category: "01 / Make room",
    title: "A Space for every part of your day",
    description:
      "Keep tabs, pinned pages and folders in a colored Space. Switch without losing your place.",
    capture: "tour-spaces",
    fallback: "spaces",
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
    capture: "tour-profiles",
    fallback: "profiles",
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
    capture: "tour-launcher",
    fallback: "launcher",
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
    capture: "tour-extensions",
    fallback: "extensions",
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
    capture: "tour-downloads",
    fallback: "siteControls",
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
    capture: "tour-private",
    fallback: "spaces",
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
    capture: "tour-dialogs",
    fallback: "siteControls",
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
    capture: "tour-basic-auth",
    fallback: "siteControls",
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
    capture: "tour-permissions",
    fallback: "siteControls",
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
    capture: "tour-autofill",
    fallback: "profiles",
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
    capture: "tour-protocols",
    fallback: "siteControls",
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
    capture: "tour-devices",
    fallback: "siteControls",
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
    capture: "tour-video",
    fallback: "hero",
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
    capture: "tour-widevine",
    fallback: "hero",
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
    capture: "tour-sleeping-tabs",
    fallback: "spaces",
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
    capture: "tour-https-first",
    fallback: "siteControls",
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
    capture: "tour-devtools",
    fallback: "hero",
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
    capture: "tour-stop-loading",
    fallback: "hero",
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
    capture: "tour-restore",
    fallback: "spaces",
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
    capture: "tour-hebrew",
    fallback: "profiles",
    choices: [
      ["English", "Settings · Profiles · Downloads", "green"],
      ["עברית", "הגדרות · פרופילים · הורדות", "blue"],
    ],
  },
];

function captureFile(feature: TourFeature): string | undefined {
  return ["webp", "png"]
    .map((extension) => `${feature.capture}.${extension}`)
    .find((file) => existsSync(new URL(`../../screens/${file}`, import.meta.url)));
}

function screenshot(feature: TourFeature): string {
  const capture = captureFile(feature);
  const fallback = screens[feature.fallback];
  const file = capture ?? fallback.file;
  const alt = capture
    ? `Shaar 0.2.0 showing ${feature.title.toLowerCase()}`
    : `Existing Shaar screenshot: ${fallback.alt}. Feature-specific capture pending.`;
  return `<img src="/assets/screens/${file}" width="${fallback.width}" height="${fallback.height}" loading="lazy" decoding="async" alt="${escapeHtml(alt)}">`;
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
    </div><figure class="tour-image">${screenshot(feature)}<figcaption class="mono">${captureFile(feature) ? `SHAAR 0.2.0 · ${escapeHtml(feature.category.replace(/^\d+ \/ /, ""))}` : "SHAAR APP · REFERENCE CAPTURE"}</figcaption></figure>
  </article>`;
}

export function FeatureTour(): string {
  return `<section class="tour" aria-labelledby="tour-title"><div class="tour-intro"><p class="mono">THE 0.2.0 FIELD GUIDE</p><h2 id="tour-title">Everything you need.\nNothing in your way.</h2><p>Explore the moments that make Shaar feel like your browser. Each control below is a small, interactive preview; screenshots show the real Mac app.</p></div><div class="tour-list">${tourFeatures.map(feature).join("")}</div></section>`;
}
