// Copyright 2026 The Shaar Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import * as SDK from '../../../core/sdk/sdk.js';
import * as Protocol from '../../../generated/protocol.js';
import * as UI from '../../../ui/legacy/legacy.js';

import {
  buildPacket,
  LIMITS,
  pngBytes,
  type Packet,
  type PacketRequestInput,
  type PacketScope,
  type PageStamp,
} from './AgentPacket.js';

const OBJECT_GROUP = 'shaar-agent-copy';

export class AgentPacketCollectError extends Error {
  readonly code: 'no-page'|'no-selection';

  constructor(code: 'no-page'|'no-selection') {
    super(code);
    this.name = 'AgentPacketCollectError';
    this.code = code;
  }
}

export interface CollectedAgentPacket {
  packet: Packet;
  stamp: PageStamp;
  pngBase64: string;
}

export function readPageStamp(target?: SDK.Target.Target|null): PageStamp|null {
  const resolved = target === undefined ? SDK.TargetManager.TargetManager.instance().primaryPageTarget() : target;
  if (!resolved) {
    return null;
  }
  const frame = resolved.model(SDK.ResourceTreeModel.ResourceTreeModel)?.mainFrame ?? null;
  return {
    url: String(frame?.url || resolved.inspectedURL() || ''),
    loaderId: String(frame?.loaderId || ''),
  };
}

export async function collectAgentPacket(scope: PacketScope): Promise<CollectedAgentPacket> {
  const stamp = readPageStamp();
  const target = SDK.TargetManager.TargetManager.instance().primaryPageTarget();
  if (!stamp || !target) {
    throw new AgentPacketCollectError('no-page');
  }
  const node = scope === 'element' ? selectedElement() : await pageElement(target);
  if (!node) {
    throw new AgentPacketCollectError(scope === 'element' ? 'no-selection' : 'no-page');
  }

  const html = await node.getOuterHTML().catch(() => null);
  if (html == null) {
    throw new AgentPacketCollectError('no-page');
  }
  const nodeTarget = node.domModel().target();
  const source = await sourceLocation(node);
  const styles = await matchedStyles(node);
  const consoleModel = nodeTarget.model(SDK.ConsoleModel.ConsoleModel);
  const pngBase64 = await capture(node, scope);
  const screenshotBytes = pngBytes(pngBase64);
  const packet = buildPacket({
    page: {
      scope,
      url: stamp.url,
      html,
      source,
      consoleRecording: Boolean(consoleModel),
      consoleErrors: consoleErrors(consoleModel),
      failedRequests: await failedRequests(nodeTarget),
    },
    matchedStyles: styles.matched,
    stylesOmitted: styles.omitted,
    screenshotBytes,
  });
  return {packet, stamp, pngBase64: screenshotBytes > 0 ? pngBase64 : ''};
}

function selectedElement(): SDK.DOMModel.DOMNode|null {
  const flavored = UI.Context.Context.instance().flavor(SDK.DOMModel.DOMNode);
  let current: SDK.DOMModel.DOMNode|null = flavored;
  while (current && current.nodeType() !== SDK.DOMModel.NodeType.ELEMENT_NODE) {
    current = current.parentNode;
  }
  return current;
}

async function pageElement(target: SDK.Target.Target): Promise<SDK.DOMModel.DOMNode|null> {
  const document = await target.model(SDK.DOMModel.DOMModel)?.requestDocument() ?? null;
  return document?.documentElement ?? null;
}

async function matchedStyles(node: SDK.DOMModel.DOMNode): Promise<{matched: unknown, omitted: boolean}> {
  try {
    const cssModel = node.domModel().cssModel();
    const response = await cssModel.agent.invoke_getMatchedStylesForNode({nodeId: node.id});
    if (response.getError()) {
      return {matched: null, omitted: true};
    }
    return {matched: response, omitted: false};
  } catch {
    return {matched: null, omitted: true};
  }
}

