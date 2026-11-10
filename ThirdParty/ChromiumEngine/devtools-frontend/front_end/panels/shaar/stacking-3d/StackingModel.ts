// Copyright 2026 The Shaar Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

export const DOM_STEP = 26;
export const Z_STEP = 34;
export const INNER_STEP = 7;
export const MAXIMUM_NODES = 180;

export const ORBIT_YAW = -0.65;
export const ORBIT_PITCH = 0.58;

const SKIPPED_TAGS = new Set([
  'SCRIPT',
  'STYLE',
  'LINK',
  'META',
  'TITLE',
  'NOSCRIPT',
  'TEMPLATE',
  'BR',
  'WBR',
  'HEAD',
]);

export type StackingMode = 'dom'|'z-index';

export interface Rect {
  x: number;
  y: number;
  width: number;
  height: number;
}

export interface StackingStyle {
  position: string;
  zIndex: string;
  opacity: string;
  transform: string;
  filter: string;
  perspective: string;
  mixBlendMode: string;
  isolation: string;
  willChange: string;
  contain: string;
  backdropFilter: string;
  clipPath: string;
  maskImage: string;
  display: string;
}

export interface StackingElement {
  nodeId: number;
  backendNodeId: number|null;
  parentId: number|null;
  name: string;
  depth: number;
  bounds: Rect|null;
  style: StackingStyle;
  parentDisplay: string;
}

export interface StackingSnapshot {
  elements: StackingElement[];
  clipped: boolean;
}

export interface StackingSlab {
  nodeId: number;
  name: string;
  depth: number;
  bounds: Rect;
  zIndex: number|null;
  createsContext: boolean;
  reasons: string[];
  level: number;
  paintOrder: number;
}

export interface StackingCamera {
  yaw: number;
  pitch: number;
  zoom: number;
  panX: number;
  panY: number;
}

export interface Point {
  x: number;
  y: number;
}

export interface ProtocolNode {
  nodeId?: number;
  backendNodeId?: number;
  nodeType?: number;
  nodeName?: string;
  attributes?: string[];
  children?: ProtocolNode[];
  contentDocument?: ProtocolNode;
}

export interface ProtocolDocument {
  root?: ProtocolNode;
}

export interface ProtocolBoxModel {
  border?: number[];
  content?: number[];
}

export interface ProtocolComputedStyle {
  computedStyle?: Array<{name?: string, value?: string}>;
}

export function orbitCamera(): StackingCamera {
  return {yaw: ORBIT_YAW, pitch: ORBIT_PITCH, zoom: 1, panX: 0, panY: 0};
}

export function emptyStyle(): StackingStyle {
  return {
    position: '',
    zIndex: '',
    opacity: '',
    transform: '',
    filter: '',
    perspective: '',
    mixBlendMode: '',
    isolation: '',
    willChange: '',
    contain: '',
    backdropFilter: '',
    clipPath: '',
    maskImage: '',
    display: '',
  };
}

export function reasonsFor(element: StackingElement, isRoot: boolean): string[] {
  if (isRoot) {
    return ['root'];
  }
  const reasons: string[] = [];
  const position = normalized(element.style.position);
  const zIndex = normalized(element.style.zIndex);
  const positioned = position === 'absolute' || position === 'relative';
  if (positioned && hasZIndex(zIndex)) {
    reasons.push(`z-index: ${element.style.zIndex}`);
  }
  if (position === 'fixed' || position === 'sticky') {
    reasons.push(`position: ${position}`);
    if (hasZIndex(zIndex)) {
      reasons.push(`z-index: ${element.style.zIndex}`);
    }
  }
  const parent = normalized(element.parentDisplay);
  if (flexOrGrid(parent) && hasZIndex(zIndex)) {
    reasons.push(`${parent} item z-index`);
  }
  if (opacityCreates(element.style.opacity)) {
    reasons.push(`opacity: ${element.style.opacity}`);
  }
  appendEffect('transform', element.style.transform, reasons);
  appendEffect('filter', element.style.filter, reasons);
  appendEffect('perspective', element.style.perspective, reasons);
  appendEffect('backdrop-filter', element.style.backdropFilter, reasons);
  appendEffect('clip-path', element.style.clipPath, reasons);
  appendEffect('mask', element.style.maskImage, reasons);
  const blend = normalized(element.style.mixBlendMode);
  if (blend.length > 0 && blend !== 'normal') {
    reasons.push('mix-blend-mode');
  }
  if (normalized(element.style.isolation) === 'isolate') {
    reasons.push('isolation');
  }
  if (willChangeCreates(element.style.willChange)) {
    reasons.push('will-change');
  }
  if (containCreates(element.style.contain)) {
    reasons.push('contain');
  }
  return reasons;
}

