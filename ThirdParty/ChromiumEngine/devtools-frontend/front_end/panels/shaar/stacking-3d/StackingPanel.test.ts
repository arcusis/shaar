// Copyright 2026 The Shaar Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import {assert} from 'chai';

import {describeWithEnvironment} from '../../../testing/EnvironmentHelpers.js';

import * as Stacking from './stacking-3d.js';

const Model = Stacking.StackingModel;
const openPanels: Stacking.StackingPanel.StackingPanel[] = [];

describeWithEnvironment('StackingPanel', () => {
  afterEach(() => {
    const panel = openPanels.pop();
    panel?.detach(true);
  });

  it('asks for a snapshot before anything is captured', () => {
    const panel = mount();
    panel.performUpdate();
    const empty = panel.contentElement.querySelector('.stacking-empty');
    assert.instanceOf(empty, HTMLElement);
    assert.include(empty.textContent ?? '', 'See depth and stacking');
  });

  it('shows an error when the page is missing', async () => {
    const panel = mount(async () => {
      throw new Stacking.StackingCapture.StackingCaptureError('no-page');
    });
    await panel.capture();
    panel.performUpdate();
    const error = panel.contentElement.querySelector('.stacking-error');
    assert.instanceOf(error, HTMLElement);
    assert.include(error.textContent ?? '', 'Open a page');
    assert.include(panel.contentElement.textContent ?? '', 'Snapshot needs a page');
  });

  it('lists stacking contexts and selects the clicked row in Elements', async () => {
    const selected: number[] = [];
    const panel = mount(async () => ({elements: fixture(), clipped: false}), (nodeId) => {
      selected.push(nodeId);
      return Promise.resolve(true);
    });
    await panel.capture();
    panel.performUpdate();
    assert.include(panel.contentElement.textContent ?? '', '7 elements, 4 stacking contexts');
    const names = [...panel.contentElement.querySelectorAll('.stacking-row-name')].map(node => node.textContent);
    assert.deepEqual(names, ['html', 'div#behind', 'div#modal', 'div#faded']);
    const modal = panel.contentElement.querySelector('[data-node-id="6"]');
    assert.instanceOf(modal, HTMLButtonElement);
    modal.click();
    panel.performUpdate();
    const selectedRow = panel.contentElement.querySelector('[data-node-id="6"]');
    assert.strictEqual(selectedRow?.getAttribute('aria-selected'), 'true');
    assert.deepEqual(selected, [6]);
  });

  it('says when the element cannot be selected', async () => {
    const panel = mount(async () => ({elements: fixture(), clipped: true}), () => Promise.resolve(false));
    await panel.capture();
    panel.selectNode(6);
    await Promise.resolve();
    panel.performUpdate();
    assert.include(panel.contentElement.textContent ?? '', 'The element is not in the Elements tree yet.');
    assert.include(panel.contentElement.textContent ?? '', 'This snapshot stops at the first 180 elements.');
  });
});

function mount(
    collector?: () => Promise<Stacking.StackingModel.StackingSnapshot>,
    select?: (nodeId: number, backendNodeId: number|null) => Promise<boolean>,
    ): Stacking.StackingPanel.StackingPanel {
  const panel = new Stacking.StackingPanel.StackingPanel(collector, select);
  openPanels.push(panel);
  return panel;
}

function fixture(): Stacking.StackingModel.StackingElement[] {
  return [
    box(1, 'html', null, 0, 0, 0, 800, 600, 'static', 'auto', '1'),
    box(2, 'body', 1, 1, 0, 0, 800, 600, 'static', 'auto', '1'),
    box(3, 'div#page', 2, 2, 0, 0, 400, 300, 'relative', 'auto', '1'),
    box(4, 'div#behind', 3, 3, 20, 20, 160, 80, 'absolute', '-1', '1'),
    box(5, 'div#card', 3, 3, 40, 40, 200, 120, 'absolute', 'auto', '1'),
    box(6, 'div#modal', 3, 3, 80, 70, 180, 100, 'absolute', '10', '1'),
    box(7, 'div#faded', 3, 3, 12, 180, 100, 40, 'static', 'auto', '0.5'),
  ];
}

function box(
    nodeId: number, name: string, parentId: number|null, depth: number, x: number, y: number, width: number,
    height: number, position: string, zIndex: string, opacity: string,
    ): Stacking.StackingModel.StackingElement {
  const style = Model.emptyStyle();
  style.position = position;
  style.zIndex = zIndex;
  style.opacity = opacity;
  style.display = 'block';
  return {
    nodeId,
    backendNodeId: nodeId + 100,
    parentId,
    name,
    depth,
    bounds: {x, y, width, height},
    style,
    parentDisplay: 'block',
  };
}
