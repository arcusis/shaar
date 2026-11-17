// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

export const repository = "https://github.com/arcusis/shaar";
export const siteOrigin = "https://shaar.arcusis.com";
export const appcast = "https://arcusis.github.io/shaar/appcast.xml";
export const commandInterfaceName = "Nativ";

// Current public release. Asset names follow scripts/release_feed.py: Shaar_<version>_aarch64.dmg and Shaar-<version>-macos.zip.
export const release = {
  version: "0.2.0",
  url: `${repository}/releases/tag/v0.2.0`,
  dmg: `${repository}/releases/download/v0.2.0/Shaar_0.2.0_aarch64.dmg`,
  zip: `${repository}/releases/download/v0.2.0/Shaar-0.2.0-macos.zip`,
};

// Release-note groups for the current public beta. The download itself is `release`.
export const upcomingRelease = {
  version: "0.2.0",
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
  tour: [
    {
      heading: "Everyday browsing",
      items: [
        "Spaces and separate profiles keep tabs and accounts in place.",
        "Command-T finds tabs, history, bookmarks and browser actions.",
        "Downloads show progress, opening and Finder actions; private windows isolate their session.",
        "Stop Loading, session restore and reopen closed tabs or windows keep work recoverable.",
      ],
    },
    {
      heading: "Web platform",
      items: [
        "JavaScript dialogs and HTTP Basic authentication use Shaar sheets.",
        "Camera, microphone, location, notifications and MIDI requests ask for permission.",
        "Protocol handlers ask before opening apps; Bluetooth and Serial use device pickers.",
      ],
    },
    {
      heading: "Media and performance",
      items: [
        "Video and audio playback include picture-in-picture.",
        "The engine supports Widevine when a licensed CDM is present; DRM support is coming to the public build.",
        "Inactive tabs can sleep, with controls for when they sleep and sites that stay awake.",
      ],
    },
    {
      heading: "Tools and trust",
      items: [
        "Chrome Web Store extensions install through Shaar consent.",
        "HTTPS-first warns before insecure public pages.",
        "F12 opens Chromium Developer Tools with Shaar panels.",
        "Hebrew and right-to-left layouts cover browser flows and sheets.",
      ],
    },
  ],
};

export interface SitePage {
  path: string;
  title: string;
  description: string;
  heading: string;
  body: string;
}
