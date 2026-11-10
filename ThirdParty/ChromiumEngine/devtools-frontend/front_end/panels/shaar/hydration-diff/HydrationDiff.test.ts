// Copyright 2026 The Shaar Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import {assert} from 'chai';

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
    const hydrated = Diff.treeFromSnapshot(sampleSnapshot());
    const report = Diff.diffHydrationTrees(server, hydrated);
    assert.isNull(report.notice);
    assert.deepEqual(report.mismatches, []);
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
