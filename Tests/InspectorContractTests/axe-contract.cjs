// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const root = path.resolve(__dirname, '../..');
process.env.PLAYWRIGHT_BROWSERS_PATH = path.join(root, 'build/PlaywrightBrowsers');
const { chromium } = require('playwright');
const pin = JSON.parse(fs.readFileSync(path.join(root, 'ThirdParty/axe-core/pin.json'), 'utf8'));
const axePath = path.join(root, pin.bundlePath);
const axeSource = fs.readFileSync(axePath, 'utf8');
const axeSHA = crypto.createHash('sha256').update(axeSource).digest('hex');
assert.equal(pin.version, '4.14.0');
assert.equal(pin.license, 'MPL-2.0');
assert.equal(axeSHA, pin.bundleSHA256);
const runner = fs.readFileSync(path.join(root, 'Sources/ArcusisBrowser/Resources/InspectorAudit/runner.js'), 'utf8');
const runnerExpression = runner.slice(runner.indexOf('(async'));
const inactiveSource = fs.readFileSync(path.join(root, 'Sources/ArcusisBrowser/InspectorInactiveCSSScript.swift'), 'utf8');
const inactiveTemplate = inactiveSource.match(/private static let template = #"""([\s\S]*?)"""#/)[1];
const html = `<!doctype html><html lang="en"><head><title>Audit fixture</title><meta name="viewport" content="width=device-width"></head><body>
  <main>
    <img id="missing-alt" src="data:image/gif;base64,R0lGODlhAQABAAD/ACwAAAAAAQABAAACADs=">
    <button id="unnamed"></button>
    <div id="block" style="display:block;justify-content:center;align-items:center;row-gap:8px;grid-template-columns:1fr;grid-column:1;flex-direction:row;z-index:2;position:static;vertical-align:middle">Block</div>
    <span id="inline" style="display:inline;width:20px;height:30px">Inline</span>
    <div id="flex-parent" style="display:flex"><div id="flex-child" style="position:static;z-index:2;float:left;flex-grow:1">Flex item</div></div>
    <div id="grid-parent" style="display:grid"><div id="grid-child" style="grid-column:1">Grid item</div></div>
  </main>
</body></html>`;

(async () => {
  const browser = await chromium.launch({ headless: true });
  try {
    const context = await browser.newContext();
    await context.addInitScript(() => {
      Object.defineProperty(window, 'axe', {
        configurable: true, enumerable: true, writable: true, value: { sentinel: true },
      });
    });
    const page = await context.newPage();
    await page.setContent(html);
    const originalScripts = await page.locator('script').count();
    const pageResult = await run(page, axeSource, runner, 'page');
    assert(pageResult.violations > 0);
    assert(pageResult.findings.some(row => row.ruleId === 'image-alt' && row.target === '#missing-alt'));
    assert(pageResult.findings.some(row => row.ruleId === 'button-name' && row.target === '#unnamed'));
    assert.equal(pageResult.scope, 'page');
    assert.equal(await page.evaluate(() => window.axe?.sentinel), true, 'restore an existing axe global');
    assert.equal(await page.locator('script').count(), originalScripts, 'leave no injected script node');

    await page.evaluate(() => {
      globalThis.__shaarInspectorV2 = { element: () => document.querySelector('#missing-alt') };
    });
    const selectedResult = await run(page, axeSource, runner, 'selected');
    assert(selectedResult.findings.some(row => row.ruleId === 'image-alt'));
    assert.equal(selectedResult.scope, 'selected');

    const cleanContext = await browser.newContext();
    const cleanPage = await cleanContext.newPage();
    await cleanPage.setContent(html);
    await run(cleanPage, axeSource, runner, 'page');
    assert.equal(await cleanPage.evaluate(() => Object.prototype.hasOwnProperty.call(window, 'axe')), false);
    await cleanContext.close();

    await verifyHints(page, inactiveTemplate);
    console.log(JSON.stringify({
      passed: true, axeVersion: pin.version, violations: pageResult.violations,
      findings: pageResult.findings.length, incomplete: pageResult.incomplete,
      injectedScriptNodes: 0, cleanup: 'restores or removes window.axe', inactiveHintFixtures: 5,
    }, null, 2));
  } finally {
    await browser.close();
  }
})().catch(error => {
  console.error(error);
  process.exitCode = 1;
});

async function run(page, source, script, scope) {
  return page.evaluate(({ source, script, scope }) => new Function(`return ${script}`)()(source, scope), {
    source, script: runnerExpression, scope,
  });
}

async function verifyHints(page, template) {
  const properties = [
    'justify-content', 'align-items', 'row-gap', 'grid-template-columns', 'grid-column',
    'flex-direction', 'width', 'height', 'z-index', 'float', 'vertical-align', 'flex-grow',
  ];
  const evaluate = async selector => {
    await page.evaluate(selector => {
      globalThis.__shaarInspectorV2 = { element: () => document.querySelector(selector) };
    }, selector);
    const expression = template.replace('__SHAAR_PROPERTIES__', JSON.stringify(properties));
    return page.evaluate(expression);
  };
  const block = await evaluate('#block');
  assert.match(block['justify-content'], /flex or grid container/);
  assert.match(block['grid-template-columns'], /grid container/);
  assert.match(block['grid-column'], /grid container or grid item/);
  assert.match(block['flex-direction'], /flex container/);
  assert.match(block['z-index'], /static elements/);
  assert.match(block['vertical-align'], /block-level/);
  const inline = await evaluate('#inline');
  assert.match(inline.width, /non-replaced inline/);
  assert.match(inline.height, /non-replaced inline/);
  const flexChild = await evaluate('#flex-child');
  assert.match(flexChild.float, /flex or grid items/);
  assert.equal(flexChild['z-index'], undefined);
  assert.equal(flexChild['flex-grow'], undefined);
  const gridChild = await evaluate('#grid-child');
  assert.equal(gridChild['grid-column'], undefined);
}