export function parsedZIndex(value: string): number|null {
  const text = normalized(value);
  if (text.length === 0 || text === 'auto') {
    return null;
  }
  const parsed = Number(text);
  if (!Number.isInteger(parsed)) {
    return null;
  }
  return parsed;
}

export function slabsFrom(elements: StackingElement[], mode: StackingMode): StackingSlab[] {
  const byId = new Map<number, StackingElement>();
  for (const element of elements) {
    byId.set(element.nodeId, element);
  }
  const children = childIds(elements);
  const roots = elements.filter(element => {
    if (element.parentId === null) {
      return true;
    }
    return !byId.has(element.parentId);
  });
  const built: StackingSlab[] = [];
  const order = {value: 0};
  for (const root of roots) {
    walkSlab(root.nodeId, 0, 0, true, children, byId, mode, order, built);
  }
  return built;
}

export function project(point: Point, level: number, camera: StackingCamera): Point {
  const cosYaw = Math.cos(camera.yaw);
  const sinYaw = Math.sin(camera.yaw);
  const cosPitch = Math.cos(camera.pitch);
  const sinPitch = Math.sin(camera.pitch);
  const turnedX = point.x * cosYaw + level * sinYaw;
  const turnedZ = -point.x * sinYaw + level * cosYaw;
  const turnedY = point.y * cosPitch - turnedZ * sinPitch;
  return {x: turnedX * camera.zoom + camera.panX, y: turnedY * camera.zoom + camera.panY};
}

export function quad(bounds: Rect, level: number, camera: StackingCamera): Point[] {
  return [
    project({x: bounds.x, y: bounds.y}, level, camera),
    project({x: bounds.x + bounds.width, y: bounds.y}, level, camera),
    project({x: bounds.x + bounds.width, y: bounds.y + bounds.height}, level, camera),
    project({x: bounds.x, y: bounds.y + bounds.height}, level, camera),
  ];
}

export function pointInQuad(point: Point, corners: Point[]): boolean {
  if (corners.length < 3) {
    return false;
  }
  let inside = false;
  let previous = corners[corners.length - 1];
  for (const corner of corners) {
    const crosses = (corner.y > point.y) !== (previous.y > point.y);
    if (crosses && previous.y !== corner.y) {
      const xCross = (previous.x - corner.x) * (point.y - corner.y) / (previous.y - corner.y) + corner.x;
      if (point.x < xCross) {
        inside = !inside;
      }
    }
    previous = corner;
  }
  return inside;
}

export function hitSlab(point: Point, slabs: StackingSlab[], camera: StackingCamera): StackingSlab|null {
  let best: StackingSlab|null = null;
  for (const slab of slabs) {
    const corners = quad(slab.bounds, slab.level, camera);
    if (!pointInQuad(point, corners)) {
      continue;
    }
    if (best === null) {
      best = slab;
      continue;
    }
    if (slab.level < best.level) {
      continue;
    }
    if (slab.level === best.level && slab.paintOrder < best.paintOrder) {
      continue;
    }
    best = slab;
  }
  return best;
}

export function fittedCamera(slabs: StackingSlab[], width: number, height: number, orbit: StackingCamera): StackingCamera {
  const camera = {...orbit, zoom: 1, panX: 0, panY: 0};
  let minX = Number.POSITIVE_INFINITY;
  let minY = Number.POSITIVE_INFINITY;
  let maxX = Number.NEGATIVE_INFINITY;
  let maxY = Number.NEGATIVE_INFINITY;
  let any = false;
  for (const slab of slabs) {
    for (const corner of quad(slab.bounds, slab.level, camera)) {
      any = true;
      minX = Math.min(minX, corner.x);
      minY = Math.min(minY, corner.y);
      maxX = Math.max(maxX, corner.x);
      maxY = Math.max(maxY, corner.y);
    }
  }
  if (!any || width <= 48 || height <= 48) {
    return orbit;
  }
  const padding = 24;
  const spanX = Math.max(maxX - minX, 1);
  const spanY = Math.max(maxY - minY, 1);
  const roomX = Math.max(width - padding * 2, 1);
  const roomY = Math.max(height - padding * 2, 1);
  const zoom = Math.min(roomX / spanX, roomY / spanY);
  camera.zoom = zoom;
  camera.panX = padding - minX * zoom + (roomX - spanX * zoom) / 2;
  camera.panY = padding - minY * zoom + (roomY - spanY * zoom) / 2;
  return camera;
}

