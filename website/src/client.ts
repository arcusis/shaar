// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import { initializeSky } from "./sky";

const root = document.documentElement;
root.dataset.enhanced = "true";

function initializeMenu(): void {
  const button = document.querySelector<HTMLButtonElement>(".menu-control");
  const navigation = document.querySelector<HTMLElement>(".mobile-nav");
  if (!button || !navigation) return;
  button.hidden = false;
  const close = () => {
    delete navigation.dataset.open;
    button.setAttribute("aria-expanded", "false");
    button.textContent = "Menu";
  };
  button.addEventListener("click", () => {
    if (navigation.dataset.open) {
      close();
      return;
    }
    navigation.dataset.open = "true";
    button.setAttribute("aria-expanded", "true");
    button.textContent = "Close";
  });
  navigation.addEventListener("click", (event) => {
    if (event.target instanceof Element && event.target.closest("a")) close();
  });
  document.addEventListener("keydown", (event) => {
    if (event.key === "Escape" && navigation.dataset.open) {
      close();
      button.focus();
    }
  });
}

// Home only: the sticky bar slides in once the hero frame (with its own nav) leaves view.
function initializeStickyHeader(): void {
  const header = document.querySelector<HTMLElement>(".site-header[data-home]");
  const hero = document.querySelector(".hero-frame");
  if (!header || !hero) return;
  const setVisible = (visible: boolean) => {
    if (visible) header.dataset.visible = "true";
    else delete header.dataset.visible;
    header.inert = !visible;
  };
  setVisible(false);
  new IntersectionObserver(([entry]) => setVisible(!entry.isIntersecting), {
    rootMargin: "-64px 0px 0px 0px",
  }).observe(hero);
}

// Story: the step nearest the middle of the viewport picks the window shown beside it.
function initializeStory(): void {
  const grid = document.querySelector<HTMLElement>(".story-grid");
  if (!grid) return;
  const observer = new IntersectionObserver(
    (entries) => {
      for (const entry of entries) {
        if (entry.isIntersecting && entry.target instanceof HTMLElement) {
          grid.dataset.active = entry.target.dataset.step ?? "0";
        }
      }
    },
    { rootMargin: "-45% 0px -45% 0px" },
  );
  for (const step of grid.querySelectorAll(".step")) observer.observe(step);
}

document.addEventListener("DOMContentLoaded", () => {
  initializeMenu();
  initializeStickyHeader();
  initializeStory();
  initializeSky();
});
