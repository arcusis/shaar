// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { spawn } = require('node:child_process');
const root = path.resolve(__dirname, '../..');
const reportPath = path.join(root, 'build/Verification/picker-locators.json');
fs.rmSync(reportPath, { force: true });
process.env.PLAYWRIGHT_BROWSERS_PATH = path.join(root, 'build/PlaywrightBrowsers');
const { chromium } = require('playwright');
const source = fs.readFileSync(path.join(root, 'Sources/ArcusisBrowser/ElementPickerScript.swift'), 'utf8');
const script = source.match(/static let install = #"""([\s\S]*?)"""#/)[1];
let server;

async function fixtureURL() {
  if (process.env.SHAAR_PICKER_FIXTURE_URL) return process.env.SHAAR_PICKER_FIXTURE_URL;
  server = spawn(path.join(root, '.venv/bin/python'), [path.join(__dirname, 'server.py')], {
    cwd: root, stdio: ['ignore', 'pipe', 'inherit'],
  });
  console.log(`Owned picker fixture PID ${server.pid}`);
  return new Promise((resolve, reject) => {
    let buffer = '';
    const timeout = setTimeout(() => reject(Error('Fixture server did not become ready')), 120000);
    server.once('exit', code => { clearTimeout(timeout); reject(Error(`Fixture exited ${code}`)); });
    server.stdout.on('data', chunk => {
      buffer += chunk;
      if (buffer.includes('\n')) { clearTimeout(timeout); resolve(JSON.parse(buffer.split('\n')[0]).url); }
    });
  });
}

async function run() {
  let browser;
  const cases = [];
  try {
    const base = new URL(await fixtureURL());
    assert.ok(base.hostname.endsWith('.localhost') || base.hostname === '127.0.0.1');
    browser = await chromium.launch({ headless: true });
    const page = await browser.newPage({ viewport: { width: 1100, height: 800 } });
    const errors = [];
    page.on('pageerror', error => errors.push(String(error)));
    for (const [route, selector, frameDepth, strategy, framework] of [
      ['/developer-react', '#react-target', 0, 'testId', 'React'],
      ['/developer-vue', '#vue-target', 0, 'role', 'Vue'],
      ['/developer-plain', '#plain-target', 0, 'text', null],
      ['/developer-plain', '[data-quote-target]', 0, 'role', null],
      ['/developer-plain', '#second-duplicate', 0, 'css', null],
      ['/developer-frame', '#frame-target', 2, 'testId', null],
      ['/developer-complex', '#ambiguous-role', 0, 'text', null],
      ['/developer-complex', '#ambiguous-text', 0, 'xpath', null],
      ['/developer-complex', '#nameless-checkbox', 0, 'xpath', null],
      ['/developer-complex', '#invalid-role', 0, 'text', null],
      ['/developer-complex', '#ambiguous-unicode', 0, 'xpath', null],
      ['/developer-complex', '#outside-shadow', 0, 'text', null],
      ['/developer-complex', '#shadow-css-target', 0, 'xpath', null],
    ]) {
      await page.goto(new URL(route, base).href);
      let scope = page;
      for (let index = 0; index < frameDepth; index++) scope = scope.frameLocator('#picker-frame');
      const target = scope.locator(selector);
      await target.waitFor({ state: 'visible' });
      const expectedID = await target.getAttribute('id');
      const box = await target.boundingBox();
      assert.ok(box);
      await page.evaluate(script);
      await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2);
      await page.waitForFunction(() => globalThis.__shaarPickerV1.snapshot().highlighted);
      const hover = await page.evaluate(() => globalThis.__shaarPickerV1.snapshot().hoverLabel);
      assert.match(hover, /<\w+> \d+ × \d+/);
      await page.mouse.click(box.x + box.width / 2, box.y + box.height / 2);
      const state = await page.evaluate(() => globalThis.__shaarPickerV1.snapshot());
      assert.ok(state.selection, errors.join('\n'));
      const picked = state.selection;
      assert.equal(picked.frames.length, frameDepth);
      let generatedScope = page;
      let prefix = 'page';
      for (const frame of picked.frames) {
        generatedScope = generatedScope.frameLocator(frame);
        prefix += `.frameLocator(${JSON.stringify(frame)})`;
      }
      const xpathTarget = generatedScope.locator(`xpath=${picked.xpath}`);
      assert.equal(await xpathTarget.count(), 1);
      // CSS is scoped to the DOM document; Playwright's CSS engine also pierces open shadows.
      assert.equal(await xpathTarget.evaluate((node, css) => node.ownerDocument.querySelectorAll(css).length, picked.css), 1);
      assert.equal(await xpathTarget.evaluate((node, css) => node.ownerDocument.querySelector(css) === node, picked.css), true);
      let locator, code;
      const value = picked.locator.value;
      switch (picked.locator.strategy) {
        case 'testId': locator = generatedScope.getByTestId(value); code = `${prefix}.getByTestId(${JSON.stringify(value)})`; break;
        case 'role': locator = generatedScope.getByRole(value, { name: picked.locator.name, exact: true }); code = `${prefix}.getByRole(${JSON.stringify(value)}, { name: ${JSON.stringify(picked.locator.name)}, exact: true })`; break;
        case 'text': locator = generatedScope.getByText(value, { exact: true }); code = `${prefix}.getByText(${JSON.stringify(value)}, { exact: true })`; break;
        default: locator = generatedScope.locator(value); code = `${prefix}.locator(${JSON.stringify(value)})`;
      }
      assert.equal(picked.locator.code, code);
      assert.equal(await locator.count(), 1);
      assert.equal(await locator.getAttribute('id'), expectedID);
      assert.equal(picked.locator.strategy, strategy);
      assert.equal(await target.evaluate(() => globalThis.fixtureClicked), undefined);
      if (framework) {
        assert.equal(picked.component.framework, framework);
        assert.equal(picked.component.name, `${framework}Demo`);
        assert.equal(picked.component.source, `/fixture/${framework}Demo.${framework === 'React' ? 'jsx' : 'vue'}`);
      }
      if (frameDepth) await target.press('Escape'); else await page.keyboard.press('Escape');
      assert.equal(await page.evaluate(() => globalThis.__shaarPickerV1.snapshot().closed), true);
      assert.equal(await page.locator('[data-shaar-picker]').count(), 0);
      cases.push({ route, selector, strategy, frameDepth, css: picked.css, xpath: picked.xpath, playwright: picked.locator.code });
    }
    fs.mkdirSync(path.join(root, 'build/Verification'), { recursive: true });
    fs.writeFileSync(path.join(root, 'build/Verification/picker-locators.json'), JSON.stringify({ passed: true, headless: true, browserVersion: browser.version(), sourceSHA256: require('node:crypto').createHash('sha256').update(source).digest('hex'), cases }, null, 2));
    console.log(`Passed ${cases.length} headless selector contracts.`);
  } finally {
    if (browser) await browser.close();
    if (server && server.exitCode === null) {
      console.log(`Stopping owned picker fixture PID ${server.pid}`);
      server.kill('SIGTERM');
    }
  }
}
run().catch(error => { console.error(error); process.exitCode = 1; });
