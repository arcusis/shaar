// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

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

// Hero sun: drag it anywhere in the sky; the light warms as it sets.
function initializeSun(): void {
  const sun = document.querySelector<HTMLElement>("[data-sun]");
  const landscape = sun?.closest<HTMLElement>(".landscape");
  if (!sun || !landscape) return;
  let offsetX = 0;
  let offsetY = 0;
  const move = (event: PointerEvent) => {
    const bounds = landscape.getBoundingClientRect();
    const size = sun.offsetWidth;
    const x = Math.min(
      Math.max(event.clientX - bounds.left - offsetX, -size / 3),
      bounds.width - size * 0.66,
    );
    const y = Math.min(
      Math.max(event.clientY - bounds.top - offsetY, -size / 3),
      bounds.height * 0.62,
    );
    sun.style.left = `${x}px`;
    sun.style.top = `${y}px`;
    landscape.style.setProperty(
      "--dusk",
      Math.max(0, (y / (bounds.height * 0.62) - 0.25) / 0.75).toFixed(3),
    );
  };
  sun.addEventListener("pointerdown", (event) => {
    const rect = sun.getBoundingClientRect();
    offsetX = event.clientX - rect.left;
    offsetY = event.clientY - rect.top;
    sun.setPointerCapture(event.pointerId);
    sun.classList.add("is-dragging", "was-dragged");
  });
  sun.addEventListener("pointermove", (event) => {
    if (sun.hasPointerCapture(event.pointerId)) move(event);
  });
  const release = (event: PointerEvent) => {
    if (sun.hasPointerCapture(event.pointerId)) sun.releasePointerCapture(event.pointerId);
    sun.classList.remove("is-dragging");
  };
  sun.addEventListener("pointerup", release);
  sun.addEventListener("pointercancel", release);
}

document.addEventListener("DOMContentLoaded", () => {
  initializeMenu();
  initializeStickyHeader();
  initializeStory();
  initializeSun();
});
