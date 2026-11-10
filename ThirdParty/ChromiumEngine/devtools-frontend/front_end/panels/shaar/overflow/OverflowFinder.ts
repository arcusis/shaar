// Copyright 2026 The Shaar Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// A cause is the outermost element that sticks out of a scroll container.
// A child already covered by that element is omitted. 100vw is flagged even
// when the page does not currently scroll.

export const CAUSE_LIMIT = 100;
const SLOP = 1;

export type OverflowAxis = 'horizontal'|'vertical';

export interface MeasuredNode {
  id: string;
  parentId: string|null;
  selector: string;
  tag: string;
  scrollWidth: number;
  clientWidth: number;
  scrollHeight: number;
  clientHeight: number;
  left: number;
  right: number;
  top: number;
  bottom: number;
  contentLeft: number;
  contentRight: number;
  contentTop: number;
  contentBottom: number;
  clipsHorizontal: boolean;
  clipsVertical: boolean;
  uses100vw: boolean;
  width: number;
  height: number;
  rendered: boolean;
}

export interface OverflowCause {
  id: string;
  selector: string;
  tag: string;
  axes: OverflowAxis[];
  uses100vw: boolean;
  width: number;
  height: number;
}

export interface OverflowReport {
  causes: OverflowCause[];
  truncated: boolean;
}

interface Box {
  id: string;
  parentId: string|null;
  selector: string;
  tag: string;
  scrollWidth: number;
  clientWidth: number;
  scrollHeight: number;
  clientHeight: number;
  left: number;
  right: number;
  top: number;
  bottom: number;
  contentLeft: number;
  contentRight: number;
  contentTop: number;
  contentBottom: number;
  clipsHorizontal: boolean;
  clipsVertical: boolean;
  uses100vw: boolean;
  width: number;
  height: number;
}

interface Container {
  node: Box;
  axes: OverflowAxis[];
}

interface Sticker {
  node: Box;
  axes: OverflowAxis[];
}

export function findOverflowCauses(input: unknown): OverflowReport {
  if (!Array.isArray(input)) {
    return {causes: [], truncated: false};
  }
  const byId = new Map<string, Box>();
  const children = new Map<string, string[]>();
  for (const raw of input) {
    const node = normalize(raw);
    if (!node) {
      continue;
    }
    byId.set(node.id, node);
  }
  for (const node of byId.values()) {
    if (node.parentId === null || !byId.has(node.parentId)) {
      continue;
    }
    const list = children.get(node.parentId) ?? [];
    list.push(node.id);
    children.set(node.parentId, list);
  }

  const containers: Container[] = [];
  for (const node of byId.values()) {
    const axes = overflowingAxes(node);
    if (axes.length) {
      containers.push({node, axes});
    }
  }

  const causes: OverflowCause[] = [];
  const indexById = new Map<string, number>();
  for (const container of containers) {
    const stickers = stickingDescendants(container, byId, children);
    const outermost = stickers.filter(sticker => !stickers.some(other =>
      other.node.id !== sticker.node.id && isAncestor(other.node.id, sticker.node.id, byId)));
    if (!outermost.length) {
      addCause(causes, indexById, container.node, container.axes);
      continue;
    }
    for (const sticker of outermost) {
      addCause(causes, indexById, sticker.node, sticker.axes);
    }
  }

  const visible = causes.filter(cause => cause.axes.length > 0 && !coveredByAncestor(cause, byId, causes, indexById));
  causes.length = 0;
  indexById.clear();
  for (const cause of visible) {
    indexById.set(cause.id, causes.length);
    causes.push(cause);
  }

  for (const node of byId.values()) {
    if (!node.uses100vw || has100vwAncestor(node, byId)) {
      continue;
    }
    addCause(causes, indexById, node, []);
    const index = indexById.get(node.id);
    if (index !== undefined) {
      causes[index].uses100vw = true;
    }
  }

  return {causes: causes.slice(0, CAUSE_LIMIT), truncated: causes.length > CAUSE_LIMIT};
}

function stickingDescendants(container: Container, byId: Map<string, Box>, children: Map<string, string[]>): Sticker[] {
  const stickers: Sticker[] = [];
  for (const id of descendants(container.node.id, children)) {
    const node = byId.get(id);
    if (!node) {
      continue;
    }
    const axes: OverflowAxis[] = [];
    for (const axis of container.axes) {
      if (sticks(node, container.node, axis)) {
        axes.push(axis);
      }
    }
    if (axes.length) {
      stickers.push({node, axes});
    }
  }
  return stickers;
}

