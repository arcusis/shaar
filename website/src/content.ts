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

// Real Shaar screenshots served from /assets/screens/. Files come from website/screens/
// when present (fresh captures), otherwise from the repository's .github/assets/.
export const screens = {
  hero: {
    file: "command-t.png",
    width: 1600,
    height: 1040,
    alt: "Shaar window with the sidebar of pinned sites and tabs and the Command-T launcher open",
  },
  spaces: {
    file: "spaces-overview.png",
    width: 1400,
    height: 958,
    alt: "Shaar Library showing differently colored Spaces with their pinned tabs and folders",
  },
  profiles: {
    file: "settings-profiles.png",
    width: 720,
    height: 560,
    alt: "Shaar Settings showing two profiles, each with its own color, search engine and accounts",
  },
  launcher: {
    file: "command-t.png",
    width: 1600,
    height: 1040,
    alt: "Command-T launcher listing open tabs, favorites and recently closed pages with filter chips",
  },
  extensions: {
    file: "profile-extensions.png",
    width: 440,
    height: 230,
    alt: "Shaar Settings showing Chrome Web Store extensions managed for one profile",
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