function consoleErrors(model: SDK.ConsoleModel.ConsoleModel|null): string[] {
  if (!model) {
    return [];
  }
  const errors: string[] = [];
  for (const message of model.messages()) {
    if (message.level !== Protocol.Log.LogEntryLevel.Error || !message.messageText) {
      continue;
    }
    errors.push(message.messageText);
  }
  return errors.slice(-LIMITS.errors);
}

// The network log is a DevTools module. Its GN target is not visible to
// Shaar panels, so the collector loads the module when it builds a packet.
async function recordedRequests(): Promise<SDK.NetworkRequest.NetworkRequest[]> {
  try {
    const specifier: string = '../../../models/logs/logs.js';
    const logs = await import(specifier) as {
      NetworkLog: {NetworkLog: {instance(): {requests(): SDK.NetworkRequest.NetworkRequest[]}}},
    };
    return logs.NetworkLog.NetworkLog.instance().requests();
  } catch {
    return [];
  }
}

async function failedRequests(target: SDK.Target.Target): Promise<PacketRequestInput[]> {
  const rows: PacketRequestInput[] = [];
  for (const request of await recordedRequests()) {
    if (SDK.NetworkManager.NetworkManager.forRequest(request)?.target() !== target) {
      continue;
    }
    const status = request.statusCode || 0;
    const error = request.failed ? (request.localizedFailDescription || 'failed') : '';
    if (status < 400 && !error) {
      continue;
    }
    rows.push({
      method: request.requestMethod || 'GET',
      url: request.url(),
      status,
      error,
      requestHeaders: request.requestHeaders().map(header => ({name: header.name, value: header.value})),
      responseHeaders: request.responseHeaders.map(header => ({name: header.name, value: header.value})),
    });
  }
  return rows.slice(-LIMITS.requests);
}

async function sourceLocation(node: SDK.DOMModel.DOMNode): Promise<string> {
  const marked = attributeSource(node);
  if (marked) {
    return marked;
  }
  return await reactSource(node);
}

function attributeSource(node: SDK.DOMModel.DOMNode): string {
  let current: SDK.DOMModel.DOMNode|null = node;
  for (let depth = 0; current && depth < 12; depth++) {
    const marked = current.getAttribute('data-source');
    if (marked) {
      return marked.slice(0, LIMITS.line);
    }
    current = current.parentNode;
  }
  return '';
}

async function reactSource(node: SDK.DOMModel.DOMNode): Promise<string> {
  const object = await node.resolveToObject(OBJECT_GROUP).catch(() => null);
  try {
    if (!object) {
      return '';
    }
    const located = await object.callFunctionJSON(reactSourceFunction, undefined);
    return typeof located === 'string' ? located.slice(0, LIMITS.line) : '';
  } catch {
    return '';
  } finally {
    object?.release();
    void node.domModel().target().runtimeAgent().invoke_releaseObjectGroup({objectGroup: OBJECT_GROUP});
  }
}

function reactSourceFunction(this: Element): string {
  const limit = 180;
  const sourceFile = (source: {fileName?: string, lineNumber?: number, line?: number}|null|undefined): string => {
    if (!source?.fileName) {
      return '';
    }
    const line = source.lineNumber || source.line || '';
    return String(source.fileName) + (line ? ':' + line : '');
  };
  let current: Element|null = this;
  for (let depth = 0; current && depth < 12; depth++) {
    const marked = current.getAttribute('data-source');
    if (marked) {
      return String(marked).slice(0, limit);
    }
    const record = current as unknown as Record<string, unknown>;
    for (const key of Object.keys(record)) {
      const fiberKey = key.startsWith('__reactFiber') || key.startsWith('__reactInternalInstance');
      if (!fiberKey) {
        continue;
      }
      let fiber = record[key] as {
        _debugSource?: {fileName?: string, lineNumber?: number, line?: number},
        __source?: {fileName?: string, lineNumber?: number, line?: number},
        return?: object,
        _debugOwner?: object,
      } | null;
      for (let hop = 0; fiber && hop < 12; hop++) {
        const located = sourceFile(fiber._debugSource) || sourceFile(fiber.__source);
        if (located) {
          return located.slice(0, limit);
        }
        fiber = (fiber.return || fiber._debugOwner) as typeof fiber;
      }
    }
    current = current.parentElement;
  }
  return '';
}

