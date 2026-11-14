// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

export const repository = "https://github.com/arcusis/shaar";
export const siteOrigin = "https://shaar.arcusis.com";
export const appcast = "https://arcusis.github.io/shaar/appcast.xml";
export const commandInterfaceName = "Nativ";

// Published release snapshot. Update alongside a published release, not an unreleased version bump.
export const release = {
  version: "0.2.0",
  date: "2026-11-12",
  label: "12 November 2026",
  size: "See GitHub Release",
  url: `${repository}/releases/tag/v0.2.0`,
  dmg: `${repository}/releases/download/v0.2.0/Shaar_0.2.0_aarch64.dmg`,
  zip: `${repository}/releases/download/v0.2.0/Shaar-0.2.0-macos.zip`,
  highlights: [
    "Shaar now runs on Chromium 157, bringing a newer web engine to everyday browsing.",
    "Press F12 or Option-Command-I for Chromium Developer Tools, with Shaar panels for viewports, network rules, 3D stacking, focus and more. The old developer tools window has been replaced; Shaar Inspector remains available.",
    "Inactive tabs can sleep to save memory. Choose when they sleep and which sites stay awake in Settings; pinned, active and playing tabs stay awake.",
    "Move an ordinary tab between windows by dragging it. Its place in the destination window is preserved.",
    "Shaar tries HTTPS first and shows a warning before opening a public page over an insecure connection. You can change this for each profile in Settings.",
    "Website requests for location, notifications, MIDI and protocol handlers now appear in Shaar's permission sheet alongside camera and microphone requests.",
    "Site icons stay with pinned tabs and Favorites after loading and restart.",
    "A pinned tab no longer remains in the sidebar after its page closes during a renderer failure.",
    "Switching Spaces while a page loads keeps its tab in the right profile. Library history loads more reliably, and startup no longer shows a premature download error.",
    "Picture in Picture starts more reliably when you switch away from a playing video.",
    "Extension Settings explains when loading an unpacked extension needs a newer Shaar engine.",
    "Saved-space tabs now stay in their Space when a window closes.",
  ],
};

// Real Shaar screenshots (live Chromium pages, captured offscreen at 2x by the
// website screenshot harness). Files live in website/screens/; the build falls back to
// the repository's .github/assets/ when a file is missing.
export const screens = {
  hero: {
    file: "hero.png",
    width: 2880,
    height: 1920,
    alt: "Shaar in the Work Space on arcusis.com, with its tabs in the sidebar",
  },
  spaces: {
    file: "spaces.webp",
    width: 2880,
    height: 1920,
    alt: "Shaar in the Hasbara Space, in its own color, on hasbara.co.il",
  },
  profiles: {
    file: "profiles.webp",
    width: 1800,
    height: 1464,
    alt: "Shaar Settings showing the Work profile used by the Work, Hasbara and Freight Spaces, and a separate Personal profile",
  },
  launcher: {
    file: "command-t.webp",
    width: 2880,
    height: 1920,
    alt: `${commandInterfaceName} searching for freight across history, open tabs and Spaces`,
  },
  siteControls: {
    file: "site-controls.webp",
    width: 2880,
    height: 1920,
    alt: "Site control center on arcusis.com with permissions, the secure connection and reload actions",
  },
  extensions: {
    file: "extensions.webp",
    width: 2880,
    height: 1920,
    alt: "Shaar on arcusis.com with Dark Reader and Bitwarden from the Chrome Web Store in the toolbar",
  },
} as const;

export interface SitePage {
  path: string;
  title: string;
  description: string;
  heading: string;
  body: string;
}