export function elementsFromDocument(
    document: ProtocolDocument,
    boxes: Map<number, {model?: ProtocolBoxModel}>,
    styles: Map<number, ProtocolComputedStyle>,
    ): StackingSnapshot {
  const root = document.root;
  if (!root) {
    return {elements: [], clipped: false};
  }
  const flat: RawNode[] = [];
  flattenProtocol(root, null, false, 0, flat);
  const eligible = prefixNodes(flat, Number.MAX_SAFE_INTEGER);
  const kept = prefixNodes(flat, MAXIMUM_NODES);
  return {elements: elementsFromRaw(kept, boxes, styles), clipped: eligible.length > kept.length};
}

export function boundsFromQuad(quad: number[]|undefined): Rect|null {
  if (!quad || quad.length < 6) {
    return null;
  }
  const xs: number[] = [];
  const ys: number[] = [];
  for (let index = 0; index + 1 < quad.length; index += 2) {
    const x = quad[index];
    const y = quad[index + 1];
    if (typeof x !== 'number' || typeof y !== 'number') {
      continue;
    }
    xs.push(x);
    ys.push(y);
  }
  if (xs.length === 0 || ys.length === 0) {
    return null;
  }
  const minX = Math.min(...xs);
  const maxX = Math.max(...xs);
  const minY = Math.min(...ys);
  const maxY = Math.max(...ys);
  const rect = {x: minX, y: minY, width: maxX - minX, height: maxY - minY};
  if (rect.width < 1 || rect.height < 1) {
    return null;
  }
  return rect;
}

export function styleFromComputed(reply: ProtocolComputedStyle|undefined): StackingStyle {
  const values = new Map<string, string>();
  for (const row of reply?.computedStyle ?? []) {
    if (typeof row.name === 'string' && typeof row.value === 'string') {
      values.set(row.name, row.value);
    }
  }
  return styleFromMap(values);
}

export function styleFromMap(values: ReadonlyMap<string, string>): StackingStyle {
  const style = emptyStyle();
  style.position = values.get('position') ?? '';
  style.zIndex = values.get('z-index') ?? '';
  style.opacity = values.get('opacity') ?? '';
  style.transform = values.get('transform') ?? '';
  style.filter = values.get('filter') ?? '';
  style.perspective = values.get('perspective') ?? '';
  style.mixBlendMode = values.get('mix-blend-mode') ?? '';
  style.isolation = values.get('isolation') ?? '';
  style.willChange = values.get('will-change') ?? '';
  style.contain = values.get('contain') ?? '';
  style.backdropFilter = values.get('backdrop-filter') ?? '';
  style.clipPath = values.get('clip-path') ?? '';
  style.maskImage = values.get('mask-image') ?? '';
  style.display = values.get('display') ?? '';
  return style;
}

interface RawNode {
  nodeId: number;
  backendNodeId: number|null;
  parentId: number|null;
  parentIsElement: boolean;
  name: string;
  attributes: string[];
  depth: number;
}

function elementsFromRaw(
    nodes: RawNode[],
    boxes: Map<number, {model?: ProtocolBoxModel}>,
    styles: Map<number, ProtocolComputedStyle>,
    ): StackingElement[] {
  const built: StackingElement[] = [];
  for (const node of nodes) {
    const model = boxes.get(node.nodeId)?.model;
    const quadValues = model?.border ?? model?.content;
    built.push({
      nodeId: node.nodeId,
      backendNodeId: node.backendNodeId,
      parentId: node.parentId,
      name: labelFor(node),
      depth: node.depth,
      bounds: boundsFromQuad(quadValues),
      style: styleFromComputed(styles.get(node.nodeId)),
      parentDisplay: '',
    });
  }
  const displayById = new Map<number, string>();
  for (const element of built) {
    displayById.set(element.nodeId, element.style.display);
  }
  for (const element of built) {
    if (element.parentId === null) {
      continue;
    }
    element.parentDisplay = displayById.get(element.parentId) ?? '';
  }
  return built;
}

function flattenProtocol(
    node: ProtocolNode, parentId: number|null, parentIsElement: boolean, depth: number, into: RawNode[]): void {
  const type = integer(node.nodeType) ?? 0;
  const nodeId = integer(node.nodeId) ?? 0;
  const name = node.nodeName ?? '';
  const isElement = type === 1 && nodeId > 0;
  if (isElement && !SKIPPED_TAGS.has(name.toUpperCase())) {
    const backend = integer(node.backendNodeId) ?? 0;
    into.push({
      nodeId,
      backendNodeId: backend > 0 ? backend : null,
      parentId,
      parentIsElement,
      name,
      attributes: node.attributes ?? [],
      depth,
    });
  }
  const childParent = isElement ? nodeId : parentId;
  const childParentIsElement = isElement ? true : parentIsElement;
  const childDepth = isElement ? depth + 1 : depth;
  for (const child of node.children ?? []) {
    flattenProtocol(child, childParent, childParentIsElement, childDepth, into);
  }
  if (node.contentDocument) {
    flattenProtocol(node.contentDocument, childParent, childParentIsElement, childDepth, into);
  }
}