function addCause(causes: OverflowCause[], indexById: Map<string, number>, node: Box, axes: OverflowAxis[]): void {
  const existing = indexById.get(node.id);
  if (existing !== undefined) {
    const cause = causes[existing];
    for (const axis of axes) {
      if (!cause.axes.includes(axis)) {
        cause.axes.push(axis);
      }
    }
    return;
  }
  indexById.set(node.id, causes.length);
  causes.push({
    id: node.id,
    selector: node.selector,
    tag: node.tag,
    axes: axes.slice(),
    uses100vw: node.uses100vw,
    width: asInt(node.width),
    height: asInt(node.height),
  });
}

function asInt(value: number): number {
  if (!Number.isFinite(value)) {
    return 0;
  }
  return Math.trunc(value);
}

function overflowingAxes(node: Box): OverflowAxis[] {
  const axes: OverflowAxis[] = [];
  if (node.scrollWidth > node.clientWidth + SLOP && canScroll(node, 'horizontal')) {
    axes.push('horizontal');
  }
  if (node.scrollHeight > node.clientHeight + SLOP && canScroll(node, 'vertical')) {
    axes.push('vertical');
  }
  return axes;
}

function canScroll(node: Box, axis: OverflowAxis): boolean {
  if (node.parentId === null || node.tag === 'html' || node.tag === 'body') {
    return true;
  }
  if (axis === 'horizontal') {
    return node.clipsHorizontal;
  }
  return node.clipsVertical;
}

function sticks(node: Box, container: Box, axis: OverflowAxis): boolean {
  if (axis === 'horizontal') {
    return node.right > container.contentRight + SLOP || node.left < container.contentLeft - SLOP;
  }
  return node.bottom > container.contentBottom + SLOP || node.top < container.contentTop - SLOP;
}

function descendants(id: string, children: Map<string, string[]>): string[] {
  const result: string[] = [];
  const stack = (children.get(id) ?? []).slice().reverse();
  while (stack.length) {
    const next = stack.pop();
    if (!next) {
      continue;
    }
    result.push(next);
    const more = children.get(next);
    if (!more) {
      continue;
    }
    for (let index = more.length - 1; index >= 0; index--) {
      stack.push(more[index]);
    }
  }
  return result;
}

function isAncestor(ancestorId: string, nodeId: string, byId: Map<string, Box>): boolean {
  let parentId = byId.get(nodeId)?.parentId ?? null;
  while (parentId !== null) {
    if (parentId === ancestorId) {
      return true;
    }
    parentId = byId.get(parentId)?.parentId ?? null;
  }
  return false;
}

function coveredByAncestor(
    cause: OverflowCause, byId: Map<string, Box>, causes: OverflowCause[], indexById: Map<string, number>): boolean {
  let parentId = byId.get(cause.id)?.parentId ?? null;
  while (parentId !== null) {
    const index = indexById.get(parentId);
    const ancestor = index === undefined ? undefined : causes[index];
    if (ancestor && cause.axes.every(axis => ancestor.axes.includes(axis))) {
      return true;
    }
    parentId = byId.get(parentId)?.parentId ?? null;
  }
  return false;
}

function has100vwAncestor(node: Box, byId: Map<string, Box>): boolean {
  let parentId = node.parentId;
  while (parentId !== null) {
    const parent = byId.get(parentId);
    if (!parent) {
      return false;
    }
    if (parent.uses100vw) {
      return true;
    }
    parentId = parent.parentId;
  }
  return false;
}

function normalize(raw: unknown): Box|null {
  if (!raw || typeof raw !== 'object') {
    return null;
  }
  const record = raw as Record<string, unknown>;
  if (record.id == null || record.rendered === false) {
    return null;
  }
  const id = String(record.id);
  if (!id) {
    return null;
  }
  let parentId: string|null = null;
  if (record.parentId != null) {
    parentId = String(record.parentId);
  }
  return {
    id,
    parentId,
    selector: record.selector == null ? '' : String(record.selector),
    tag: record.tag == null ? '' : String(record.tag),
    scrollWidth: num(record.scrollWidth),
    clientWidth: num(record.clientWidth),
    scrollHeight: num(record.scrollHeight),
    clientHeight: num(record.clientHeight),
    left: num(record.left),
    right: num(record.right),
    top: num(record.top),
    bottom: num(record.bottom),
    contentLeft: num(record.contentLeft),
    contentRight: num(record.contentRight),
    contentTop: num(record.contentTop),
    contentBottom: num(record.contentBottom),
    clipsHorizontal: record.clipsHorizontal === true,
    clipsVertical: record.clipsVertical === true,
    uses100vw: record.uses100vw === true,
    width: num(record.width),
    height: num(record.height),
  };
}

function num(value: unknown): number {
  const number = Number(value);
  if (!Number.isFinite(number)) {
    return 0;
  }
  return number;
}
