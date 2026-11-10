// Copyright 2026 The Shaar Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import {assert} from 'chai';

import type {MeasuredNode} from './OverflowFinder.js';
import * as Overflow from './overflow.js';

const Finder = Overflow.OverflowFinder;
const Page = Overflow.OverflowPage;

describe('OverflowFinder', () => {
  it('reports a wide child and a vertical sticker, and skips the child the parent explains', () => {
    const report = Finder.findOverflowCauses([
      box('html', {selector: 'html', tag: 'html', scrollWidth: 2400, clientWidth: 800, right: 800, bottom: 600, contentRight: 800, contentBottom: 600}),
      box('body', {selector: 'body', tag: 'body', parentId: 'html', scrollWidth: 2400, clientWidth: 800, right: 800, bottom: 600, contentRight: 800, contentBottom: 600}),
      box('wide', {selector: '#wide', parentId: 'body', scrollWidth: 2400, clientWidth: 2400, right: 2400, bottom: 30, contentRight: 2400, contentBottom: 30}),
      box('inside', {selector: '#inside', parentId: 'wide', right: 100, bottom: 20, contentRight: 100, contentBottom: 20}),
      box('full', {selector: '#full', parentId: 'body', top: 30, bottom: 50, contentTop: 30, contentBottom: 50, uses100vw: true}),
      box('tall', {selector: '#tall', parentId: 'body', scrollHeight: 200, clientHeight: 20, right: 100, top: 50, bottom: 70, contentRight: 100, contentTop: 50, contentBottom: 70, clipsVertical: true}),
      box('item', {selector: '#tall-item', parentId: 'tall', right: 100, top: 50, bottom: 250, contentRight: 100, contentTop: 50, contentBottom: 250}),
    ]);
    const selectors = report.causes.map(cause => cause.selector);
    assert.include(selectors, '#wide');
    assert.include(selectors, '#tall-item');
    assert.include(selectors, '#full');
    assert.notInclude(selectors, '#inside');
    assert.notInclude(selectors, 'html');
    assert.notInclude(selectors, 'body');
    assert.notInclude(selectors, '#tall');
    const full = report.causes.find(cause => cause.selector === '#full');
    const wide = report.causes.find(cause => cause.selector === '#wide');
    assert.isTrue(full?.uses100vw);
    assert.deepEqual(wide?.axes, ['horizontal']);
  });

  it('omits a child explained by its parent', () => {
    const report = Finder.findOverflowCauses([
      box('html', {selector: 'html', tag: 'html', scrollWidth: 500, clientWidth: 100, right: 100, bottom: 200, contentRight: 100, contentBottom: 200}),
      box('box', {selector: '#box', parentId: 'html', scrollWidth: 400, clientWidth: 100, right: 400, bottom: 40, contentRight: 100, contentBottom: 40}),
      box('item', {selector: '#item', parentId: 'box', right: 400, bottom: 20, contentRight: 400, contentBottom: 20}),
    ]);
    assert.deepEqual(report.causes.map(cause => cause.selector), ['#box']);
  });

  it('does not report a visible box whose line box is slightly taller than the client box', () => {
    const report = Finder.findOverflowCauses([
      box('html', {selector: 'html', tag: 'html', bottom: 400, contentBottom: 400}),
      box('inside', {selector: '#inside', parentId: 'html', scrollHeight: 20, clientHeight: 18, bottom: 18, contentBottom: 18}),
    ]);
    assert.deepEqual(report.causes, []);
  });

  it('ignores one pixel past the client box', () => {
    const report = Finder.findOverflowCauses([
      box('tight', {selector: 'p', scrollWidth: 101, clientWidth: 100, right: 100, contentRight: 100}),
    ]);
    assert.deepEqual(report.causes, []);
  });

  it('reports a scroller that has no sticking child', () => {
    const report = Finder.findOverflowCauses([
      box('text', {selector: 'p', scrollWidth: 400, clientWidth: 100, right: 100, contentRight: 100}),
      box('child', {selector: 'span', parentId: 'text', right: 90, contentRight: 90}),
    ]);
    assert.deepEqual(report.causes.map(cause => cause.selector), ['p']);
  });

  it('flags 100vw when the page does not scroll', () => {
    const report = Finder.findOverflowCauses([
      box('full', {selector: '#full', uses100vw: true}),
    ]);
    assert.lengthOf(report.causes, 1);
    assert.isTrue(report.causes[0].uses100vw);
    assert.deepEqual(report.causes[0].axes, []);
  });

  it('does not repeat a nested 100vw rule', () => {
    const report = Finder.findOverflowCauses([
      box('outer', {selector: '#outer', uses100vw: true}),
      box('inner', {selector: '#inner', parentId: 'outer', uses100vw: true}),
    ]);
    assert.deepEqual(report.causes.map(cause => cause.selector), ['#outer']);
  });

  it('reports sibling stickers', () => {
    const report = Finder.findOverflowCauses([
      box('html', {selector: 'html', tag: 'html', scrollWidth: 1200, clientWidth: 800, right: 800, contentRight: 800}),
      box('a', {selector: '#a', parentId: 'html', right: 900, contentRight: 900}),
      box('b', {selector: '#b', parentId: 'html', right: 1100, top: 20, bottom: 40, contentRight: 1100, contentTop: 20, contentBottom: 40}),
    ]);
    const selectors = report.causes.map(cause => cause.selector);
    assert.include(selectors, '#a');
    assert.include(selectors, '#b');
    assert.notInclude(selectors, 'html');
  });

  it('stops the cause list at 100', () => {
    const nodes = [];
    for (let index = 1; index <= 101; index++) {
      nodes.push(box(`n${index}`, {selector: `#n${index}`, scrollWidth: 50, clientWidth: 10}));
    }
    const report = Finder.findOverflowCauses(nodes);
    assert.isTrue(report.truncated);
    assert.lengthOf(report.causes, 100);
  });

  it('skips a hidden node', () => {
    const report = Finder.findOverflowCauses([
      box('gone', {selector: '#gone', scrollWidth: 400, clientWidth: 10, rendered: false}),
    ]);
    assert.deepEqual(report.causes, []);
  });

  it('returns no causes for a non-array', () => {
    const report = Finder.findOverflowCauses(null);
    assert.deepEqual(report.causes, []);
    assert.isFalse(report.truncated);
  });

  it('joins axes, the 100vw flag, and the size', () => {
    const detail = Page.causeDetail(
        {
          id: '1',
          selector: '#full',
          tag: 'div',
          axes: ['horizontal', 'vertical'],
          uses100vw: true,
          width: 2400,
          height: 30,
        },
        {horizontal: 'Horizontal', vertical: 'Vertical'});
    assert.strictEqual(detail, 'Horizontal · Vertical · 100vw · 2400×30');
  });

  it('escapes a selector passed to the page', () => {
    const expression = Page.highlightExpression('a"b\\c\n');
    assert.include(expression, JSON.stringify('a"b\\c\n'));
    const collect = Page.collectExpression();
    assert.include(collect, 'return collectOverflowInPage();');
    assert.include(collect, 'location.href');
    assert.isFunction(new Function(collect));
    assert.isFunction(new Function(expression));
  });

  it('rejects a measurement that is not the page payload', () => {
    assert.isNull(Page.readMeasurement(null));
    assert.isNull(Page.readMeasurement({nodes: []}));
    const measured = Page.readMeasurement({href: 'https://example.com/', truncated: true, nodes: []});
    assert.strictEqual(measured?.href, 'https://example.com/');
    assert.isTrue(measured?.truncated);
  });

  it('treats a trailing slash as the same document', async () => {
    const session = new Page.OverflowSession();
    await session.scan(async () => ({href: 'https://example.com/', truncated: false, nodes: []}), 'https://example.com');
    assert.strictEqual(session.failure, null);
    assert.isTrue(session.scanned);
  });

  it('stores a parsed report and ignores a hash-only difference', async () => {
    const session = new Page.OverflowSession();
    await session.scan(async () => ({
                        href: 'https://example.com/#section',
                        truncated: true,
                        nodes: [
                          box('text', {selector: 'p', scrollWidth: 400, clientWidth: 100, right: 100, contentRight: 100}),
                        ],
                      }),
                      'https://example.com/');
    assert.isTrue(session.scanned);
    assert.isTrue(session.truncated);
    assert.strictEqual(session.failure, null);
    assert.deepEqual(session.causes.map(cause => cause.selector), ['p']);
  });

  it('drops a scan that finishes after reset', async () => {
    const session = new Page.OverflowSession();
    let release = (_value: unknown): void => {};
    const pending = new Promise<unknown>(resolve => {
      release = resolve;
    });
    const started = session.scan(() => pending, 'https://example.com/');
    session.reset();
    release({
      href: 'https://example.com/',
      truncated: false,
      nodes: [box('text', {selector: 'p', scrollWidth: 400, clientWidth: 100, right: 100, contentRight: 100})],
    });
    await started;
    assert.isFalse(session.scanned);
    assert.strictEqual(session.causes.length, 0);
    assert.isFalse(session.scanning);
  });

  it('does not keep causes from a different document', async () => {
    const session = new Page.OverflowSession();
    await session.scan(
        async () => ({
          href: 'http://127.0.0.1:9/',
          truncated: false,
          nodes: [box('wide', {selector: '#wide', scrollWidth: 400, clientWidth: 100, right: 400, contentRight: 100})],
        }),
        'https://example.com/');
    assert.strictEqual(session.failure, Page.MOVED);
    assert.isTrue(session.scanned);
    assert.strictEqual(session.causes.length, 0);
  });
});

function box(id: string, fields: Partial<MeasuredNode>&{selector: string}): MeasuredNode {
  const left = fields.left ?? 0;
  const right = fields.right ?? 10;
  const top = fields.top ?? 0;
  const bottom = fields.bottom ?? 10;
  return {
    id,
    parentId: fields.parentId ?? null,
    selector: fields.selector,
    tag: fields.tag ?? 'div',
    scrollWidth: fields.scrollWidth ?? 10,
    clientWidth: fields.clientWidth ?? 10,
    scrollHeight: fields.scrollHeight ?? 10,
    clientHeight: fields.clientHeight ?? 10,
    left,
    right,
    top,
    bottom,
    contentLeft: fields.contentLeft ?? left,
    contentRight: fields.contentRight ?? right,
    contentTop: fields.contentTop ?? top,
    contentBottom: fields.contentBottom ?? bottom,
    clipsHorizontal: fields.clipsHorizontal ?? false,
    clipsVertical: fields.clipsVertical ?? false,
    uses100vw: fields.uses100vw ?? false,
    width: fields.width ?? Math.max(0, right - left),
    height: fields.height ?? Math.max(0, bottom - top),
    rendered: fields.rendered ?? true,
  };
}
