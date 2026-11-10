// Copyright 2026 The Shaar Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import * as Common from '../../../core/common/common.js';
import * as SDK from '../../../core/sdk/sdk.js';
import type * as Protocol from '../../../generated/protocol.js';

import {
  type ElementBudget,
  elementsFromDocument,
  type ProtocolComputedStyle,
  type ProtocolNode,
  retainElement,
  type StackingSnapshot,
} from './StackingModel.js';

export class StackingCaptureError extends Error {
  readonly code: 'no-page'|'empty';

  constructor(code: 'no-page'|'empty') {
    super(code);
    this.code = code;
  }
}

/**
 * Reads the document the Elements panel already holds.
 * A second DOM.getDocument drops frontend node ids, so this expands with
 * requestChildNodes and then calls DOM.getBoxModel and CSS.getComputedStyleForNode.
 */
export async function collectFromInspectedPage(): Promise<StackingSnapshot> {
  const target = SDK.TargetManager.TargetManager.instance().primaryPageTarget();
  const domModel = target?.model(SDK.DOMModel.DOMModel) ?? null;
  const cssModel = target?.model(SDK.CSSModel.CSSModel) ?? null;
  if (!target || !domModel || !cssModel) {
    throw new StackingCaptureError('no-page');
  }
  const document = await domModel.requestDocument();
  if (!document) {
    throw new StackingCaptureError('empty');
  }
  const subtree = await document.getSubtree(12, false);
  if (!subtree) {
    throw new StackingCaptureError('empty');
  }
  return await snapshotFromDom(document, cssModel);
}

export async function revealInElements(nodeId: number, backendNodeId: number|null): Promise<boolean> {
  const target = SDK.TargetManager.TargetManager.instance().primaryPageTarget();
  if (!target) {
    return false;
  }
  const domModel = target.model(SDK.DOMModel.DOMModel);
  const direct = domModel?.nodeForId(nodeId as Protocol.DOM.NodeId) ?? null;
  const node = direct ?? await resolveBackend(target, backendNodeId);
  if (!node) {
    return false;
  }
  node.highlight();
  await Common.Revealer.reveal(node);
  return true;
}

export function hideInspectedHighlight(): void {
  SDK.OverlayModel.OverlayModel.hideDOMNodeHighlight(SDK.TargetManager.TargetManager.instance());
}

async function snapshotFromDom(root: SDK.DOMModel.DOMNode, cssModel: SDK.CSSModel.CSSModel):
    Promise<StackingSnapshot> {
  const budget: ElementBudget = {ids: new Set(), clipped: false};
  const kept: SDK.DOMModel.DOMNode[] = [];
  const protocol = domToProtocol(root, null, false, budget, kept);
  if (!protocol) {
    return {elements: [], clipped: budget.clipped};
  }
  const details = await readNodeMeasurements(
      kept,
      node => node.boxModel(),
      node => cssModel.getComputedStyle(node.id));
  const boxes = new Map<number, {model?: {border?: number[], content?: number[]}}>();
  const styles = new Map<number, ProtocolComputedStyle>();
  for (const detail of details) {
    const {node, model, computed} = detail;
    if (model) {
      boxes.set(node.id, {model: {border: model.border, content: model.content}});
    }
    styles.set(node.id, computedStyleReply(computed));
  }
  const snapshot = elementsFromDocument({root: protocol}, boxes, styles);
  return {elements: snapshot.elements, clipped: budget.clipped || snapshot.clipped};
}

export async function readNodeMeasurements<T, Box, Style>(
    nodes: T[], readBox: (node: T) => Promise<Box>, readStyle: (node: T) => Promise<Style>):
    Promise<Array<{node: T, model: Box, computed: Style}>> {
  const measurements: Array<{node: T, model: Box, computed: Style}> = [];
  const batchSize = 16;
  for (let start = 0; start < nodes.length; start += batchSize) {
    const batch = nodes.slice(start, start + batchSize);
    const results = await Promise.all(batch.map(async node => {
      const [model, computed] = await Promise.all([readBox(node), readStyle(node)]);
      return {node, model, computed};
    }));
    measurements.push(...results);
  }
  return measurements;
}

function computedStyleReply(computed: Map<string, string>|null): ProtocolComputedStyle {
  if (!computed) {
    return {computedStyle: []};
  }
  const computedStyle: Array<{name: string, value: string}> = [];
  for (const [name, value] of computed) {
    computedStyle.push({name, value});
  }
  return {computedStyle};
}

function domToProtocol(
    node: SDK.DOMModel.DOMNode, parentId: number|null, parentIsElement: boolean, budget: ElementBudget,
    kept: SDK.DOMModel.DOMNode[]): ProtocolNode|null {
  if (budget.clipped) {
    return null;
  }
  const nodeId = node.id;
  const nodeType = node.nodeType();
  const nodeName = node.nodeName();
  const isElement = nodeType === 1 && nodeId > 0;
  const retained = retainElement(nodeId, nodeType, nodeName, parentId, parentIsElement, budget);
  if (isElement && !retained) {
    return null;
  }
  if (retained) {
    kept.push(node);
  }
  const childParent = isElement ? nodeId : parentId;
  const childParentIsElement = isElement ? true : parentIsElement;
  const children: ProtocolNode[] = [];
  for (const child of node.children() ?? []) {
    if (budget.clipped) {
      break;
    }
    const converted = domToProtocol(child, childParent, childParentIsElement, budget, kept);
    if (converted) {
      children.push(converted);
    }
  }
  let contentDocument: ProtocolNode|undefined;
  const content = node.contentDocument();
  if (content && !budget.clipped) {
    const converted = domToProtocol(content, childParent, childParentIsElement, budget, kept);
    if (converted) {
      contentDocument = converted;
    }
  }
  const attributes: string[] = [];
  const identifier = node.getAttribute('id');
  const className = node.getAttribute('class');
  if (identifier !== undefined) {
    attributes.push('id', identifier);
  }
  if (className !== undefined) {
    attributes.push('class', className);
  }
  return {
    nodeId,
    backendNodeId: node.backendNodeId(),
    nodeType,
    nodeName,
    attributes,
    children,
    contentDocument,
  };
}

async function resolveBackend(target: SDK.Target.Target, backendNodeId: number|null):
    Promise<SDK.DOMModel.DOMNode|null> {
  if (backendNodeId === null || backendNodeId <= 0) {
    return null;
  }
  const deferred = new SDK.DOMModel.DeferredDOMNode(target, backendNodeId as Protocol.DOM.BackendNodeId);
  return await deferred.resolvePromise();
}
