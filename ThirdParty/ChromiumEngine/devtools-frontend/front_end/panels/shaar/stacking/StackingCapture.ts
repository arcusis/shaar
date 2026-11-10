// Copyright 2026 The Shaar Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import * as Common from '../../../core/common/common.js';
import * as SDK from '../../../core/sdk/sdk.js';
import type * as Protocol from '../../../generated/protocol.js';

import {
  elementsFromDocument,
  MAXIMUM_NODES,
  type ProtocolComputedStyle,
  type ProtocolDocument,
  type ProtocolNode,
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

async function snapshotFromDom(root: SDK.DOMModel.DOMNode, cssModel: SDK.CSSModel.CSSModel):
    Promise<StackingSnapshot> {
  const protocol = domToProtocol(root);
  const document: ProtocolDocument = {root: protocol};
  const preliminary = elementsFromDocument(document, new Map(), new Map());
  const boxes = new Map<number, {model?: {border?: number[], content?: number[]}}>();
  const styles = new Map<number, ProtocolComputedStyle>();
  const byId = indexNodes(root);
  const kept = preliminary.elements.slice(0, MAXIMUM_NODES);
  for (const element of kept) {
    const node = byId.get(element.nodeId);
    if (!node) {
      continue;
    }
    const model = await node.boxModel();
    if (model) {
      boxes.set(element.nodeId, {model: {border: model.border, content: model.content}});
    }
    const computed = await cssModel.getComputedStyle(node.id);
    styles.set(element.nodeId, computedStyleReply(computed));
  }
  const snapshot = elementsFromDocument(document, boxes, styles);
  return {elements: snapshot.elements, clipped: preliminary.clipped || snapshot.clipped};
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

function indexNodes(root: SDK.DOMModel.DOMNode): Map<number, SDK.DOMModel.DOMNode> {
  const byId = new Map<number, SDK.DOMModel.DOMNode>();
  const visit = (node: SDK.DOMModel.DOMNode): void => {
    byId.set(node.id, node);
    for (const child of node.children() ?? []) {
      visit(child);
    }
    const content = node.contentDocument();
    if (content) {
      visit(content);
    }
  };
  visit(root);
  return byId;
}

function domToProtocol(node: SDK.DOMModel.DOMNode): ProtocolNode {
  const attributes: string[] = [];
  const identifier = node.getAttribute('id');
  const className = node.getAttribute('class');
  if (identifier !== undefined) {
    attributes.push('id', identifier);
  }
  if (className !== undefined) {
    attributes.push('class', className);
  }
  const content = node.contentDocument();
  return {
    nodeId: node.id,
    backendNodeId: node.backendNodeId(),
    nodeType: node.nodeType(),
    nodeName: node.nodeName(),
    attributes,
    children: (node.children() ?? []).map(child => domToProtocol(child)),
    contentDocument: content ? domToProtocol(content) : undefined,
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
