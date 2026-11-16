// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

export function initializeTour(): void {
  const features = [...document.querySelectorAll<HTMLElement>("[data-tour-feature]")];
  if (!features.length) return;

  const reducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)");
  if (!("IntersectionObserver" in window)) return;
  if (!reducedMotion.matches) document.documentElement.dataset.tourMotion = "true";

  const visible = new Set<HTMLElement>();
  let frame = 0;
  const updateParallax = () => {
    frame = 0;
    const center = window.innerHeight / 2;
    for (const feature of visible) {
      const bounds = feature.getBoundingClientRect();
      const distance = (bounds.top + bounds.height / 2 - center) / window.innerHeight;
      feature.style.setProperty(
        "--tour-parallax",
        `${Math.max(-20, Math.min(20, distance * -18))}px`,
      );
    }
  };
  const observer = new IntersectionObserver(
    (entries) => {
      for (const entry of entries) {
        const feature = entry.target as HTMLElement;
        if (entry.isIntersecting) {
          visible.add(feature);
          feature.dataset.revealed = "true";
        } else visible.delete(feature);
      }
      updateParallax();
    },
    { rootMargin: "80px 0px 80px 0px" },
  );
  if (!reducedMotion.matches) for (const feature of features) observer.observe(feature);
  window.addEventListener(
    "scroll",
    () => {
      if (!frame) frame = requestAnimationFrame(updateParallax);
    },
    { passive: true },
  );
  reducedMotion.addEventListener("change", () => {
    if (reducedMotion.matches) {
      observer.disconnect();
      visible.clear();
      delete document.documentElement.dataset.tourMotion;
      for (const feature of features) feature.style.removeProperty("--tour-parallax");
    } else {
      document.documentElement.dataset.tourMotion = "true";
      for (const feature of features) observer.observe(feature);
    }
  });
}
