// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import { initializeDemo } from "./demo";
import { startScene } from "./scene";
import { initializeSky, type SkyState } from "./sky";
import { nearestStep } from "./story";

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
  const intersecting = new Set<HTMLElement>();
  const observer = new IntersectionObserver(
    (entries) => {
      for (const entry of entries) {
        if (!(entry.target instanceof HTMLElement)) continue;
        if (entry.isIntersecting) intersecting.add(entry.target);
        else intersecting.delete(entry.target);
      }
      const active = nearestStep(intersecting, window.innerHeight / 2);
      if (active) {
        grid.dataset.active = active.dataset.step ?? "0";
        for (const step of grid.querySelectorAll<HTMLElement>(".step")) {
          step.toggleAttribute("data-current", step === active);
        }
      }
    },
    { rootMargin: "-45% 0px -45% 0px" },
  );
  const steps = grid.querySelectorAll<HTMLElement>(".step");
  steps[0]?.setAttribute("data-current", "");
  for (const step of steps) observer.observe(step);
}

document.addEventListener("DOMContentLoaded", () => {
  initializeStickyHeader();
  initializeStory();
  initializeDemo();
  let updateScene: ((state: SkyState) => void) | null = null;
  initializeSky((state) => {
    if (updateScene) {
      updateScene(state);
      return;
    }
    const canvas = document.querySelector<HTMLCanvasElement>(".scene-canvas");
    if (canvas) updateScene = startScene(canvas, state);
  });
});
