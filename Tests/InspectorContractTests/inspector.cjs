// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { spawn } = require('node:child_process');
const root = path.resolve(__dirname, '../..');
process.env.PLAYWRIGHT_BROWSERS_PATH = path.join(root, 'build/PlaywrightBrowsers');
const { chromium } = require('playwright');
const source = fs.readFileSync(path.join(root, 'Sources/ArcusisBrowser/InspectorPageScript.swift'), 'utf8');
const script = source.match(/static let install = #"""([\s\S]*?)"""#/)[1];
const styleSource = fs.readFileSync(path.join(root, 'Sources/ArcusisBrowser/InspectorStyleScript.swift'), 'utf8');
const styleScript = styleSource.match(/static let install = #"""([\s\S]*?)"""#/)[1];
const output = path.join(root, 'build/Verification/inspector-contracts.json');
fs.rmSync(output, { force: true });
let server, browser;

async function serve() {
  server = spawn(path.join(root, '.venv/bin/python'), [path.join(__dirname, 'server.py')], {
    cwd: root, stdio: ['ignore', 'pipe', 'inherit'],
  });
  console.log('Owned Inspector fixture PID ' + server.pid);
  return new Promise((resolve, reject) => {
    let buffer = '';
    const timer = setTimeout(() => reject(Error('Fixture startup timed out')), 15000);
    server.once('exit', code => { clearTimeout(timer); reject(Error('Fixture exited ' + code)); });
    server.stdout.on('data', chunk => {
      buffer += chunk;
      if (buffer.includes('\n')) { clearTimeout(timer); resolve(JSON.parse(buffer.split('\n')[0]).url); }
    });
  });
}

(async () => {
  const url = await serve();
  browser = await chromium.launch({ headless: true });
  const page = await browser.newPage({ viewport: { width: 1100, height: 850 } });
  await page.goto(url);
  await page.evaluate(script);
  await page.evaluate(styleScript);
  const state = () => page.evaluate(() => globalThis.__shaarInspectorV2.read());
  const waitTag = tag => page.waitForFunction(tag => globalThis.__shaarInspectorV2.read().selection?.tag === tag, tag);
  await page.locator('#save').hover({ force: true });
  await waitTag('span');
  assert.equal((await state()).selection.locked, false);
  const overlay = await page.evaluate(() => globalThis.__shaarInspectorV2.overlay());
  assert.equal(overlay.painted, true);
  assert.equal(overlay.colors.length, 4);
  assert.match(overlay.badge, /span.*×/);
  await page.locator('#save').click({ force: true });
  assert.equal((await state()).selection.locked, true);
  assert.equal(await page.evaluate(() => window.clicked || 0), 0);
  await page.keyboard.press('ArrowUp');
  await waitTag('button');
  let selected = (await state()).selection;
  assert.deepEqual(selected.box.padding, ['10px', '20px', '10px', '20px']);
  assert.deepEqual(selected.box.border, ['2px', '2px', '2px', '2px']);
  assert.equal(selected.playwright, 'page.getByTestId("save")');
  assert.equal(await page.getByTestId('save').count(), 1);
  assert.equal(await page.evaluate(s => document.querySelectorAll(s).length, selected.css), 1);
  assert.equal(await page.evaluate(s => document.evaluate(s, document, null, XPathResult.ORDERED_NODE_SNAPSHOT_TYPE, null).snapshotLength, selected.xpath), 1);
  assert.equal(await page.evaluate(expression => eval(expression).id, selected.jsPath), 'save');
  const cdp = await page.context().newCDPSession(page);
  await cdp.send('DOM.enable');
  const doc = await cdp.send('DOM.getDocument');
  const { nodeId } = await cdp.send('DOM.querySelector', { nodeId: doc.root.nodeId, selector: '#save' });
  await cdp.send('CSS.enable');
  const matches = await cdp.send('CSS.getMatchedStylesForNode', { nodeId });
  const authored = matches.matchedCSSRules.find(row => row.rule.origin === 'regular').rule;
  const sourceURL = await page.evaluate(([selector, text]) => globalThis.__shaarInspectorStyles.sourceFor(selector, text), [authored.selectorList.text, authored.style.cssText]);
  assert.equal(sourceURL, url + '#style-1');
  await cdp.detach();
  let edited = await page.evaluate(id => globalThis.__shaarInspectorStyles.edit(id, 'padding', '30px', 'important'), selected.id);
  assert.equal(edited.ok, true);
  assert.equal(await page.locator('#save').evaluate(el => getComputedStyle(el).padding), '30px');
  assert.equal((await page.evaluate(() => globalThis.__shaarInspectorStyles.undo())).ok, true);
  assert.equal(await page.locator('#save').getAttribute('style'), null);
  assert.match((await page.evaluate(id => globalThis.__shaarInspectorStyles.edit(id, 'padding', 'invalid-css', ''), selected.id)).error, /support/);
  await page.keyboard.down('Alt');
  await page.locator('#next').hover({ force: true });
  await page.waitForFunction(() => globalThis.__shaarInspectorStyles.measurement() !== null);
  assert.equal((await page.evaluate(() => globalThis.__shaarInspectorStyles.measurement())).horizontal, 32);
  await page.keyboard.up('Alt');
  assert.equal(await page.evaluate(() => globalThis.__shaarInspectorStyles.measurement()), null);
  await page.keyboard.press('ArrowRight');
  assert.equal((await state()).selection.css, '#next');
  await page.keyboard.press('ArrowLeft');
  assert.equal((await state()).selection.css, '#save');
  await page.keyboard.press('ArrowDown');
  await waitTag('span');
  const parent = (await state()).selection.ancestors.find(n => n.label === 'main');
  await page.evaluate(id => globalThis.__shaarInspectorV2.choose(id), parent.id);
  await waitTag('main');
  await page.evaluate(() => globalThis.__shaarInspectorV2.pick());
  await page.locator('#transparent').click({ force: true });
  selected = (await state()).selection;
  assert.equal(selected.foreground.rgba[3], 0.5);
  assert.equal(selected.contrastLimit, null);
  await page.evaluate(() => globalThis.__shaarInspectorV2.pick());
  await page.locator('#gradient').click({ force: true });
  assert.match((await state()).selection.contrastLimit, /gradient/i);
  await page.evaluate(() => globalThis.__shaarInspectorV2.pick());
  const frame = page.frameLocator('#frame');
  await frame.locator('#nested').click({ force: true });
  selected = (await state()).selection;
  assert.equal(selected.frames.length, 1);
  assert.match(selected.playwright, /frameLocator/);
  assert.equal(await page.evaluate(expression => eval(expression).id, selected.jsPath), 'nested');
  await page.evaluate(() => { document.querySelector('#frame').src = '/inspector-frame?reload=1'; });
  await frame.locator('#nested').waitFor();
  await page.evaluate(() => globalThis.__shaarInspectorV2.pick());
  await frame.locator('#nested').click({ force: true });
  assert.equal((await state()).selection.frames.length, 1);
  selected = (await state()).selection;
  assert.equal((await page.evaluate(id => globalThis.__shaarInspectorStyles.edit(id, 'color', 'red', ''), selected.id)).ok, true);
  await frame.locator('#nested').evaluate(el => { el.style.color = 'blue'; });
  assert.match((await page.evaluate(() => globalThis.__shaarInspectorStyles.undo())).error, /Page styles changed/);
  assert.equal(await frame.locator('#nested').evaluate(el => el.style.color), 'blue');
  await page.keyboard.press('Escape');
  assert.equal((await state()).closed, true);
  assert.equal(await page.locator('[data-shaar-inspector]').count(), 0);
  fs.mkdirSync(path.dirname(output), { recursive: true });
  fs.writeFileSync(output, JSON.stringify({
    passed: true, headless: true, browserVersion: browser.version(),
    sourceSHA256: require('node:crypto').createHash('sha256').update(source).digest('hex'),
    styleSourceSHA256: require('node:crypto').createHash('sha256').update(styleSource).digest('hex'),
    checks: ['hover regions', 'lock interception', 'arrow navigation', 'breadcrumb', 'unique CSS/XPath/JS/Playwright', 'CSS edit and exact undo', 'CSS validation', 'Option measurement and release', 'conflicting page edit preserves page changes', 'alpha precision', 'gradient limit', 'same-origin iframe', 'iframe reload listeners', 'Escape cleanup'],
  }, null, 2));
  console.log('Passed Inspector renderer contracts.');
})().catch(error => { console.error(error); process.exitCode = 1; }).finally(async () => {
  await browser?.close();
  if (server) { console.log('Stopping owned Inspector fixture PID ' + server.pid); server.kill('SIGTERM'); }
});
