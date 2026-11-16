// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

export function initializeTour(): void {
  const features = [...document.querySelectorAll<HTMLElement>("[data-tour-feature]")];
  if (!features.length) return;

  for (const feature of features) {
    const output = feature.querySelector<HTMLElement>("[data-tour-output]");
    const buttons = [...feature.querySelectorAll<HTMLButtonElement>("[data-choice]")];
    const previews = [...feature.querySelectorAll<HTMLElement>("[data-tour-preview]")];
    for (const button of buttons) {
      button.addEventListener("click", () => {
        for (const option of buttons)
          option.setAttribute("aria-pressed", String(option === button));
        feature.dataset.tone = button.dataset.tone ?? "green";
        if (output) output.textContent = button.dataset.message ?? "";
        for (const preview of previews)
          preview.hidden = preview.dataset.tourPreview !== button.dataset.choice;
        if (feature.id === "hebrew") {
          const preview = feature.querySelector<HTMLElement>(".tour-live");
          if (preview) {
            preview.dir = button.textContent?.trim() === "עברית" ? "rtl" : "ltr";
            preview.lang = preview.dir === "rtl" ? "he" : "en";
          }
        }
      });
      button.addEventListener("keydown", (event) => {
        const current = buttons.indexOf(button);
        const next =
          event.key === "ArrowRight" || event.key === "ArrowDown"
            ? (current + 1) % buttons.length
            : event.key === "ArrowLeft" || event.key === "ArrowUp"
              ? (current + buttons.length - 1) % buttons.length
              : event.key === "Home"
                ? 0
                : event.key === "End"
                  ? buttons.length - 1
                  : -1;
        if (next < 0) return;
        event.preventDefault();
        buttons[next].focus();
        buttons[next].click();
      });
    }
  }

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
