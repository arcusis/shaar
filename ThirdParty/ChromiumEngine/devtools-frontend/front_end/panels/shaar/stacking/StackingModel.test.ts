// Copyright 2026 The Shaar Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import {assert} from 'chai';

import * as Stacking from './stacking.js';

const Model = Stacking.StackingModel;

describe('StackingModel', () => {
  it('treats a positioned z-index as a context and auto as none', () => {
    const positioned = element(4, 'div#modal', {position: 'absolute', zIndex: '2'});
    const automatic = element(5, 'div#card', {position: 'absolute', zIndex: 'auto'});
    assert.deepEqual(Model.reasonsFor(positioned, false), ['z-index: 2']);
    assert.deepEqual(Model.reasonsFor(automatic, false), []);
  });

  it('creates contexts for opacity, transform, fixed, flex, and paint properties', () => {
    assert.isFalse(Model.reasonsFor(element(1, 'div', {opacity: '1'}), false).some(reason => reason.startsWith('opacity')));
    assert.include(Model.reasonsFor(element(1, 'div', {opacity: '0.5'}), false), 'opacity: 0.5');
    assert.deepEqual(Model.reasonsFor(element(1, 'div', {transform: 'none'}), false), []);
    assert.deepEqual(Model.reasonsFor(element(1, 'div', {transform: 'matrix(1, 0, 0, 1, 0, 0)'}), false), ['transform']);
    assert.deepEqual(Model.reasonsFor(element(1, 'div', {position: 'fixed', zIndex: 'auto'}), false), ['position: fixed']);
    assert.deepEqual(Model.reasonsFor(element(1, 'div', {position: 'static', zIndex: '4'}), false), []);
    const flexItem = element(6, 'div', {zIndex: '1', parentDisplay: 'flex'});
    const flexAuto = element(7, 'div', {zIndex: 'auto', parentDisplay: 'inline-flex'});
    assert.deepEqual(Model.reasonsFor(flexItem, false), ['flex item z-index']);
    assert.deepEqual(Model.reasonsFor(flexAuto, false), []);
    assert.deepEqual(Model.reasonsFor(element(1, 'div', {isolation: 'isolate'}), false), ['isolation']);
    assert.deepEqual(Model.reasonsFor(element(1, 'div', {willChange: 'transform'}), false), ['will-change']);
    assert.deepEqual(Model.reasonsFor(element(1, 'div', {contain: 'paint'}), false), ['contain']);
    assert.deepEqual(Model.reasonsFor(element(1, 'div', {contain: 'layout'}), false), []);
    assert.deepEqual(Model.reasonsFor(element(1, 'div', {filter: 'blur(1px)'}), false), ['filter']);
    assert.deepEqual(Model.reasonsFor(element(1, 'div', {mixBlendMode: 'multiply'}), false), ['mix-blend-mode']);
  });

  it('lifts z-index contexts relative to the parent context', () => {
    const slabs = Model.slabsFrom(page(), 'z-index');
    const level = new Map(slabs.map(slab => [slab.name, slab.level]));
    assert.strictEqual(level.get('html'), 0);
    assert.strictEqual(level.get('div#behind'), -Model.Z_STEP);
    assert.strictEqual(level.get('div#modal'), 10 * Model.Z_STEP);
    const behind = level.get('div#behind');
    const faded = level.get('div#faded');
    const modal = level.get('div#modal');
    assert.isBelow(behind ?? 0, faded ?? 0);
    assert.isBelow(faded ?? 0, modal ?? 0);
    assert.isFalse(slabs.find(slab => slab.name === 'div#card')?.createsContext);
    assert.isTrue(slabs.find(slab => slab.name === 'div#modal')?.createsContext);
  });

  it('separates DOM mode by depth', () => {
    const slabs = Model.slabsFrom(page(), 'dom');
    const modal = slabs.find(slab => slab.name === 'div#modal');
    const card = slabs.find(slab => slab.name === 'div#card');
    assert.strictEqual(modal?.level, (modal?.depth ?? 0) * Model.DOM_STEP);
    assert.strictEqual(card?.depth, modal?.depth);
    assert.strictEqual(card?.level, modal?.level);
  });

  it('omits zero-size elements', () => {
    const hidden = element(3, 'div#gone', {bounds: {x: 0, y: 0, width: 0, height: 10}});
    const shown = element(4, 'div#shown', {bounds: {x: 0, y: 0, width: 20, height: 10}});
    const slabs = Model.slabsFrom([hidden, shown], 'dom');
    assert.deepEqual(slabs.map(slab => slab.name), ['div#shown']);
  });

  it('keeps a deep non-context below the next z-index step', () => {
    const bounds = {x: 0, y: 0, width: 120, height: 80};
    const chain = [
      element(1, 'html', {bounds: {x: 0, y: 0, width: 400, height: 300}, depth: 0}),
      element(2, 'div#d0', {parentId: 1, bounds, depth: 1}),
      element(3, 'div#d1', {parentId: 2, bounds, depth: 2}),
      element(4, 'div#d2', {parentId: 3, bounds, depth: 3}),
      element(5, 'div#d3', {parentId: 4, bounds, depth: 4}),
      element(6, 'div#d4', {parentId: 5, bounds, depth: 5}),
      element(7, 'div#raised', {parentId: 1, bounds, depth: 1, position: 'absolute', zIndex: '1'}),
    ];
    const slabs = Model.slabsFrom(chain, 'z-index');
    const deep = slabs.find(slab => slab.name === 'div#d4');
    const raised = slabs.find(slab => slab.name === 'div#raised');
    assert.strictEqual(slabs.find(slab => slab.name === 'div#d0')?.level, Model.INNER_STEP);
    assert.isBelow(deep?.level ?? 0, Model.Z_STEP);
    assert.strictEqual(raised?.level, Model.Z_STEP);
    assert.isBelow(deep?.level ?? 0, raised?.level ?? 0);
    const camera = {yaw: 0, pitch: 0, zoom: 1, panX: 0, panY: 0};
    assert.strictEqual(Model.hitSlab({x: 40, y: 40}, slabs, camera)?.nodeId, 7);

    const wrapped = [
      element(1, 'html', {bounds: {x: 0, y: 0, width: 400, height: 300}, depth: 0}),
      element(2, 'div#fade', {parentId: 1, bounds, depth: 1, opacity: '0.4'}),
      element(3, 'div#a', {parentId: 2, bounds, depth: 2}),
      element(4, 'div#b', {parentId: 3, bounds, depth: 3}),
      element(5, 'div#c', {parentId: 4, bounds, depth: 4}),
      element(6, 'div#d', {parentId: 5, bounds, depth: 5}),
      element(7, 'div#raised', {parentId: 1, bounds, depth: 1, position: 'absolute', zIndex: '1'}),
    ];
    const wrappedSlabs = Model.slabsFrom(wrapped, 'z-index');
    const wrappedDeep = wrappedSlabs.find(slab => slab.name === 'div#d');
    const wrappedRaised = wrappedSlabs.find(slab => slab.name === 'div#raised');
    assert.isBelow(wrappedDeep?.level ?? 0, wrappedRaised?.level ?? 0);
    assert.strictEqual(Model.hitSlab({x: 40, y: 40}, wrappedSlabs, camera)?.nodeId, 7);
  });

  it('picks the higher slab when the quads overlap', () => {
    const root = element(1, 'html', {bounds: {x: 0, y: 0, width: 200, height: 200}, depth: 0});
    const child = element(2, 'div#modal', {
      parentId: 1,
      bounds: {x: 20, y: 20, width: 40, height: 40},
      depth: 1,
      position: 'absolute',
      zIndex: '3',
    });
    const slabs = Model.slabsFrom([root, child], 'dom');
    const camera = {yaw: 0, pitch: 0, zoom: 1, panX: 0, panY: 0};
    assert.strictEqual(Model.hitSlab({x: 30, y: 30}, slabs, camera)?.nodeId, 2);
    assert.strictEqual(Model.hitSlab({x: 10, y: 10}, slabs, camera)?.nodeId, 1);
    assert.isNull(Model.hitSlab({x: 400, y: 400}, slabs, camera));
  });

  it('fits every slab inside the view', () => {
    const slabs = Model.slabsFrom(page(), 'z-index');
    const camera = Model.fittedCamera(slabs, 640, 420, Model.orbitCamera());
    for (const slab of slabs) {
      for (const corner of Model.quad(slab.bounds, slab.level, camera)) {
        assert.isAtLeast(corner.x, -0.5);
        assert.isAtMost(corner.x, 640.5);
        assert.isAtLeast(corner.y, -0.5);
        assert.isAtMost(corner.y, 420.5);
      }
    }
  });

  it('reads a box model and computed style into a named element', () => {
    const document = {
      root: {
        nodeId: 1,
        nodeType: 9,
        nodeName: '#document',
        children: [{
          nodeId: 2,
          nodeType: 1,
          nodeName: 'HTML',
          children: [
            {nodeId: 3, nodeType: 1, nodeName: 'HEAD', children: [{nodeId: 4, nodeType: 1, nodeName: 'STYLE'}]},
            {
              nodeId: 5,
              nodeType: 1,
              nodeName: 'BODY',
              children: [{
                nodeId: 6,
                nodeType: 1,
                nodeName: 'DIV',
                backendNodeId: 60,
                attributes: ['id', 'modal', 'class', 'panel open'],
              }],
            },
          ],
        }],
      },
    };
    const boxes = new Map<number, {model?: Stacking.StackingModel.ProtocolBoxModel}>([
      [2, {model: {border: quad(0, 0, 800, 600)}}],
      [5, {model: {border: quad(0, 0, 800, 600)}}],
      [6, {model: {border: quad(40, 50, 180, 120)}}],
    ]);
    const styles = new Map<number, Stacking.StackingModel.ProtocolComputedStyle>([
      [2, computed({'display': 'block', 'position': 'static'})],
      [5, computed({'display': 'block', 'position': 'static'})],
      [6, computed({'display': 'block', 'position': 'absolute', 'z-index': '10', 'opacity': '1'})],
    ]);
    const snapshot = Model.elementsFromDocument(document, boxes, styles);
    assert.deepEqual(snapshot.elements.map(item => item.name), ['html', 'body', 'div#modal.panel.open']);
    const modal = snapshot.elements[2];
    assert.strictEqual(modal?.parentDisplay, 'block');
    assert.strictEqual(modal?.backendNodeId, 60);
    assert.deepEqual(modal?.bounds, {x: 40, y: 50, width: 180, height: 120});
    const slabs = Model.slabsFrom(snapshot.elements, 'z-index');
    assert.strictEqual(slabs.find(slab => slab.nodeId === 6)?.zIndex, 10);
    assert.isTrue(slabs.find(slab => slab.nodeId === 6)?.createsContext);
    assert.isFalse(snapshot.clipped);
  });

  it('keeps the first 180 elements and marks the rest clipped', () => {
    const children = [];
    for (let nodeId = 3; nodeId <= 202; nodeId++) {
      children.push({nodeId, nodeType: 1, nodeName: 'DIV'});
    }
    const snapshot = Model.elementsFromDocument({
      root: {
        nodeId: 1,
        nodeType: 9,
        nodeName: '#document',
        children: [{nodeId: 2, nodeType: 1, nodeName: 'HTML', children}],
      },
    }, new Map<number, {model?: Stacking.StackingModel.ProtocolBoxModel}>(), new Map());
    assert.strictEqual(snapshot.elements.length, Model.MAXIMUM_NODES);
    assert.strictEqual(snapshot.elements[0]?.name, 'html');
    assert.strictEqual(snapshot.elements[Model.MAXIMUM_NODES - 1]?.nodeId, 181);
    assert.isTrue(snapshot.clipped);
  });
});