async function capture(node: SDK.DOMModel.DOMNode, scope: PacketScope): Promise<string> {
  try {
    const target = node.domModel().target();
    const model = target.model(SDK.ScreenCaptureModel.ScreenCaptureModel);
    if (!model) {
      return '';
    }
    if (scope === 'page') {
      const data = await model.captureScreenshot(
          Protocol.Page.CaptureScreenshotRequestFormat.Png, 100, SDK.ScreenCaptureModel.ScreenshotMode.FROM_VIEWPORT);
      return data || '';
    }
    const clip = await elementClip(node);
    if (!clip) {
      return '';
    }
    const data = await model.captureScreenshot(
        Protocol.Page.CaptureScreenshotRequestFormat.Png, 100, SDK.ScreenCaptureModel.ScreenshotMode.FROM_CLIP, clip);
    return data || '';
  } catch {
    return '';
  }
}

async function elementClip(node: SDK.DOMModel.DOMNode): Promise<Protocol.Page.Viewport|null> {
  const box = await node.boxModel();
  if (!box?.border?.length) {
    return null;
  }
  const bounds = quadBounds(box.border);
  const width = bounds.maxX - bounds.minX;
  const height = bounds.maxY - bounds.minY;
  if (!(width > 0) || !(height > 0)) {
    return null;
  }
  const metrics = await node.domModel().target().pageAgent().invoke_getLayoutMetrics();
  if (metrics.getError()) {
    return null;
  }
  const offset = await frameOffset(node.domModel().target());
  const zoom = metrics.cssVisualViewport.zoom ?? 1;
  return {
    x: (offset.x + metrics.cssVisualViewport.pageX + bounds.minX) * zoom,
    y: (offset.y + metrics.cssVisualViewport.pageY + bounds.minY) * zoom,
    width: width * zoom,
    height: height * zoom,
    scale: 1,
  };
}

function quadBounds(quad: number[]): {minX: number, minY: number, maxX: number, maxY: number} {
  let minX = Infinity;
  let minY = Infinity;
  let maxX = -Infinity;
  let maxY = -Infinity;
  for (let index = 0; index + 1 < quad.length; index += 2) {
    minX = Math.min(minX, quad[index]);
    maxX = Math.max(maxX, quad[index]);
    minY = Math.min(minY, quad[index + 1]);
    maxY = Math.max(maxY, quad[index + 1]);
  }
  return {minX, minY, maxX, maxY};
}

async function frameOffset(target: SDK.Target.Target|null): Promise<{x: number, y: number}> {
  if (!target) {
    return {x: 0, y: 0};
  }
  const parent = target.parentTarget();
  if (!parent || parent.type() !== SDK.Target.Type.FRAME) {
    return {x: 0, y: 0};
  }
  const frameId = target.model(SDK.ResourceTreeModel.ResourceTreeModel)?.mainFrame?.id;
  if (!frameId) {
    return {x: 0, y: 0};
  }
  const parentDOM = parent.model(SDK.DOMModel.DOMModel);
  const deferred = parentDOM ? await parentDOM.getOwnerNodeForFrame(frameId) : null;
  const owner = await deferred?.resolvePromise();
  const box = owner ? await owner.boxModel() : null;
  if (!box?.content?.length) {
    return {x: 0, y: 0};
  }
  const above = await frameOffset(parent);
  return {x: above.x + box.content[0], y: above.y + box.content[1]};
}
