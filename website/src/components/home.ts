// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import { commandInterfaceName, release, repository, type SitePage } from "../content";
import { ShaarDemo } from "./demo";
import { Landscape, SkyControl } from "./landscape";
import { Layout } from "./layout";
import { HeroNavigation } from "./navigation";
import { FeatureTour } from "./tour";

function DownloadButton(): string {
  return `<a class="split-button" href="/download/"><span class="split-main"><span aria-hidden="true">↓</span> Download for Mac</span><span class="split-meta">Apple silicon</span></a>`;
}

function Hero(): string {
  return `<section class="hero-frame" aria-labelledby="hero-title">${Landscape()}${HeroNavigation()}
    <div class="hero-copy">
      <h1 id="hero-title">Your gateway<br>to the web</h1>
      <p class="hero-lede">A Mac browser that keeps work, personal life and side projects in separate Spaces, each with its own tabs and color. Choose profiles to keep accounts apart. It runs on Chromium, so your sites and extensions work.</p>
      <div class="hero-actions">${DownloadButton()}<a class="ghost-button" href="#spaces">See how it works</a></div>
      <p class="hero-meta mono">macOS 26 or later · Free and open source · v${release.version} beta available</p>
    </div>
    <div class="hero-bottom"><p>Shaar (<span lang="he" dir="rtl">שער</span>) means gateway in Hebrew</p>${SkyControl()}</div>
  </section>
  <div class="hero-window">${ShaarDemo()}</div>
  <div class="beta-strip"><p>Shaar is in public beta. Expect bugs, and report them on GitHub.</p><a href="/changelog/">What's in ${release.version}</a></div>`;
}

function OpenSource(): string {
  return `<section class="open-source" aria-labelledby="open-title">
    <div class="open-source-grid"><h2 id="open-title">Open source under MPL-2.0</h2>
      <div><p>Shaar is independent. The full source is on GitHub, so you can read it, build the app yourself, or file an issue.</p>
        <p class="open-links"><a class="text-link" href="${repository}">Source on GitHub</a><a class="text-link" href="/privacy/">Privacy details</a></p></div></div>
  </section>`;
}

function Finale(): string {
  return `<section class="finale" aria-labelledby="finale-title"><img src="/assets/shaar-icon.png" width="88" height="88" alt="" loading="lazy">
    <h2 id="finale-title">Download Shaar for Mac</h2>${DownloadButton()}
    <p class="finale-meta mono">Current release ${release.version} · macOS 26 or later · Apple silicon · <a href="/changelog/">Release notes</a></p></section>`;
}

export function HomePage(fontFiles?: string[]): string {
  const page: SitePage = {
    path: "/",
    title: "Shaar · Your gateway to the web",
    description: `Shaar is a Mac browser built on Chromium with Spaces, separate profiles and ${commandInterfaceName} search. Free and open source, in public beta.`,
    heading: "",
    body: "",
  };
  return Layout(page, `${Hero()}${FeatureTour()}${OpenSource()}${Finale()}`, fontFiles);
}
