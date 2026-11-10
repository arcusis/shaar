// Copyright 2026 The Shaar Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import {assert} from 'chai';

import {readNodeMeasurements} from './StackingCapture.js';

describe('StackingCapture', () => {
  it('reads box models and computed styles in bounded batches', async () => {
    const nodes = Array.from({length: 35}, (_, index) => index);
    let active = 0;
    let maximumActive = 0;
    const read = async (node: number, kind: 'box'|'style'): Promise<string> => {
      active++;
      maximumActive = Math.max(maximumActive, active);
      await Promise.resolve();
      active--;
      return `${kind}-${node}`;
    };

    const details = await readNodeMeasurements(
        nodes, node => read(node, 'box'), node => read(node, 'style'));

    assert.strictEqual(details.length, nodes.length);
    assert.deepEqual(details.map(detail => detail.node), nodes);
    assert.strictEqual(details[0]?.model, 'box-0');
    assert.strictEqual(details[34]?.computed, 'style-34');
    assert.isAtMost(maximumActive, 32);
    assert.isAbove(maximumActive, 2);
  });
});