function page(): Stacking.StackingModel.StackingElement[] {
  return [
    element(1, 'html', {bounds: {x: 0, y: 0, width: 800, height: 600}, depth: 0}),
    element(2, 'body', {parentId: 1, bounds: {x: 0, y: 0, width: 800, height: 600}, depth: 1}),
    element(3, 'div#page', {
      parentId: 2,
      bounds: {x: 0, y: 0, width: 400, height: 300},
      depth: 2,
      position: 'relative',
      zIndex: 'auto',
    }),
    element(4, 'div#behind', {
      parentId: 3,
      bounds: {x: 20, y: 20, width: 160, height: 80},
      depth: 3,
      position: 'absolute',
      zIndex: '-1',
    }),
    element(5, 'div#card', {
      parentId: 3,
      bounds: {x: 40, y: 40, width: 200, height: 120},
      depth: 3,
      position: 'absolute',
      zIndex: 'auto',
    }),
    element(6, 'div#modal', {
      parentId: 3,
      bounds: {x: 80, y: 70, width: 180, height: 100},
      depth: 3,
      position: 'absolute',
      zIndex: '10',
    }),
    element(7, 'div#faded', {
      parentId: 3,
      bounds: {x: 12, y: 180, width: 100, height: 40},
      depth: 3,
      opacity: '0.5',
    }),
  ];
}