function prefixNodes(nodes: RawNode[], limit: number): RawNode[] {
  const kept: RawNode[] = [];
  const ids = new Set<number>();
  for (const node of nodes) {
    if (kept.length >= limit) {
      break;
    }
    if (node.parentIsElement && node.parentId !== null && !ids.has(node.parentId)) {
      continue;
    }
    kept.push(node);
    ids.add(node.nodeId);
  }
  return kept;
}

function labelFor(node: RawNode): string {
  let text = node.name.toLowerCase();
  let identifier = '';
  const classes: string[] = [];
  for (let index = 0; index + 1 < node.attributes.length; index += 2) {
    const key = node.attributes[index];
    const value = node.attributes[index + 1] ?? '';
    if (key === 'id' && value.length > 0) {
      identifier = value;
    }
    if (key === 'class') {
      for (const name of value.split(/\s+/)) {
        if (name.length > 0 && classes.length < 2) {
          classes.push(name);
        }
      }
    }
  }
  if (identifier.length > 0) {
    text += `#${identifier}`;
  }
  for (const name of classes) {
    text += `.${name}`;
  }
  return text;
}

function childIds(elements: StackingElement[]): Map<number, number[]> {
  const children = new Map<number, number[]>();
  for (const element of elements) {
    if (element.parentId === null) {
      continue;
    }
    const list = children.get(element.parentId) ?? [];
    list.push(element.nodeId);
    children.set(element.parentId, list);
  }
  return children;
}

function walkSlab(
    nodeId: number, parentContext: number, depthInContext: number, isRoot: boolean,
    children: Map<number, number[]>, byId: Map<number, StackingElement>, mode: StackingMode,
    order: {value: number}, slabs: StackingSlab[]): void {
  const element = byId.get(nodeId);
  if (!element) {
    return;
  }
  const reasons = reasonsFor(element, isRoot);
  const creates = reasons.length > 0;
  const zIndex = parsedZIndex(element.style.zIndex);
  const level = levelFor(creates, zIndex, element.depth, depthInContext, parentContext, isRoot, mode);
  if (element.bounds && element.bounds.width >= 1 && element.bounds.height >= 1) {
    slabs.push({
      nodeId: element.nodeId,
      name: element.name,
      depth: element.depth,
      bounds: element.bounds,
      zIndex,
      createsContext: creates,
      reasons,
      level,
      paintOrder: order.value,
    });
    order.value += 1;
  }
  const nextContext = creates ? level : parentContext;
  const nextDepth = creates ? 0 : depthInContext + 1;
  for (const child of children.get(nodeId) ?? []) {
    walkSlab(child, nextContext, nextDepth, false, children, byId, mode, order, slabs);
  }
}

function levelFor(
    creates: boolean, zIndex: number|null, depth: number, depthInContext: number, parentContext: number,
    isRoot: boolean, mode: StackingMode): number {
  if (mode === 'dom') {
    return depth * DOM_STEP;
  }
  if (isRoot) {
    return 0;
  }
  if (creates) {
    if (zIndex !== null && zIndex !== 0) {
      return parentContext + zIndex * Z_STEP;
    }
    return parentContext + INNER_STEP;
  }
  return parentContext + INNER_STEP + depthInContext * INNER_STEP;
}

function appendEffect(name: string, value: string, reasons: string[]): void {
  if (!effectCreates(value)) {
    return;
  }
  reasons.push(name);
}

function hasZIndex(value: string): boolean {
  return value.length > 0 && value !== 'auto';
}

function flexOrGrid(display: string): boolean {
  return display === 'flex' || display === 'inline-flex' || display === 'grid' || display === 'inline-grid';
}

function opacityCreates(value: string): boolean {
  const number = Number(normalized(value));
  if (!Number.isFinite(number)) {
    return false;
  }
  return number >= 0 && number < 1;
}

function effectCreates(value: string): boolean {
  const text = normalized(value);
  return text.length > 0 && text !== 'none' && text !== 'auto';
}

function willChangeCreates(value: string): boolean {
  const triggers = new Set(['transform', 'opacity', 'filter', 'perspective', 'contain', 'z-index']);
  return tokens(value).some(token => triggers.has(token));
}

function containCreates(value: string): boolean {
  const names = tokens(value);
  return names.includes('paint') || names.includes('strict') || names.includes('content');
}

function tokens(value: string): string[] {
  return normalized(value).split(/[^a-z-]+/).filter(token => token.length > 0);
}

function normalized(value: string): string {
  return value.trim().toLowerCase();
}

function integer(value: number|undefined): number|null {
  if (typeof value !== 'number' || !Number.isFinite(value)) {
    return null;
  }
  return Math.trunc(value);
}
