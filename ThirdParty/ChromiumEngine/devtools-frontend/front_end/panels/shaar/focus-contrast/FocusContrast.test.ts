// Copyright 2026 The Shaar Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import {assert} from 'chai';

import * as Focus from './focus-contrast.js';

const Contrast = Focus.FocusContrast;

describe('FocusContrast', () => {
  it('puts a positive tabindex ahead of document order', () => {
    const names = Contrast.orderFocusStops([
                     stop(1, 0, 0, 'First'),
                     stop(2, 2, 1, 'Later'),
                     stop(3, -1, 2, 'Skipped'),
                     stop(4, 1, 3, 'Priority'),
                     stop(5, 0, 4, 'Second'),
                   ]).map(item => item.name);
    assert.deepEqual(names, ['Priority', 'Later', 'First', 'Second']);
  });

  it('fails gray on white and lets large text pass', () => {
    const white = {backgroundColors: ['rgb(255, 255, 255)']};
    const normal = Contrast.decideContrast(style('rgb(119, 119, 119)', '16px', '400'), white);
    const large = Contrast.decideContrast(style('rgb(119, 119, 119)', '24px', '400'), white);
    const bold = Contrast.decideContrast(style('rgb(119, 119, 119)', '18.66px', 'bold'), white);
    const almost = Contrast.decideContrast(style('rgb(119, 119, 119)', '18.5px', '700'), white);
    const ink = Contrast.decideContrast(style('rgb(17, 17, 17)', '16px', '400'), white);
    const boundary = Contrast.decideContrast(style('rgb(118, 118, 118)', '16px', '400'), white);
    assert.isNotNull(normal);
    assert.isTrue(normal?.fails);
    assert.isFalse(normal?.largeText);
    assert.isAbove(normal?.ratio ?? 0, 4);
    assert.isBelow(normal?.ratio ?? 0, 4.5);
    assert.strictEqual(Contrast.ratioText(normal?.ratio ?? 0), '4.48');
    assert.isFalse(large?.fails);
    assert.isTrue(large?.largeText);
    assert.isFalse(bold?.fails);
    assert.isTrue(bold?.largeText);
    assert.isFalse(Contrast.isLargeText(18.5, 700));
    assert.isTrue(Contrast.isLargeText(Contrast.LARGE_BOLD_PX, 700));
    assert.isTrue(almost?.fails);
    assert.isFalse(almost?.largeText);
    assert.isFalse(ink?.fails);
    assert.isFalse(boundary?.fails);
  });

  it('parses hex and slash colors the same as commas', () => {
    const white = {backgroundColors: ['rgb(255, 255, 255)']};
    const comma = Contrast.decideContrast(style('rgb(119, 119, 119)', '16px', '400'), white);
    const slash = Contrast.decideContrast(style('rgb(119 119 119 / 1)', '16px', '400'), white);
    const hex = Contrast.decideContrast(style('#777777', '16px', '400'), white);
    assert.strictEqual(Contrast.ratioText(slash?.ratio ?? 0), Contrast.ratioText(comma?.ratio ?? 0));
    assert.strictEqual(Contrast.ratioText(hex?.ratio ?? 0), '4.48');
  });

  it('does not score a gradient or a transparent background', () => {
    const gray = style('rgb(119, 119, 119)', '16px', '400');
    assert.isNull(Contrast.decideContrast(gray, {backgroundColors: []}));
    assert.isNull(Contrast.decideContrast(gray, {backgroundColors: ['linear-gradient(white, black)']}));
    assert.isNull(Contrast.decideContrast(gray, {backgroundColors: ['rgba(0, 0, 0, 0)']}));
    assert.isNotNull(Contrast.decideContrast(gray, {backgroundColors: ['rgba(255, 255, 255, 0.5)', 'rgb(0, 0, 0)']}));
  });

  it('walks shadow roots and frame documents for markers', () => {
    const index = Contrast.walkDom({
      nodeId: 1,
      children: [
        {nodeId: 2, backendNodeId: 20, attributes: ['data-shaar-focus', '4']},
        {
          nodeId: 3,
          shadowRoots: [{
            nodeId: 4,
            attributes: ['data-shaar-contrast', '9', 'class', 'card'],
          }],
        },
      ],
      contentDocument: {nodeId: 8, attributes: ['data-shaar-focus', '1']},
    });
    assert.strictEqual(index.focus.get(4), 2);
    assert.strictEqual(index.contrast.get(9), 4);
    assert.strictEqual(index.focus.get(1), 8);
    assert.strictEqual(index.backend.get(2), 20);
    const odd = Contrast.walkDom({nodeId: 5, attributes: ['data-shaar-focus']});
    assert.strictEqual(odd.focus.size, 0);
  });

  it('decodes a page listing', () => {
    const inventory = Contrast.decodeInventory({
      scrollX: 0,
      scrollY: 3,
      truncated: true,
      stops: [{id: 1, tabIndex: 1, documentOrder: 0, name: 'Priority', x: 8, y: 12}],
      texts: [{id: 1, snippet: 'Low contrast', x: 8, y: 40}],
    });
    assert.strictEqual(inventory?.stops[0].name, 'Priority');
    assert.strictEqual(inventory?.stops[0].tabIndex, 1);
    assert.strictEqual(inventory?.texts[0].snippet, 'Low contrast');
    assert.strictEqual(inventory?.texts[0].origin.y, 40);
    assert.strictEqual(inventory?.scrollY, 3);
    assert.isTrue(inventory?.truncated);
    assert.isNull(Contrast.decodeInventory('nope'));
  });

  it('subtracts scroll from the box-model origin', () => {
    const origin = Contrast.viewportOrigin({model: {border: [30, 50, 80, 50, 80, 70, 30, 70]}}, 10, 20);
    assert.deepEqual(origin, {x: 20, y: 30});
  });

  it('reads an accessible name from the full tree', () => {
    const tree = {nodes: [{backendDOMNodeId: 20, name: {value: '  Priority control  '}}]};
    assert.strictEqual(Contrast.accessibleName(tree, 20), 'Priority control');
    assert.isNull(Contrast.accessibleName(tree, 21));
  });

  it('places numbers above the control and the ratio after the text', () => {
    assert.deepEqual(Contrast.badgePosition('focus', {left: 10, top: 30}, null, null), {left: 10, top: 10});
    assert.deepEqual(Contrast.badgePosition('contrast', {left: 10, top: 30}, 48, 58), {left: 64, top: 30});
    assert.deepEqual(Contrast.badgePosition('contrast', {left: 10, top: 30}, 0, 200), {left: 16, top: 30});
  });

  it('moves the keyboard through one list', () => {
    assert.strictEqual(Contrast.nextRowIndex(3, 0, 'ArrowDown'), 1);
    assert.strictEqual(Contrast.nextRowIndex(3, 2, 'ArrowDown'), 2);
    assert.strictEqual(Contrast.nextRowIndex(3, 0, 'ArrowUp'), 0);
    assert.strictEqual(Contrast.nextRowIndex(3, 2, 'Home'), 0);
    assert.strictEqual(Contrast.nextRowIndex(3, 0, 'End'), 2);
    assert.isNull(Contrast.nextRowIndex(3, 1, 'Enter'));
  });

  it('keeps the page script on the text bounds', () => {
    assert.include(Contrast.COLLECT_EXPRESSION, String.raw`/\s+/g`);
    assert.include(Contrast.COLLECT_EXPRESSION, 'selectNodeContents');
    assert.include(Contrast.COLLECT_EXPRESSION, 'maxNodes = 2000');
    assert.strictEqual(Contrast.COLLECT_EXPRESSION.split('getComputedStyle').length - 1, 1);
    assert.doesNotThrow(() => new Function(`return ${Contrast.COLLECT_EXPRESSION}`));
    assert.include(Contrast.COLLECT_EXPRESSION, 'y - 20');
    assert.include(Contrast.COLLECT_EXPRESSION, 'right + 6');
    assert.notInclude(Contrast.COLLECT_EXPRESSION, '__shaarA11yOverlay.paint');
    const expression = Contrast.paintExpression([{
      kind: 'focus',
      label: '1',
      marker: '4',
      snippet: 'Priority',
      x: 8,
      y: 12,
      nodeId: 2,
    }]);
    assert.include(expression ?? '', '__shaarA11yOverlay.paint');
    assert.include(expression ?? '', '"label":"1"');
    assert.notInclude(expression ?? '', 'nodeId');
  });

  it('counts one failure in the singular', () => {
    assert.strictEqual(Contrast.summaryText(2, 1, 0, false), '2 tab stops · 1 contrast failure');
    assert.notInclude(Contrast.summaryText(2, 1, 0, false), 'failures');
    assert.strictEqual(
        Contrast.summaryText(1, 0, 2, true),
        '1 tab stop · 0 contrast failures · 2 not scored · list limited');
  });

  it('paints numbered stops and the failing pair', async () => {
    const caller = new FixtureCaller();
    const result = await Contrast.refreshFocusContrast(caller, () => true);
    assert.isNull(result.failure);
    assert.deepEqual(result.badges.map(badge => badge.kind), ['focus', 'focus', 'contrast']);
    assert.deepEqual(result.badges.map(badge => badge.label), ['1', '2', '4.48']);
    assert.deepEqual(result.badges.map(badge => badge.snippet), ['Priority control', 'First', 'Low contrast']);
    assert.strictEqual(result.summary, '2 tab stops · 1 contrast failure');
    assert.notInclude(result.summary, 'failures');
    assert.isTrue(result.trace.boxModel);
    assert.isTrue(result.trace.backgroundColors);
    assert.isTrue(result.trace.axNames);
    assert.isTrue(result.trace.computedStyle);
    assert.deepEqual(caller.nameIds, [[20, 21]]);
    assert.notInclude(caller.methods, 'DOM.enable');
    assert.notInclude(caller.methods, 'CSS.enable');
    assert.notInclude(caller.methods, 'DOM.getDocument');
    assert.notInclude(caller.methods, 'Accessibility.getFullAXTree');
    assert.notInclude(caller.methods, 'CSS.getComputedStyleForNode');
    assert.include(caller.methods, 'DOM.getBoxModel');
    assert.include(caller.methods, 'CSS.getBackgroundColors');
    assert.notInclude(result.badges.map(badge => badge.snippet), 'High contrast');
  });

  it('stops walking the elements tree at 2000 nodes', () => {
    const children = [];
    for (let index = 0; index < Contrast.MAX_WALK_NODES; index++) {
      children.push({
        nodeId: index + 2,
        attributes: index === Contrast.MAX_WALK_NODES - 1 ? ['data-shaar-focus', '9'] : [],
      });
    }
    const index = Contrast.walkDom({nodeId: 1, children});
    assert.isFalse(index.focus.has(9));
  });

  it('keeps the page name when the elements tree has not loaded the stop', async () => {
    const caller = new FixtureCaller();
    caller.tree = {nodeId: 1};
    caller.inventory = {
      scrollX: 0,
      scrollY: 0,
      truncated: false,
      stops: [{id: 1, tabIndex: 0, documentOrder: 0, name: 'Priority', x: 8, y: 12}],
      texts: [{
        id: 1,
        snippet: 'Low contrast',
        x: 8,
        y: 40,
        color: 'rgb(119, 119, 119)',
        fontSize: '16px',
        fontWeight: '400',
      }],
    };
    const result = await Contrast.refreshFocusContrast(caller, () => true);
    assert.isNull(result.failure);
    assert.strictEqual(result.badges.length, 1);
    assert.strictEqual(result.badges[0].snippet, 'Priority');
    assert.include(result.summary, '1 tab stop');
    assert.include(result.summary, '1 not scored');
    assert.deepEqual(caller.nameIds, []);
    assert.notInclude(caller.methods, 'DOM.performSearch');
    assert.notInclude(caller.methods, 'DOM.getDocument');
  });

  it('clears a paint that finished after the overlay was turned off', async () => {
    const caller = new FixtureCaller();
    let painted = false;
    const original = caller.evaluate.bind(caller);
    caller.evaluate = async (expression: string) => {
      if (expression.includes('__shaarA11yOverlay.paint')) {
        painted = true;
      }
      return await original(expression);
    };
    const result = await Contrast.refreshFocusContrast(caller, () => !painted);
    assert.isTrue(painted);
    assert.isTrue(result.cancelled);
    assert.isTrue(caller.expressions.some(expression => expression.includes('__shaarA11yOverlay.clear')));
  });

  it('stops before painting when the overlay is already off', async () => {
    const caller = new FixtureCaller();
    const result = await Contrast.refreshFocusContrast(caller, () => false);
    assert.isTrue(result.cancelled);
    assert.deepEqual(caller.expressions, []);
  });

  it('reports a page that did not list its tab stops', async () => {
    const caller = new FixtureCaller();
    caller.inventory = null;
    const result = await Contrast.refreshFocusContrast(caller, () => true);
    assert.strictEqual(result.failure, Contrast.NO_STOPS);
  });
});

