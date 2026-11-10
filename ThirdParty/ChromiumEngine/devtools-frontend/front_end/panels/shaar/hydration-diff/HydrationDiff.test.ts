// Copyright 2026 The Shaar Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import {assert} from 'chai';
import sinon from 'sinon';

import * as Hydration from './hydration-diff.js';

const Diff = Hydration.HydrationDiff;

describe('HydrationDiff', () => {
  it('reports nothing for identical trees', () => {
    const server = Diff.bodyNode([
      Diff.elementNode('p', [{name: 'class', value: 'b a'}], [Diff.textNode('Hello')]),
    ]);
    const page = Diff.bodyNode([
      Diff.elementNode('p', [{name: 'class', value: 'a b'}], [Diff.textNode('  Hello  ')]),
    ]);
    const report = Diff.diffHydrationTrees(server, page);
    assert.isNull(report.notice);
    assert.deepEqual(report.mismatches, []);
    assert.isFalse(report.truncated);
  });

  it('lists text, attribute, missing, and extra nodes', () => {
    const server = Diff.bodyNode([
      Diff.elementNode('h1', [], [Diff.textNode('Server')]),
      Diff.elementNode('p', [{name: 'id', value: 'lead'}, {name: 'class', value: 'old'}], [Diff.textNode('Same')]),
      Diff.elementNode('footer', [], [Diff.textNode('Only server')]),
    ]);
    const page = Diff.bodyNode([
      Diff.elementNode('h1', [], [Diff.textNode('Page', 4)]),
      Diff.elementNode('p', [{name: 'id', value: 'lead'}, {name: 'class', value: 'new'}], [Diff.textNode('Same')], 8),
      Diff.elementNode('aside', [], [Diff.textNode('Only page')], 9),
    ]);
    const report = Diff.diffHydrationTrees(server, page);
    assert.isNull(report.notice);
    assert.deepEqual(report.mismatches.map(mismatch => mismatch.kind), [
      'text',
      'attribute',
      'missing',
      'extra',
    ]);
    assert.strictEqual(report.mismatches[0].path, 'body > h1 > #text');
    assert.strictEqual(report.mismatches[0].server, 'Server');
    assert.strictEqual(report.mismatches[0].page, 'Page');
    assert.strictEqual(report.mismatches[0].backendNodeId, 4);
    assert.strictEqual(report.mismatches[1].attributeName, 'class');
    assert.strictEqual(report.mismatches[1].path, 'body > p#lead');
    assert.strictEqual(report.mismatches[1].backendNodeId, 8);
    assert.strictEqual(report.mismatches[2].path, 'body > footer');
    assert.isNull(report.mismatches[2].backendNodeId);
    assert.strictEqual(report.mismatches[3].path, 'body > aside');
    assert.strictEqual(report.mismatches[3].backendNodeId, 9);
  });

  it('does not shift the rest of the list when one node is inserted', () => {
    const server = Diff.bodyNode([
      Diff.elementNode('h1', [], [Diff.textNode('Title')]),
      Diff.elementNode('p', [], [Diff.textNode('Body')]),
    ]);
    const page = Diff.bodyNode([
      Diff.elementNode('h1', [], [Diff.textNode('Title')]),
      Diff.elementNode('div', [], [Diff.textNode('Inserted')], 3),
      Diff.elementNode('p', [], [Diff.textNode('Body')]),
    ]);
    const report = Diff.diffHydrationTrees(server, page);
    assert.deepEqual(report.mismatches.map(mismatch => mismatch.kind), ['extra']);
    assert.strictEqual(report.mismatches[0].path, 'body > div');
  });

  it('calls an empty document a client shell when the page has content', () => {
    const page = Diff.bodyNode([Diff.elementNode('main', [], [Diff.textNode('Rendered')])]);
    const report = Diff.diffHydrationTrees(Diff.bodyNode([]), page);
    assert.strictEqual(report.notice, 'client-shell-empty');
    assert.strictEqual(report.mismatches[0].kind, 'extra');
  });

  it('calls an empty mount a client shell', () => {
    const server = Diff.bodyNode([Diff.elementNode('div', [{name: 'id', value: 'root'}])]);
    const page = Diff.bodyNode([
      Diff.elementNode('div', [{name: 'id', value: 'root'}], [
        Diff.elementNode('p', [], [Diff.textNode('Hydrated')], 12),
      ]),
    ]);
    const report = Diff.diffHydrationTrees(server, page);
    assert.strictEqual(report.notice, 'client-shell-mount');
    assert.strictEqual(report.mismatches[0].kind, 'extra');
    assert.strictEqual(report.mismatches[0].backendNodeId, 12);
  });

  it('does not call a mount with server content a client shell', () => {
    const server = Diff.bodyNode([
      Diff.elementNode('div', [{name: 'id', value: '__next'}], [Diff.textNode('From the server')]),
    ]);
    const page = Diff.bodyNode([
      Diff.elementNode('div', [{name: 'id', value: '__next'}], [Diff.textNode('From the server')]),
    ]);
    assert.isNull(Diff.diffHydrationTrees(server, page).notice);
  });

  it('does not call two empty documents a client shell', () => {
    assert.isNull(Diff.diffHydrationTrees(Diff.bodyNode([]), Diff.bodyNode([])).notice);
  });

  it('ignores framework bookkeeping attributes', () => {
    const server = Diff.bodyNode([Diff.elementNode('div', [{name: 'id', value: 'app'}], [Diff.textNode('Hi')])]);
    const page = Diff.bodyNode([
      Diff.elementNode('div', [
        {name: 'id', value: 'app'},
        {name: 'data-reactroot', value: ''},
        {name: 'nonce', value: 'server-only'},
      ], [Diff.textNode('Hi')]),
    ]);
    assert.deepEqual(Diff.diffHydrationTrees(server, page).mismatches, []);
  });

  it('stops the mismatch list at the limit', () => {
    const extras = [];
    for (let index = 0; index < Diff.MISMATCH_LIMIT + 5; index++) {
      extras.push(Diff.elementNode('li', [], [Diff.textNode(String(index))], index + 1));
    }
    const report = Diff.diffHydrationTrees(Diff.bodyNode([]), Diff.bodyNode(extras));
    assert.lengthOf(report.mismatches, Diff.MISMATCH_LIMIT);
    assert.isTrue(report.truncated);
    assert.strictEqual(report.notice, 'client-shell-empty');
  });

  it('keeps the body and drops scripts, shadow trees, and pseudos', () => {
    const tree = Diff.treeFromSnapshot(sampleSnapshot());
    assert.strictEqual(tree.name, 'body');
    assert.lengthOf(tree.children, 1);
    assert.strictEqual(tree.children[0].name, 'p');
    assert.strictEqual(tree.children[0].backendNodeId, 21);
    assert.strictEqual(tree.children[0].children[0].value, 'Hi');
    assert.strictEqual(tree.children[0].attributes[0].name, 'class');
    assert.strictEqual(tree.children[0].attributes[0].value, 'a b');
  });

  it('does not diff a non-html response', () => {
    assert.isFalse(Diff.looksLikeHTML('{"ok":true}'));
    const report = Diff.diffServerHTML('{"ok":true}', Diff.bodyNode([Diff.elementNode('p')]));
    assert.strictEqual(report.notice, 'not-html');
    assert.deepEqual(report.mismatches, []);
  });

  it('agrees with DOMParser for a small document', () => {
    const html = '<!doctype html><html><head><script>bad()</script></head><body><p class="b a">Hi</p></body></html>';
    const server = Diff.treeFromHTML(html);
    assert.strictEqual(server.name, 'body');
    assert.lengthOf(server.children, 1);
    assert.strictEqual(server.children[0].name, 'p');
    assert.strictEqual(server.children[0].attributes[0].name, 'class');
    assert.strictEqual(server.children[0].attributes[0].value, 'a b');
    assert.strictEqual(server.children[0].children[0].name, '#text');
    assert.strictEqual(server.children[0].children[0].value, 'Hi');
    const report = Diff.diffHydrationTrees(server, Diff.treeFromSnapshot(sampleSnapshot()));
    assert.isNull(report.notice);
    assert.deepEqual(report.mismatches, []);
  });

  it('does not call an image or svg mount a client shell', () => {
    const image = Diff.bodyNode([
      Diff.elementNode('div', [{name: 'id', value: 'root'}], [Diff.elementNode('img', [{name: 'src', value: 'hero.jpg'}])]),
    ]);
    assert.isNull(Diff.diffHydrationTrees(image, image).notice);

    const server = Diff.bodyNode([
      Diff.elementNode('div', [{name: 'id', value: 'root'}], [Diff.elementNode('svg', [], [Diff.elementNode('path')])]),
    ]);
    const page = Diff.bodyNode([
      Diff.elementNode('div', [{name: 'id', value: 'root'}], [Diff.elementNode('p', [], [Diff.textNode('Hydrated')], 12)]),
    ]);
    const report = Diff.diffHydrationTrees(server, page);
    assert.isNull(report.notice);
    assert.isAtLeast(report.mismatches.length, 1);
  });

  it('keeps one insertion in a long sibling list as a single extra', () => {
    const count = 5000;
    const serverChildren = [];
    const pageChildren = [];
    for (let index = 0; index < count; index++) {
      const id = 'n' + index;
      serverChildren.push(Diff.elementNode('li', [{name: 'id', value: id}], [Diff.textNode(String(index))]));
      pageChildren.push(Diff.elementNode('li', [{name: 'id', value: id}], [Diff.textNode(String(index))]));
    }
    pageChildren.splice(
        2500, 0, Diff.elementNode('li', [{name: 'id', value: 'inserted'}], [Diff.textNode('x')], 7));
    const report = Diff.diffHydrationTrees(Diff.bodyNode(serverChildren), Diff.bodyNode(pageChildren));
    assert.deepEqual(report.mismatches.map(mismatch => mismatch.kind), ['extra']);
    assert.strictEqual(report.mismatches[0].path, 'body > li#inserted');
    assert.strictEqual(report.mismatches[0].backendNodeId, 7);
  });
});

