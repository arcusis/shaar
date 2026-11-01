// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Code-native replica of the Shaar window, used instead of screenshots so the
// product shots stay sharp, themeable and in sync with the copy.

import { escapeHtml } from "../html";

export interface SpaceTab {
  title: string;
  host: string;
  icon: string;
  selected?: boolean;
}

export interface SpaceView {
  name: string;
  color: string;
  profile: string;
  pins: string[];
  tabs: SpaceTab[];
}

export const spaces: SpaceView[] = [
  {
    name: "Work",
    color: "green",
    profile: "Arcusis",
    pins: ["M", "C", "L", "F"],
    tabs: [
      { title: "Roadmap · Q4 planning", host: "linear.app", icon: "L", selected: true },
      { title: "Design review notes", host: "notion.so", icon: "N" },
      { title: "shaar · Pull requests", host: "github.com", icon: "G" },
      { title: "Calendar · Week 44", host: "calendar.google.com", icon: "C" },
    ],
  },
  {
    name: "Personal",
    color: "amber",
    profile: "Personal",
    pins: ["Y", "S", "W"],
    tabs: [
      { title: "Lisbon · Wikipedia", host: "en.wikipedia.org", icon: "W", selected: true },
      { title: "Flights to Lisbon", host: "google.com", icon: "G" },
      { title: "Weekend playlist", host: "music.youtube.com", icon: "Y" },
    ],
  },
  {
    name: "Side project",
    color: "blue",
    profile: "Arcusis",
    pins: ["G", "V"],
    tabs: [
      { title: "Workers · Docs", host: "developers.cloudflare.com", icon: "C", selected: true },
      { title: "localhost:8787", host: "localhost", icon: "L" },
    ],
  },
];

function trafficLights(): string {
  return '<span class="lights" aria-hidden="true"><i></i><i></i><i></i></span>';
}

function tabRow(tab: SpaceTab): string {
  return `<li class="mock-tab${tab.selected ? " is-selected" : ""}"><span class="favicon">${escapeHtml(tab.icon)}</span><span class="mock-tab-title">${escapeHtml(tab.title)}</span></li>`;
}

function sidebar(space: SpaceView, activeIndex: number): string {
  const dots = spaces
    .map(
      (item, index) =>
        `<i class="space-dot${index === activeIndex ? " is-active" : ""}" data-color="${item.color}"></i>`,
    )
    .join("");
  const selected = space.tabs.find((tab) => tab.selected) ?? space.tabs[0];
  return `<aside class="mock-sidebar" aria-hidden="true">
    <div class="mock-sidebar-top">${trafficLights()}<span class="mock-icons" aria-hidden="true"><i></i><i></i><i></i></span></div>
    <div class="mock-url"><span>${escapeHtml(selected.host)}</span></div>
    <ul class="mock-pins">${space.pins.map((pin) => `<li class="favicon">${escapeHtml(pin)}</li>`).join("")}</ul>
    <p class="mock-space-name" data-color="${space.color}"><span></span>${escapeHtml(space.name)}<em>${escapeHtml(space.profile)}</em></p>
    <ul class="mock-tabs">${space.tabs.map(tabRow).join("")}<li class="mock-tab mock-new"><span class="favicon">+</span><span class="mock-tab-title">New tab</span></li></ul>
    <div class="mock-sidebar-bottom"><span class="mock-dots">${dots}</span></div>
  </aside>`;
}

const pageBodies: Record<string, string> = {
  green: `<ul class="mock-issues">${[
    ["In progress", "Spaces keep their scroll position", "SHA-212"],
    ["In progress", "Profile picker in onboarding", "SHA-208"],
    ["Todo", "Mini player volume slider", "SHA-219"],
    ["Todo", "Hebrew and right-to-left layout", "SHA-221"],
    ["Done", "Clean links on Command-Shift-C", "SHA-190"],
  ]
    .map(
      ([state, title, id]) =>
        `<li><i data-state="${state}"></i><span>${title}</span><em>${id}</em></li>`,
    )
    .join("")}</ul>`,
  amber: `<div class="mock-article"><div><span class="mock-line"></span><span class="mock-line"></span><span class="mock-line"></span><span class="mock-line short"></span><span class="mock-line"></span><span class="mock-line short"></span></div><figure class="mock-photo"></figure></div>`,
  blue: `<pre class="mock-code"><code><b>export default</b> {
  <b>async</b> fetch(request, env) {
    <b>return new</b> Response("Hello from the edge");
  },
};</code></pre><span class="mock-line"></span><span class="mock-line short"></span>`,
};

function page(space: SpaceView): string {
  const selected = space.tabs.find((tab) => tab.selected) ?? space.tabs[0];
  return `<div class="mock-page" data-color="${space.color}">
    <p class="mock-page-host">${escapeHtml(selected.host)}</p>
    <p class="mock-page-title">${escapeHtml(selected.title)}</p>
    ${pageBodies[space.color] ?? ""}
  </div>`;
}

function launcher(): string {
  const rows = [
    ["Open tabs", "Roadmap · Q4 planning", "linear.app", true],
    ["Open tabs", "Design review notes", "notion.so", false],
    ["Favorites & pinned", "Calendar · Week 44", "calendar.google.com", false],
    ["Most visited", "Pull requests", "github.com", false],
    ["Actions", "New Space", "⌃⌘N", false],
  ] as const;
  let section = "";
  const items = rows
    .map(([group, title, detail, selected]) => {
      const header = group !== section ? `<li class="launcher-group">${group}</li>` : "";
      section = group;
      return `${header}<li class="launcher-row${selected ? " is-selected" : ""}"><span class="favicon">${title[0]}</span><span>${escapeHtml(title)}</span><em>${escapeHtml(detail)}</em>${selected ? "<kbd>↩</kbd>" : ""}</li>`;
    })
    .join("");
  return `<div class="launcher" aria-hidden="true"><div class="launcher-field"><span class="launcher-caret"></span>ro</div>
    <div class="launcher-chips"><span>Tabs</span><span>History</span><span>Bookmarks</span><span>Actions</span></div>
    <ul>${items}</ul></div>`;
}

function cleanLink(): string {
  return `<div class="clean-link" aria-hidden="true"><p class="clean-before">example.com/article<span>?utm_source=news&amp;utm_medium=email&amp;fbclid=IwAR2…</span></p><p class="clean-after"><span class="clean-check">✓</span>Copied example.com/article</p></div>`;
}

export type BrowserScene = "spaces" | "profiles" | "launcher" | "clean";

export function BrowserWindow(scene: BrowserScene, spaceIndex = 0, label = "Shaar window"): string {
  const space = spaces[spaceIndex];
  const overlay = scene === "launcher" ? launcher() : scene === "clean" ? cleanLink() : "";
  return `<div class="browser" data-scene="${scene}" role="img" aria-label="${escapeHtml(label)}">
    ${sidebar(space, spaceIndex)}
    <div class="mock-main" aria-hidden="true">${page(space)}${overlay}</div>
  </div>`;
}
