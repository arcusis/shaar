// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const root = path.resolve(__dirname, '../..');
process.env.PLAYWRIGHT_BROWSERS_PATH = path.join(root, 'build/PlaywrightBrowsers');
const { chromium } = require('playwright');
const source = fs.readFileSync(
  path.join(root, 'Sources/ArcusisBrowser/InspectorInactiveCSSRules.swift'), 'utf8');
const template = source.match(/private static let template = #"""([\s\S]*?)"""#/)[1];

const fixtures = [
  {
    selector: '#block-container',
    style: 'display:block',
    hints: {
      'justify-content': /flex or grid container/,
      'align-items': /flex or grid container/,
      gap: /flex, grid, or multi-column container/,
      'grid-gap': /flex, grid, or multi-column container/,
      'flex-direction': /flex container/,
      'flex-wrap': /flex container/,
      'flex-flow': /flex container/,
      'grid-template-columns': /grid container/,
      'grid-template-rows': /grid container/,
      'grid-auto-columns': /grid container/,
      'grid-auto-flow': /grid container/,
      grid: /grid container/,
      'grid-column': /grid item/,
      'grid-row': /grid item/,
      'grid-row-start': /grid item/,
      'grid-area': /grid item/,
      'justify-items': /grid container/,
    },
  },
  {
    selector: '#flex-container',
    style: 'display:flex',
    hints: {
      'flex-direction': null,
      'flex-flow': null,
      'align-items': null,
      gap: null,
      'grid-gap': null,
      'grid-template-columns': /grid container/,
      'grid-template-rows': /grid container/,
      'grid-auto-columns': /grid container/,
      grid: /grid container/,
    },
  },
  {
    selector: '#grid-container',
    style: 'display:grid',
    hints: {
      'grid-template-columns': null,
      'grid-template-rows': null,
      'grid-auto-flow': null,
      'grid-auto-columns': null,
      grid: null,
      'grid-row-gap': null,
      'justify-items': null,
      'align-items': null,
      gap: null,
      'flex-direction': /flex container/,
    },
  },
  {
    selector: '#plain-item',
    style: 'display:block',
    parentStyle: 'display:block',
    hints: {
      flex: /flex item/,
      'flex-basis': /flex item/,
      'flex-grow': /flex item/,
      'flex-shrink': /flex item/,
      'grid-column': /grid item/,
      float: null,
    },
  },
  {
    selector: '#flex-item',
    style: 'display:block;position:static',
    parentStyle: 'display:flex',
    hints: {
      flex: null,
      'flex-basis': null,
      'flex-grow': null,
      'flex-shrink': null,
      'grid-column': /grid item/,
      'grid-area': /grid item/,
      float: /flex or grid items/,
      'z-index': null,
      top: /statically positioned/,
    },
  },
  {
    selector: '#grid-item',
    style: 'display:block;position:static',
    parentStyle: 'display:grid',
    hints: {
      'grid-column': null,
      'grid-row': null,
      'grid-row-start': null,
      'flex-grow': /flex item/,
      float: /flex or grid items/,
      'z-index': null,
    },
  },
  {
    selector: '#inline',
    style: 'display:inline',
    hints: {
      width: /non-replaced inline/,
      height: /non-replaced inline/,
      'margin-top': /non-replaced inline/,
      'margin-bottom': /non-replaced inline/,
      'vertical-align': null,
    },
  },
  {
    selector: '#inline-image',
    style: 'display:inline',
    tag: 'img',
    hints: { width: null, height: null, 'margin-top': null, 'margin-bottom': null },
  },
  {
    selector: '#static-position',
    style: 'position:static',
    hints: {
      'z-index': /positioning or a flex\/grid item/,
      top: /statically positioned/,
      left: /statically positioned/,
      right: /statically positioned/,
      bottom: /statically positioned/,
    },
  },
  {
    selector: '#relative-position',
    style: 'position:relative',
    hints: { 'z-index': null, top: null, left: null },
  },
  {
    selector: '#block-vertical-align',
    style: 'display:block',
    hints: { 'vertical-align': /block-level boxes/ },
  },
  {
    selector: '#table-cell',
    style: 'display:table-cell',
    hints: { 'vertical-align': null },
  },
  {
    selector: '#text-visible-nowrap',
    style: 'overflow:visible;white-space:nowrap',
    hints: { 'text-overflow': /overflow: hidden and white-space: nowrap/ },
  },
  {
    selector: '#text-hidden-wrap',
    style: 'overflow:hidden;white-space:normal',
    hints: { 'text-overflow': /overflow: hidden and white-space: nowrap/ },
  },
  {
    selector: '#text-hidden-nowrap',
    style: 'overflow:hidden;white-space:nowrap',
    hints: { 'text-overflow': null },
  },
  {
    selector: '#multi-column',
    style: 'column-count:2',
    hints: {
      gap: null,
      'row-gap': null,
      'column-gap': null,
      'grid-gap': null,
      'grid-row-gap': null,
      'grid-column-gap': null,
    },
  },
];

const html = `<main>${fixtures.map(fixture => {
  const element = `<${fixture.tag || 'div'} id="${fixture.selector.slice(1)}" style="${fixture.style}"></${fixture.tag || 'div'}>`;
  if (!fixture.parentStyle) return element;
  return `<div style="${fixture.parentStyle}">${element}</div>`;
}).join('')}</main>`;

(async () => {
  const browser = await chromium.launch({ headless: true });
  try {
    const page = await browser.newPage();
    await page.setContent(html);
    let assertions = 0;
    for (const fixture of fixtures) {
      const properties = Object.keys(fixture.hints);
      await page.evaluate(selector => {
        globalThis.__shaarInspectorV2 = { element: () => document.querySelector(selector) };
      }, fixture.selector);
      const result = await page.evaluate(
        template.replace('__SHAAR_PROPERTIES__', JSON.stringify(properties)));
      for (const [property, expected] of Object.entries(fixture.hints)) {
        if (expected === null) {
          assert.equal(result[property], undefined, `${fixture.selector} ${property} should apply`);
        } else {
          assert.match(result[property] || '', expected, `${fixture.selector} ${property}`);
        }
        assertions++;
      }
    }
    console.log(JSON.stringify({ passed: true, fixtures: fixtures.length, assertions }, null, 2));
  } finally {
    await browser.close();
  }
})().catch(error => {
  console.error(error);
  process.exitCode = 1;
});
