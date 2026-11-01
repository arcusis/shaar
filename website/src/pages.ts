// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import { appcast, release, repository, type SitePage } from "./content";
import { escapeHtml } from "./html";

const source = `${repository}/blob/production`;

export function Pages(license: string, notice: string, thirdPartyNotices: string): SitePage[] {
  return [
    {
      path: "/download/",
      title: "Download",
      eyebrow: "A new gateway",
      heading: "Make yourself at home.",
      description: "Shaar for Mac. Free, open source and in early public beta.",
      body: `<div class="download-panel"><img src="/assets/shaar-icon.png" width="96" height="96" alt="Shaar app icon"><div><h2>Shaar ${release.version}</h2><p>Apple silicon · macOS 26 or later</p><a class="button" href="${release.dmg}">Download .dmg <span aria-hidden="true">↓</span></a><p class="download-size">${release.size} · Published ${release.label}</p></div></div>
        <aside class="callout"><h2>Early public beta</h2><p>Usable day to day, with rough edges and missing features. <a href="${repository}/issues">Report problems and ideas</a>.</p></aside>
        <h2>From download to your first Space</h2><ol class="install-steps"><li><strong>Open the disk image.</strong> Download the DMG above on an Apple silicon Mac running macOS 26 or later.</li><li><strong>Drag Shaar to Applications.</strong> The published app is Developer ID signed and notarized by Apple.</li><li><strong>Open Shaar from Applications.</strong> Create a profile and a Space, then start browsing.</li></ol>
        <p>Prefer an archive? <a href="${release.zip}">Download the ZIP</a>. Intel Macs, Windows and Linux are not currently supported.</p>
        <h2>Updates, without another download</h2><p>Release builds use Sparkle for automatic updates. The update feed remains at <a href="${appcast}">${appcast}</a>.</p>
        <div class="related-links"><a href="/changelog/">Read release notes ↗</a><a href="/verification/">Security & verification ↗</a><a href="/building/">Build from source ↗</a><a href="${repository}/releases">All published releases ↗</a></div>`,
    },
    {
      path: "/changelog/",
      title: "Changelog",
      eyebrow: "Growing, in public",
      heading: "Notes from the gateway.",
      description: "Published releases and the changes that come with them.",
      body: `<article class="release-notes"><div class="release-heading"><h2>${release.version} <span class="tag">First public beta</span></h2><time datetime="${release.date}">${release.label}</time></div><p>Shaar's first public beta. Expect rough edges and missing features; feedback belongs in <a href="${repository}/issues">GitHub Issues</a>.</p><h3>Highlights</h3><ul>${release.highlights.map((item) => `<li>${escapeHtml(item)}</li>`).join("")}</ul><p>Requires macOS 26 or later on Apple silicon. Developer ID signed and notarized by Apple.</p><a class="text-link" href="${release.url}">Original release notes & assets ↗</a></article><p class="source-note">This page records published release ${release.version}. <a href="${repository}/releases">GitHub Releases</a> is the canonical archive for newer releases and all assets.</p>`,
    },
    {
      path: "/building/",
      title: "Build from source",
      eyebrow: "For the curious",
      heading: "The door is open.",
      description: "Build the native macOS browser from its public source.",
      body: `<h2>What you'll need</h2><ul><li>Apple silicon Mac with macOS 26 or later.</li><li>Xcode 26 or later and Swift 6.2 or newer.</li><li>Git. For the Chromium engine bundle: curl, jq, ripgrep and Python 3.</li></ul>
        <h2>Get the source</h2><pre><code>git clone https://github.com/arcusis/shaar.git
cd shaar</code></pre>
        <h2>Build the browser with its engine</h2><pre><code>bash scripts/bundle-app.sh --with-engine</code></pre><p>The result is <code>build/Shaar.app</code>, signed ad hoc for local development. The script downloads the pinned Chromium framework, checks its SHA-256 and verifies the extracted payload. This is a development build, not a notarized release.</p>
        <h2>Work on the shell</h2><pre><code>swift build
swift run ArcusisBrowser</code></pre><p>This builds the UI-only preview without downloading Chromium. It does not render webpages. Development builds have no live update feed.</p>
        <h2>Run checks</h2><pre><code>swift test --jobs 2
swift format lint --strict --recursive Package.swift Sources Tests
python3 scripts/check-license-headers.py</code></pre><p>Engine probes and Python tooling have additional setup. See the <a href="${source}/CONTRIBUTING.md">contributor guide</a> and <a href="${source}/Notebook/Build_And_Run.md">full build instructions</a>.</p>
        <h2>Build this website</h2><pre><code>cd website
pnpm install --frozen-lockfile
pnpm check
pnpm wrangler dev</code></pre><p>Local development needs no Cloudflare token. See <a href="${source}/website/README.md">website setup</a> for hosting and release-content maintenance.</p>`,
    },
    {
      path: "/privacy/",
      title: "Privacy",
      eyebrow: "Clear boundaries",
      heading: "Your browsing, explained.",
      description:
        "What this website stores, what the browser keeps locally, and when network services are involved.",
      body: `<h2>This website</h2><p>No third-party trackers, analytics scripts, embedded videos, advertising or external font requests. Images, fonts, styles and scripts are served from this site. No account or cookies are needed.</p><p>Your browser contacts Cloudflare to load the site; Cloudflare processes connection information, including IP addresses, to serve and protect it. See <a href="https://www.cloudflare.com/privacypolicy/">Cloudflare's privacy policy</a>.</p><p>Download and source links take you to GitHub, which handles those requests under <a href="https://docs.github.com/en/site-policy/privacy-policies/github-general-privacy-statement">its own privacy policy</a>.</p>
        <h2>Profiles and local data</h2><p>In the Shaar app, each profile keeps its own cookies, website sign-ins, history and extensions. Spaces that deliberately share a profile also share its website account data. Spaces themselves organize tabs, folders and theme colors.</p><p>The app uses the local <code>Arcusis Browser</code> Application Support folder for existing browser data. The historical folder name and bundle identifier preserve access to that state.</p>
        <h2>Websites and extensions</h2><p>Visiting a website sends requests to that website. Signing in to Google or Microsoft contacts their services and any identity provider your organization uses. Installed extensions can have access granted by their permissions; review those before installing.</p>
        <h2>Permissions</h2><p>Camera and microphone requests use native consent associated with the requesting origin, page and profile. macOS permissions also apply. Unsupported website permission types are denied. See <a href="${source}/Notebook/Media_Consent.md">media consent behavior and verification limits</a>.</p>
        <h2>Application updates</h2><p>Published release builds check the public <a href="${appcast}">Sparkle appcast on GitHub Pages</a> and download updates from GitHub Releases. Development builds do not check for updates.</p>
        <h2>Read the implementation</h2><p>These are specific storage and network boundaries, not a claim that all browser activity remains offline. The <a href="${repository}">source</a> and <a href="${source}/Notebook/Profile_Space_Isolation.md">profile isolation notes</a> are public.</p>`,
    },
    {
      path: "/verification/",
      title: "Security & verification",
      eyebrow: "Trust, with boundaries",
      heading: "Look before you leap.",
      description: "Release checks, security reporting and the limits of our verification.",
      body: `<h2>Report a vulnerability privately</h2><p>Use <a href="${repository}/security/advisories/new">GitHub Security Advisories</a>. Include the affected version or commit, impact and safe reproduction steps. Do not publish unpatched vulnerabilities or include secrets and unrelated personal information.</p><aside class="callout"><h2>Active development</h2><p>Shaar has no fixed support window or promised security update service. The bundled Chromium engine is pinned; a pin does not provide ongoing security updates. Read the <a href="${source}/SECURITY.md">security policy</a>.</p></aside>
        <h2>Check a downloaded app</h2><p>After copying the published release to Applications, these read-only commands inspect its signature and Gatekeeper assessment:</p><pre><code>codesign --verify --deep --strict --verbose=2 /Applications/Shaar.app
codesign -dv --verbose=4 /Applications/Shaar.app
spctl --assess --type execute --verbose=4 /Applications/Shaar.app</code></pre><p>Expected release identity: bundle identifier <code>com.arcusis.browser</code>, Developer ID Application for Arcusis LTD, team <code>F9Z784RA6D</code>. A successful local check applies to that installed artifact; it does not audit every browser feature or upstream engine source.</p>
        <h2>What release tooling verifies</h2><p>Release tooling signs nested components, verifies signatures, notarizes and staples the app and DMG, and signs the Sparkle update archive. The release workflow cross-checks public download metadata, bundle identity, versions, feed URL and Ed25519 signature before publishing the appcast. See <a href="${source}/Notebook/Releasing.md">release verification</a>.</p>
        <h2>What development checks establish</h2><p>Source tests, engine probes and hosted UI captures provide different evidence. A green source check does not prove physical-device behavior, real account sign-in, every extension, permission prompt or website compatibility. A matching engine archive hash proves payload integrity against the pin, not upstream source provenance or signer identity.</p><p>Read <a href="${source}/Notebook/Source_And_Native_Verification.md">source and native verification</a>, <a href="${source}/Notebook/Test_Coverage.md">test coverage</a> and the <a href="${repository}/actions">workflow results</a>.</p>`,
    },
    {
      path: "/license/",
      title: "License & credits",
      eyebrow: "Built in good company",
      heading: "Open source. Properly credited.",
      description:
        "Shaar is licensed under the Mozilla Public License 2.0. Dependencies retain their own licenses.",
      body: `<h2>Shaar</h2><p>Copyright © 2026 Arcusis LTD. Source available at <a href="${repository}">arcusis/shaar</a>.</p><h2>Credits</h2><p>Shaar's browser design is inspired by Arc, made by The Browser Company. Shaar is independent and is not affiliated with, sponsored by or endorsed by The Browser Company.</p><p>Built on <a href="https://www.chromium.org/">Chromium</a> through <a href="https://github.com/mantrakp04/ardia">ArdiaCore</a>, with <a href="https://sparkle-project.org/">Sparkle</a> for updates and <a href="https://publicsuffix.org/">Public Suffix List</a> data. See <a href="${source}/CREDITS.md">full project credits</a> and <a href="/notice/">third-party notices</a>.</p><p>This website uses Inter by Rasmus Andersson and Geist Mono by Vercel, both under the SIL Open Font License 1.1. <a href="/licenses/Inter-OFL.txt">Inter license</a> · <a href="/licenses/Geist-Mono-OFL.txt">Geist Mono license</a>.</p><h2 id="mpl">Mozilla Public License 2.0</h2><p>The repository license follows verbatim. <a href="/licenses/MPL-2.0.txt">Download the license text</a>.</p><pre class="license-text">${escapeHtml(license)}</pre>`,
    },
    {
      path: "/notice/",
      title: "Third-party notices",
      eyebrow: "Acknowledgements",
      heading: "Every part has a story.",
      description: "Repository notices and third-party license references, preserved in public.",
      body: `<h2>NOTICE</h2><pre class="license-text">${escapeHtml(notice)}</pre><h2>Additional third-party notices</h2><pre class="license-text">${escapeHtml(thirdPartyNotices)}</pre><p>Chromium dependency notices are also available in the app at <code>chrome://credits</code>. <a href="${source}/ThirdParty/ArdiaCore/NOTICE">ArdiaCore notice</a> · <a href="${source}/ThirdParty/ArdiaCore/LICENSE">ArdiaCore license</a> · <a href="/license/">Shaar license & credits</a>.</p>`,
    },
  ];
}

export const notFoundPage: SitePage = {
  path: "/404.html",
  title: "Page not found",
  eyebrow: "A wrong turn",
  heading: "This path ends here.",
  description: "The page you're looking for isn't here. Find your way back to Shaar.",
  body: '<p><a class="button" href="/">Back to Shaar <span aria-hidden="true">↗</span></a></p>',
};
