// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

const root = document.documentElement;
const colorPreference = window.matchMedia("(prefers-color-scheme: dark)");
const motionPreference = window.matchMedia("(prefers-reduced-motion: reduce)");
root.dataset.enhanced = "true";

try {
  const saved = localStorage.getItem("shaar-theme");
  if (saved === "light" || saved === "dark") root.dataset.theme = saved;
} catch {
  // Storage may be unavailable in private or restricted browsing contexts.
}

function isDark(): boolean {
  return root.dataset.theme ? root.dataset.theme === "dark" : colorPreference.matches;
}

function initializeTheme(): void {
  const button = document.querySelector<HTMLButtonElement>(".theme-control");
  if (!button) return;
  const updateLabel = () => {
    button.setAttribute("aria-label", `Switch to ${isDark() ? "light" : "dark"} theme`);
    button.title = `${isDark() ? "Dark" : "Light"} theme`;
  };
  button.hidden = false;
  updateLabel();
  colorPreference.addEventListener("change", updateLabel);
  button.addEventListener("click", () => {
    root.dataset.theme = isDark() ? "light" : "dark";
    try {
      localStorage.setItem("shaar-theme", root.dataset.theme);
    } catch {
      /* Theme still works without storage. */
    }
    updateLabel();
  });
}

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

function initializeLandscape(): void {
  const landscape = document.querySelector<HTMLElement>(".landscape");
  const button = document.querySelector<HTMLButtonElement>(".motion-control");
  if (!landscape || !button) return;
  let finished = false;
  const update = () => {
    button.disabled = motionPreference.matches;
    button.textContent = motionPreference.matches
      ? "Reduced motion"
      : finished
        ? "Replay landscape ↻"
        : landscape.dataset.paused
          ? "Resume landscape ▷"
          : "Pause landscape Ⅱ";
  };
  button.hidden = false;
  update();
  motionPreference.addEventListener("change", update);
  landscape.addEventListener("animationend", (event) => {
    if (event.animationName === "sun-journey") {
      finished = true;
      update();
    }
  });
  button.addEventListener("click", () => {
    if (finished) {
      for (const animation of landscape.getAnimations({ subtree: true })) animation.play();
      finished = false;
      delete landscape.dataset.paused;
    } else if (landscape.dataset.paused) {
      delete landscape.dataset.paused;
    } else {
      landscape.dataset.paused = "true";
    }
    update();
  });
}

document.addEventListener("DOMContentLoaded", () => {
  initializeTheme();
  initializeMenu();
  initializeLandscape();
});
