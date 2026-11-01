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

export interface SitePage {
  path: string;
  title: string;
  description: string;
  eyebrow: string;
  heading: string;
  body: string;
}