function stop(id: number, tabIndex: number, order: number, name: string): Focus.FocusContrast.FocusStop {
  return {id, tabIndex, documentOrder: order, name, origin: {x: 0, y: 0}};
}

function style(color: string, size: string, weight: string): {computedStyle: Array<{name: string, value: string}>} {
  return {
    computedStyle: [
      {name: 'color', value: color},
      {name: 'font-size', value: size},
      {name: 'font-weight', value: weight},
    ],
  };
}

class FixtureCaller implements Focus.FocusContrast.FocusContrastCaller {
  methods: string[] = [];
  expressions: string[] = [];
  nameIds: number[][] = [];
  tree: unknown = walkedDocument();
  inventory: unknown = {
    scrollX: 0,
    scrollY: 0,
    truncated: false,
    stops: [
      {id: 1, tabIndex: 1, documentOrder: 0, name: 'Priority', x: 8, y: 12},
      {id: 2, tabIndex: 0, documentOrder: 1, name: 'First', x: 40, y: 12},
      {id: 3, tabIndex: -1, documentOrder: 2, name: 'Minus', x: 80, y: 12},
    ],
    texts: [
      {
        id: 1,
        snippet: 'Low contrast',
        x: 8,
        y: 40,
        color: 'rgb(119, 119, 119)',
        fontSize: '16px',
        fontWeight: '400',
      },
      {
        id: 2,
        snippet: 'High contrast',
        x: 8,
        y: 70,
        color: 'rgb(17, 17, 17)',
        fontSize: '16px',
        fontWeight: '400',
      },
    ],
  };