function element(
    nodeId: number,
    name: string,
    fields: Partial<Stacking.StackingModel.StackingElement> & Partial<Stacking.StackingModel.StackingStyle> = {},
    ): Stacking.StackingModel.StackingElement {
  const style = Model.emptyStyle();
  style.position = fields.position ?? 'static';
  style.zIndex = fields.zIndex ?? 'auto';
  style.opacity = fields.opacity ?? '1';
  style.transform = fields.transform ?? 'none';
  style.filter = fields.filter ?? 'none';
  style.isolation = fields.isolation ?? 'auto';
  style.willChange = fields.willChange ?? 'auto';
  style.contain = fields.contain ?? 'none';
  style.mixBlendMode = fields.mixBlendMode ?? 'normal';
  style.display = 'block';
  return {
    nodeId,
    backendNodeId: fields.backendNodeId ?? null,
    parentId: fields.parentId ?? null,
    name,
    depth: fields.depth ?? 1,
    bounds: fields.bounds === undefined ? {x: 0, y: 0, width: 80, height: 40} : fields.bounds,
    style,
    parentDisplay: fields.parentDisplay ?? 'block',
  };
}

function quad(x: number, y: number, width: number, height: number): number[] {
  return [x, y, x + width, y, x + width, y + height, x, y + height];
}

function computed(values: Record<string, string>): Stacking.StackingModel.ProtocolComputedStyle {
  return {computedStyle: Object.entries(values).map(([name, value]) => ({name, value}))};
}