describe('HydrationSettle', () => {
  const Settle = Hydration.HydrationSettle;

  it('finds the document after a hash change or pushState', () => {
    const documentResource = {
      url: 'https://example.com/app',
      isDocument: true,
      loaderId: 'loader-1',
      isRedirect: false,
    };
    const pushedFetch = {
      url: 'https://example.com/app/2',
      isDocument: false,
      loaderId: 'loader-1',
      isRedirect: false,
    };
    const hashed = Settle.pickDocumentResource(
        'https://example.com/app#section', 'loader-1', [documentResource, pushedFetch]);
    assert.strictEqual(hashed, documentResource);
    const pushed = Settle.pickDocumentResource('https://example.com/app/2', 'loader-1', [pushedFetch, documentResource]);
    assert.strictEqual(pushed, documentResource);
  });

  it('ignores a redirect and keeps the final document', () => {
    const redirect = {url: 'https://example.com/old', isDocument: true, loaderId: 'loader-1', isRedirect: true};
    const finalDocument = {url: 'https://example.com/new', isDocument: true, loaderId: 'loader-1', isRedirect: false};
    const picked = Settle.pickDocumentResource('https://example.com/new', 'loader-1', [redirect, finalDocument]);
    assert.strictEqual(picked, finalDocument);
  });

  it('drops the load listener and the timer when load never arrives', async () => {
    let listeners = 0;
    const loaded = await Settle.attachLoadWait(
        () => {
          listeners++;
        },
        () => {
          listeners--;
        },
        15);
    assert.isFalse(loaded);
    assert.strictEqual(listeners, 0);
  });

  it('drops the load listener and the timer when the load arrives', async () => {
    const clear = sinon.spy(globalThis, 'clearTimeout');
    let fire = (): void => {};
    let listeners = 0;
    try {
      const pending = Settle.attachLoadWait(
          listener => {
            listeners++;
            fire = listener;
          },
          () => {
            listeners--;
          },
          1000);
      fire();
      assert.isTrue(await pending);
      assert.strictEqual(listeners, 0);
      assert.isTrue(clear.called);
    } finally {
      clear.restore();
    }
  });

  it('waits until a tracked fetch finishes and then stays quiet', async () => {
    const tracker = new Settle.RequestSettleTracker();
    const started = Date.now();
    const pending = Settle.waitForQuiet(() => tracker.inflight(), listener => tracker.subscribe(listener), 30, 500);
    tracker.start({id: 'fetch-1', settles: true});
    setTimeout(() => {
      tracker.finish({id: 'fetch-1', settles: true});
    }, 40);
    await pending;
    assert.isAtLeast(Date.now() - started, 60);
    assert.strictEqual(tracker.inflight(), 0);
  });

  it('does not let a socket hold the quiet window open', async () => {
    const tracker = new Settle.RequestSettleTracker();
    tracker.start({id: 'socket', settles: false});
    assert.strictEqual(tracker.inflight(), 0);
    await Settle.waitForQuiet(() => tracker.inflight(), listener => tracker.subscribe(listener), 20, 200);
    assert.strictEqual(tracker.inflight(), 0);
  });

  it('stops waiting at the cap and unsubscribes', async () => {
    const tracker = new Settle.RequestSettleTracker();
    tracker.start({id: 'fetch-1', settles: true});
    await Settle.waitForQuiet(() => tracker.inflight(), listener => tracker.subscribe(listener), 500, 30);
    tracker.finish({id: 'fetch-1', settles: true});
    assert.strictEqual(tracker.inflight(), 0);
  });

  it('extends the quiet window while the DOM is still changing', async () => {
    const clock = sinon.useFakeTimers();
    const host = document.createElement('div');
    document.body.appendChild(host);
    try {
      let settled = false;
      const pending = Settle.pageDomSettle(40, 500, host).then(() => {
        settled = true;
      });
      clock.tick(30);
      await Promise.resolve();
      assert.isFalse(settled);
      host.textContent = 'hydrated';
      await Promise.resolve();
      await Promise.resolve();
      clock.tick(39);
      await Promise.resolve();
      assert.isFalse(settled);
      clock.tick(1);
      await pending;
      assert.isTrue(settled);
    } finally {
      host.remove();
      clock.restore();
    }
  });
});

function sampleSnapshot(): Hydration.HydrationDiff.SnapshotPayload {
  return {
    strings: ['#document', 'HTML', 'HEAD', 'SCRIPT', 'BODY', 'P', 'class', 'b a', 'Hi', 'SPAN', '::before'],
    documents: [{
      nodes: {
        parentIndex: [-1, 0, 1, 2, 1, 4, 5, 4, 4, 4],
        nodeType: [9, 1, 1, 1, 1, 1, 3, 1, 1, 1],
        nodeName: [0, 1, 2, 3, 4, 5, 8, 9, 5, 3],
        nodeValue: [-1, -1, -1, -1, -1, -1, 8, -1, -1, -1],
        backendNodeId: [1, 2, 3, 4, 5, 21, 22, 30, 31, 32],
        attributes: [[], [], [], [], [], [6, 7], [], [], [], []],
        shadowRootType: {index: [7], value: [8]},
        pseudoType: {index: [8], value: [10]},
      },
    }],
  };
}