  async evaluate(expression: string): Promise<unknown> {
    this.expressions.push(expression);
    if (expression.includes('__shaarA11yOverlay.paint') || expression.includes('__shaarA11yOverlay.clear')) {
      return true;
    }
    return this.inventory;
  }

  async elementsTree(): Promise<unknown> {
    return this.tree;
  }

  async accessibleNames(backendNodeIds: number[]): Promise<Map<number, string>> {
    this.nameIds.push(backendNodeIds);
    const names = new Map<number, string>();
    if (backendNodeIds.includes(20)) {
      names.set(20, 'Priority control');
    }
    return names;
  }

  async call(method: string, params: Record<string, unknown>): Promise<Record<string, unknown>> {
    void params;
    this.methods.push(method);
    if (method === 'DOM.getBoxModel') {
      return {model: {border: [8, 12, 40, 12, 40, 28, 8, 28]}};
    }
    if (method === 'CSS.getBackgroundColors') {
      return {backgroundColors: ['rgb(255, 255, 255)']};
    }
    return {};
  }
}

function walkedDocument(): Record<string, unknown> {
  return {
    nodeId: 1,
    children: [
      {nodeId: 2, backendNodeId: 20, attributes: ['data-shaar-focus', '1']},
      {nodeId: 3, backendNodeId: 21, attributes: ['data-shaar-focus', '2']},
      {nodeId: 4, backendNodeId: 22, attributes: ['data-shaar-contrast', '1']},
      {nodeId: 5, backendNodeId: 23, attributes: ['data-shaar-contrast', '2']},
    ],
  };
}
