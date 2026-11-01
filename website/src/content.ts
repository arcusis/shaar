// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

export const repository = "https://github.com/arcusis/shaar";
export const siteOrigin = "https://shaar.arcusis.com";
export const appcast = "https://arcusis.github.io/shaar/appcast.xml";

// Published release snapshot. Update alongside a published release, not an unreleased version bump.
export const release = {
  version: "0.1.0",
  date: "2026-10-31",
  label: "31 October 2026",
  size: "180 MB",
  url: `${repository}/releases/tag/v0.1.0`,
  dmg: `${repository}/releases/download/v0.1.0/Shaar_0.1.0_aarch64.dmg`,
  zip: `${repository}/releases/download/v0.1.0/Shaar-0.1.0-macos.zip`,
  highlights: [
    "Spaces and profiles with separate sign-ins, profile colors and step-by-step onboarding for Google and Microsoft accounts, including work accounts.",
    "Command-T launcher with suggestions, filters and actions.",
    "Clean links: Command-Shift-C copies the current link without tracking parameters.",
    "Chrome Web Store extensions, managed per profile.",
    "Search engines per profile, private windows and a Library for downloads.",
    "Automatic updates through Sparkle.",
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
    alt: "Shaar showing the Work Space sidebar with pinned sites and tabs, browsing the Shaar repository on GitHub",
  },
  spaces: {
    file: "spaces.png",
    width: 2880,
    height: 1920,
    alt: "Shaar in the Personal Space, in its own color, reading the Wikipedia article on Lisbon",
  },
  profiles: {
    file: "profiles.png",
    width: 1800,
    height: 1464,
    alt: "Shaar Settings showing the Work and Personal profiles, each with its own color, search engine and Spaces",
  },
  launcher: {
    file: "command-t.png",
    width: 2880,
    height: 1920,
    alt: "Command-T launcher searching for swift across open tabs, recently closed tabs and history",
  },
  siteControls: {
    file: "site-controls.png",
    width: 2880,
    height: 1920,
    alt: "Site control center on github.com with permissions, the secure connection and reload actions",
  },
  extensions: {
    file: "extensions.png",
    width: 2880,
    height: 1920,
    alt: "Shaar with Dark Reader and Bitwarden from the Chrome Web Store in the toolbar, GitHub shown in dark mode",
  },
} as const;

export interface SitePage {
  path: string;
  title: string;
  description: string;
  eyebrow: string;
  heading: string;
  body: string;
}
