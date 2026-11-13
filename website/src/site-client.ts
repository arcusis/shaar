// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

document.documentElement.dataset.enhanced = "true";

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

document.addEventListener("DOMContentLoaded", initializeMenu);
