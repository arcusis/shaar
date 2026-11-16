// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import { parseHTML } from "linkedom";
import { HomePage } from "../src/components/home";
import { tourFeatures } from "../src/components/tour";
import { initializeTour } from "../src/tour";

test("every release feature has a screenshot, named choices and live feedback", () => {
  const document = parseHTML(HomePage()).document;
  const articles = [...document.querySelectorAll<HTMLElement>("[data-tour-feature]")];
  assert.equal(articles.length, tourFeatures.length);
  assert.equal(new Set(tourFeatures.map((feature) => feature.id)).size, tourFeatures.length);
  for (const article of articles) {
    assert.ok(article.id);
    assert.ok(article.querySelector(`h3#${article.id}-title`));
    const shot = article.querySelector("img");
    assert.ok(shot?.getAttribute("src")?.startsWith("/assets/screens/"), article.id);
    assert.ok(shot?.getAttribute("alt"), article.id);
    assert.ok(
      article.querySelectorAll('button[type="button"][aria-pressed]').length >= 2,
      article.id,
    );
    assert.ok(article.querySelector('[role="status"] [data-tour-output]'), article.id);
    const previews = [...article.querySelectorAll<HTMLElement>("[data-tour-preview]")];
    assert.equal(previews.length, article.querySelectorAll("[data-choice]").length, article.id);
    assert.equal(previews.filter((preview) => !preview.hidden).length, 1, article.id);
    assert.equal(
      article.querySelector("[style]"),
      null,
      `${article.id} must respect style-src 'self'`,
    );
  }
});

test("tour controls update visual state and screen-reader status", () => {
  const dom = parseHTML(HomePage());
  Object.assign(globalThis, {
    document: dom.document,
    window: { matchMedia: () => ({ matches: true, addEventListener: () => {} }) },
  });
  initializeTour();

  for (const article of dom.document.querySelectorAll<HTMLElement>("[data-tour-feature]")) {
    const buttons = [...article.querySelectorAll<HTMLButtonElement>("[data-choice]")];
    const previews = [...article.querySelectorAll<HTMLElement>("[data-tour-preview]")];
    const last = buttons.at(-1);
    assert.ok(last);
    last.click();
    assert.equal(last.getAttribute("aria-pressed"), "true", article.id);
    assert.equal(buttons[0].getAttribute("aria-pressed"), "false", article.id);
    assert.equal(article.querySelector("[data-tour-output]")?.textContent, last.dataset.message);
    assert.equal(previews.filter((preview) => !preview.hidden).length, 1, article.id);
    assert.equal(previews.at(-1)?.hidden, false, article.id);
  }

  const hebrew = dom.document.querySelector<HTMLElement>("#hebrew .tour-live");
  assert.equal(hebrew?.dir, "rtl");
  assert.equal(hebrew?.lang, "he");
});

test("tour arrow keys move focus and selection", () => {
  const dom = parseHTML(HomePage());
  Object.assign(globalThis, {
    document: dom.document,
    window: { matchMedia: () => ({ matches: true, addEventListener: () => {} }) },
  });
  initializeTour();
  const buttons = [...dom.document.querySelectorAll<HTMLButtonElement>("#spaces [data-choice]")];
  assert.equal(buttons.length, 3);
  let focused = false;
  buttons[1].focus = () => {
    focused = true;
  };
  const event = new dom.Event("keydown", { bubbles: true, cancelable: true });
  Object.defineProperty(event, "key", { value: "ArrowRight" });
  buttons[0].dispatchEvent(event);
  assert.equal(focused, true);
  assert.equal(buttons[1].getAttribute("aria-pressed"), "true");
  assert.equal(event.defaultPrevented, true);
});

test("tour stays readable without JavaScript and honors reduced motion", () => {
  const document = parseHTML(HomePage()).document;
  assert.ok(document.querySelector("#spaces h3"));
  assert.ok(document.querySelector("#hebrew img"));
  const styles = readFileSync(new URL("../src/styles.css", import.meta.url), "utf8");
  assert.match(styles, /html:not\(\[data-enhanced\]\) \.tour-interaction/);
  assert.match(styles, /@media \(prefers-reduced-motion: reduce\)/);
});
