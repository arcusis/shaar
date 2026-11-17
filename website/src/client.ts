// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import { initializeDemo } from "./demo";
import { startScene } from "./scene";
import { initializeSky, type SkyState } from "./sky";
import { initializeTour } from "./tour";

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

document.addEventListener("DOMContentLoaded", () => {
  initializeStickyHeader();
  initializeTour();
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
