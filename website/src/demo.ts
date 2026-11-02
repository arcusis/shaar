// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Behavior for the interactive Shaar window on the home page (markup in components/demo.ts).

interface TabRef {
  space: number;
  tab: number;
  title: string;
  host: string;
  page: string;
}

function escapeText(value: string): string {
  return value.replace(/[&<>"]/g, (character) => `&#${character.charCodeAt(0)};`);
}

export function initializeDemo(): void {
  const demo = document.querySelector<HTMLElement>("[data-demo]");
  if (!demo) return;
  const spaces = [...demo.querySelectorAll<HTMLElement>(".demo-space")];
  const dots = [...demo.querySelectorAll<HTMLButtonElement>(".demo-dot")];
  const tabButtons = [...demo.querySelectorAll<HTMLButtonElement>(".demo-tab")];
  const images = [...demo.querySelectorAll<HTMLImageElement>(".demo-page-image")];
  const hosts = [...demo.querySelectorAll<HTMLElement>("span[data-host], p[data-host]")];
  const page = demo.querySelector<HTMLElement>(".demo-page");
  const launcher = demo.querySelector<HTMLElement>(".demo-launcher");
  const input = launcher?.querySelector<HTMLInputElement>("input");
  const results = launcher?.querySelector<HTMLElement>(".demo-results");
  const popover = demo.querySelector<HTMLElement>(".demo-popover");
  const controlsButton = demo.querySelector<HTMLButtonElement>("[data-controls]");
  if (!page || !launcher || !input || !results || !popover || !controlsButton) return;

  const allTabs: TabRef[] = tabButtons.map((button) => ({
    space: Number(button.dataset.space),
    tab: Number(button.dataset.tab),
    title: button.textContent?.trim() ?? "",
    host: button.dataset.host ?? "",
    page: button.dataset.page ?? "",
  }));
  const selectedTab = new Map<number, number>(spaces.map((_, index) => [index, 0]));
  let currentSpace = 0;
  let highlighted = 0;

  const show = (space: number, tab: number) => {
    currentSpace = space;
    selectedTab.set(space, tab);
    demo.dataset.color = dots[space]?.dataset.color ?? "green";
    for (const element of spaces) element.hidden = Number(element.dataset.space) !== space;
    for (const dot of dots)
      dot.setAttribute("aria-pressed", String(Number(dot.dataset.space) === space));
    for (const button of tabButtons) {
      button.setAttribute(
        "aria-pressed",
        String(Number(button.dataset.space) === space && Number(button.dataset.tab) === tab),
      );
    }
    for (const image of images)
      image.hidden = !(Number(image.dataset.space) === space && Number(image.dataset.tab) === tab);
    const host = allTabs.find((item) => item.space === space && item.tab === tab)?.host ?? "";
    for (const element of hosts) element.textContent = host;
    page.scrollTop = 0;
  };

  const closeOverlays = () => {
    launcher.hidden = true;
    popover.hidden = true;
    controlsButton.setAttribute("aria-expanded", "false");
  };

  const matches = (query: string) => {
    const text = query.trim().toLowerCase();
    return text
      ? allTabs.filter((item) => `${item.title} ${item.host}`.toLowerCase().includes(text))
      : allTabs;
  };

  const renderResults = () => {
    const found = matches(input.value);
    highlighted = Math.min(highlighted, Math.max(0, found.length - 1));
    const rows = found.map(
      (item, index) =>
        `<li role="option" aria-selected="${index === highlighted}" data-space="${item.space}" data-tab="${item.tab}"><img src="/assets/screens/fav-${item.page}.png" width="16" height="16" alt=""><span>${escapeText(item.title)}</span><em>${escapeText(item.host)}</em>${index === highlighted ? "<kbd>↩</kbd>" : ""}</li>`,
    );
    if (input.value.trim() && found.length === 0) {
      rows.push(
        `<li role="option" aria-selected="true" data-search><span>Search for "${escapeText(input.value.trim())}"</span></li>`,
      );
    }
    results.innerHTML = rows.join("");
  };

  const openLauncher = () => {
    popover.hidden = true;
    launcher.hidden = false;
    input.value = "";
    highlighted = 0;
    renderResults();
    input.focus({ preventScroll: true });
  };

  const choose = (row: HTMLElement | null | undefined) => {
    if (!row) return;
    if (row.dataset.space) show(Number(row.dataset.space), Number(row.dataset.tab));
    closeOverlays();
  };

  for (const dot of dots)
    dot.addEventListener("click", () =>
      show(Number(dot.dataset.space), selectedTab.get(Number(dot.dataset.space)) ?? 0),
    );
  for (const button of tabButtons)
    button.addEventListener("click", () =>
      show(Number(button.dataset.space), Number(button.dataset.tab)),
    );
  for (const trigger of demo.querySelectorAll<HTMLElement>("[data-launcher]"))
    trigger.addEventListener("click", openLauncher);

  controlsButton.addEventListener("click", () => {
    launcher.hidden = true;
    popover.hidden = !popover.hidden;
    controlsButton.setAttribute("aria-expanded", String(!popover.hidden));
  });
  for (const toggle of popover.querySelectorAll<HTMLButtonElement>(".demo-switch")) {
    toggle.addEventListener("click", () =>
      toggle.setAttribute("aria-pressed", String(toggle.getAttribute("aria-pressed") !== "true")),
    );
  }
  for (const action of popover.querySelectorAll<HTMLButtonElement>("[data-reload]")) {
    action.addEventListener("click", () => {
      page.classList.remove("is-reloading");
      void page.offsetWidth;
      page.classList.add("is-reloading");
      closeOverlays();
    });
  }

  input.addEventListener("input", () => {
    highlighted = 0;
    renderResults();
  });
  input.addEventListener("keydown", (event) => {
    const rows = [...results.querySelectorAll<HTMLElement>("li")];
    if (event.key === "ArrowDown" || event.key === "ArrowUp") {
      event.preventDefault();
      highlighted =
        (highlighted + (event.key === "ArrowDown" ? 1 : rows.length - 1)) %
        Math.max(1, rows.length);
      renderResults();
    } else if (event.key === "Enter") {
      event.preventDefault();
      choose(rows[highlighted]);
    } else if (event.key === "Escape") {
      closeOverlays();
    }
  });
  results.addEventListener("click", (event) => {
    if (event.target instanceof Element) choose(event.target.closest<HTMLElement>("li"));
  });
  document.addEventListener("click", (event) => {
    if (
      !(event.target instanceof Element) ||
      event.target.closest(".demo-launcher, .demo-popover, [data-launcher], [data-controls]")
    )
      return;
    closeOverlays();
  });

  // Two-finger horizontal swipe on the sidebar switches Spaces, as in Shaar.
  const sidebar = demo.querySelector<HTMLElement>(".demo-sidebar");
  let swipe = 0;
  sidebar?.addEventListener(
    "wheel",
    (event) => {
      if (Math.abs(event.deltaX) <= Math.abs(event.deltaY)) return;
      event.preventDefault();
      swipe += event.deltaX;
      if (Math.abs(swipe) > 80) {
        const next = (currentSpace + (swipe > 0 ? 1 : spaces.length - 1)) % spaces.length;
        swipe = 0;
        show(next, selectedTab.get(next) ?? 0);
      }
    },
    { passive: false },
  );

  demo.dataset.ready = "true";
}
