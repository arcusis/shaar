// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// A small working copy of the Shaar window for the home page: switch tabs and Spaces, open
// Command-T from the address, and open the site controls. Page content is a real capture of
// each site. Behavior lives in src/demo.ts; without JavaScript the first Space shows statically.

import { escapeHtml } from "../html";

export interface DemoTab {
  title: string;
  host: string;
  page: string;
}

export interface DemoSpace {
  name: string;
  color: "green" | "blue" | "amber";
  profile: string;
  tabs: DemoTab[];
}

export const demoSpaces: DemoSpace[] = [
  {
    name: "Work",
    color: "green",
    profile: "Work",
    tabs: [
      { title: "Arcusis", host: "arcusis.com", page: "arcusis" },
      { title: "arcusis/shaar", host: "github.com", page: "github" },
    ],
  },
  {
    name: "Hasbara",
    color: "blue",
    profile: "Personal",
    tabs: [{ title: "Hasbara, understand Israel", host: "hasbara.co.il", page: "hasbara" }],
  },
  {
    name: "Freight",
    color: "amber",
    profile: "Work",
    tabs: [{ title: "FreightFTE", host: "freightfte.com", page: "freightfte" }],
  },
];

const icon = {
  sidebar:
    '<svg viewBox="0 0 16 16"><rect x="1.5" y="2.5" width="13" height="11" rx="2.5"/><path d="M6 2.5v11"/></svg>',
  back: '<svg viewBox="0 0 16 16"><path d="M10 3 5 8l5 5"/></svg>',
  forward: '<svg viewBox="0 0 16 16"><path d="m6 3 5 5-5 5"/></svg>',
  reload: '<svg viewBox="0 0 16 16"><path d="M13 8a5 5 0 1 1-1.6-3.7M13 2.5V5h-2.5"/></svg>',
  lock: '<svg viewBox="0 0 16 16"><rect x="3.5" y="7" width="9" height="6.5" rx="1.5"/><path d="M5.5 7V5a2.5 2.5 0 0 1 5 0v2"/></svg>',
  sliders:
    '<svg viewBox="0 0 16 16"><path d="M3 4.5h10M3 11.5h10"/><circle cx="6" cy="4.5" r="1.6"/><circle cx="10.5" cy="11.5" r="1.6"/></svg>',
  plus: '<svg viewBox="0 0 16 16"><path d="M8 3v10M3 8h10"/></svg>',
  search:
    '<svg viewBox="0 0 16 16"><circle cx="7" cy="7" r="4.5"/><path d="m10.5 10.5 3 3"/></svg>',
};

function favicon(page: string): string {
  return `<img class="demo-favicon" src="/assets/screens/fav-${page}.png" width="16" height="16" alt="">`;
}

function tabList(space: DemoSpace, spaceIndex: number): string {
  const tabs = space.tabs
    .map(
      (tab, tabIndex) =>
        `<li><button type="button" class="demo-tab" data-space="${spaceIndex}" data-tab="${tabIndex}" data-page="${tab.page}" data-host="${escapeHtml(tab.host)}" aria-pressed="${spaceIndex === 0 && tabIndex === 0}">${favicon(tab.page)}<span>${escapeHtml(tab.title)}</span></button></li>`,
    )
    .join("");
  return `<div class="demo-space" data-space="${spaceIndex}"${spaceIndex === 0 ? "" : " hidden"}>
    <p class="demo-space-name"><span class="demo-space-dot"></span>${escapeHtml(space.name)}<em>${escapeHtml(space.profile)} profile</em></p>
    <ul class="demo-tabs">${tabs}</ul>
    <button type="button" class="demo-new-tab" data-launcher>${icon.plus}<span>New tab</span></button>
  </div>`;
}

function pages(): string {
  return demoSpaces
    .flatMap((space, spaceIndex) =>
      space.tabs.map(
        (tab, tabIndex) =>
          `<img class="demo-page-image" data-space="${spaceIndex}" data-tab="${tabIndex}" src="/assets/screens/page-${tab.page}.webp" width="1600" height="1086" alt="${escapeHtml(`${tab.title} at ${tab.host}`)}"${spaceIndex === 0 && tabIndex === 0 ? "" : ' hidden loading="lazy"'}>`,
      ),
    )
    .join("");
}

function siteControls(): string {
  const permissions = ["Camera", "Microphone", "Location", "Notifications"];
  return `<div class="demo-popover" role="dialog" aria-label="Site controls" hidden>
    <p class="demo-popover-host" data-host>arcusis.com</p>
    <p class="demo-secure">${icon.lock}Connection is secure</p>
    <ul class="demo-permissions">${permissions.map((name) => `<li><span>${name}</span><button type="button" class="demo-switch" aria-pressed="false" aria-label="${name}"></button></li>`).join("")}</ul>
    <div class="demo-actions"><button type="button" data-reload>Reload</button><button type="button" data-reload>Clear Site Data</button></div>
  </div>`;
}

function launcher(): string {
  return `<div class="demo-launcher" role="dialog" aria-label="Command-T" hidden>
    <label class="demo-launcher-field">${icon.search}<input type="text" placeholder="Search tabs or enter an address" autocomplete="off" spellcheck="false" aria-label="Search tabs or enter an address"></label>
    <ul class="demo-results" role="listbox"></ul>
  </div>`;
}

export function ShaarDemo(): string {
  const dots = demoSpaces
    .map(
      (space, index) =>
        `<button type="button" class="demo-dot" data-space="${index}" data-color="${space.color}" aria-label="Switch to the ${escapeHtml(space.name)} Space" aria-pressed="${index === 0}"></button>`,
    )
    .join("");
  return `<div class="demo" data-demo data-color="green">
    <div class="demo-window">
      <aside class="demo-sidebar">
        <div class="demo-sidebar-top"><span class="demo-lights" aria-hidden="true"><i></i><i></i><i></i></span><span class="demo-icon" aria-hidden="true">${icon.sidebar}</span></div>
        ${demoSpaces.map(tabList).join("")}
        <div class="demo-dots">${dots}</div>
      </aside>
      <div class="demo-main">
        <div class="demo-toolbar">
          <span class="demo-icon" aria-hidden="true">${icon.back}</span><span class="demo-icon" aria-hidden="true">${icon.forward}</span><span class="demo-icon" aria-hidden="true">${icon.reload}</span>
          <button type="button" class="demo-address" data-launcher aria-label="Open Command-T">${icon.lock}<span data-host>arcusis.com</span></button>
          <button type="button" class="demo-icon demo-controls-button" data-controls aria-label="Site controls" aria-expanded="false">${icon.sliders}</button>
        </div>
        <div class="demo-page">${pages()}</div>
        ${launcher()}${siteControls()}
      </div>
    </div>
    <p class="demo-hint">This is a working copy of Shaar. Click a tab, switch Spaces with the dots, or click the address to open Command-T.</p>
  </div>`;
}
