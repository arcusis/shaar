// Copyright 2026 The Shaar Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

export interface Color {
  red: number;
  green: number;
  blue: number;
  alpha: number;
}

export interface Point {
  x: number;
  y: number;
}

export interface FocusStop {
  id: number;
  tabIndex: number;
  documentOrder: number;
  name: string;
  origin: Point;
}

export interface TextSample {
  id: number;
  snippet: string;
  origin: Point;
  color: string;
  fontSize: string;
  fontWeight: string;
}

export interface Inventory {
  scrollX: number;
  scrollY: number;
  stops: FocusStop[];
  texts: TextSample[];
  truncated: boolean;
}

export interface ContrastDecision {
  ratio: number;
  fails: boolean;
  largeText: boolean;
}

export interface DomIndex {
  focus: Map<number, number>;
  contrast: Map<number, number>;
  backend: Map<number, number>;
}

export interface FocusContrastBadge {
  kind: 'focus'|'contrast';
  label: string;
  marker: string;
  snippet: string;
  x: number;
  y: number;
  nodeId: number|null;
}

export interface FocusContrastRow {
  id: string;
  kind: 'focus'|'contrast';
  label: string;
  snippet: string;
  nodeId: number|null;
}

export interface FocusContrastTrace {
  boxModel: boolean;
  backgroundColors: boolean;
  axNames: boolean;
  computedStyle: boolean;
}

export interface FocusContrastRefresh {
  cancelled: boolean;
  failure: string|null;
  summary: string;
  badges: FocusContrastBadge[];
  rows: FocusContrastRow[];
  trace: FocusContrastTrace;
}

export interface FocusContrastCaller {
  evaluate(expression: string): Promise<unknown>;
  /** Markers from the Elements model. Not a DOM.getDocument(depth: -1) pull. */
  elementsTree(): Promise<unknown>;
  /** Accessible names for these stops only. Not Accessibility.getFullAXTree. */
  accessibleNames(backendNodeIds: number[]): Promise<Map<number, string>>;
  call(method: string, params: Record<string, unknown>): Promise<unknown>;
}

/** Page walk and Elements walk stop after this many nodes. */
export const MAX_WALK_NODES = 2000;

/** 14pt. WCAG counts bold text at least this size as large. 14 * 96 / 72 = 18.666... */
export const LARGE_BOLD_PX = 18.66;

export const NO_STOPS = 'no-stops';
export const NOT_DRAWN = 'not-drawn';
export const NOT_READY = 'not-ready';

export function orderFocusStops(stops: FocusStop[]): FocusStop[] {
  const eligible = stops.filter(stop => stop.tabIndex >= 0);
  const positive = eligible.filter(stop => stop.tabIndex > 0).sort(earlierStop);
  const natural = eligible.filter(stop => stop.tabIndex === 0).sort(earlierStop);
  return [...positive, ...natural];
}

export function summaryText(stops: number, failures: number, limited: number, truncated: boolean): string {
  const parts = [
    counted(stops, 'tab stop', 'tab stops'),
    counted(failures, 'contrast failure', 'contrast failures'),
  ];
  if (limited > 0) {
    parts.push(`${limited} not scored`);
  }
  if (truncated) {
    parts.push('list limited');
  }
  return parts.join(' · ');
}

export function ratioText(ratio: number): string {
  return ratio.toFixed(2);
}

export function isLargeText(fontSizePx: number, fontWeight: number): boolean {
  if (fontSizePx >= 24) {
    return true;
  }
  return fontSizePx >= LARGE_BOLD_PX && fontWeight >= 700;
}

export function failsAA(ratio: number, largeText: boolean): boolean {
  if (largeText) {
    return ratio < 3;
  }
  return ratio < 4.5;
}

export function parseColor(text: string): Color|null {
  const trimmed = text.trim().toLowerCase();
  if (trimmed === 'transparent') {
    return {red: 0, green: 0, blue: 0, alpha: 0};
  }
  if (trimmed.startsWith('#')) {
    return parseHex(trimmed);
  }
  if (trimmed.startsWith('rgb')) {
    return parseRGB(trimmed);
  }
  return null;
}

export function decideContrast(style: unknown, colors: unknown): ContrastDecision|null {
  const colorText = styleProperty(style, 'color');
  const foreground = colorText ? parseColor(colorText) : null;
  const sizeText = styleProperty(style, 'font-size');
  const fontSize = sizeText ? pixels(sizeText) : null;
  const weightText = styleProperty(style, 'font-weight');
  const weight = weightText ? fontWeight(weightText) : null;
  const listed = backgroundColors(colors);
  if (!foreground || fontSize === null || weight === null || !listed) {
    return null;
  }
  const parsed: Color[] = [];
  for (const item of listed) {
    const color = parseColor(item);
    if (!color) {
      return null;
    }
    parsed.push(color);
  }
  const background = flatten(parsed);
  if (!background) {
    return null;
  }
  const ratio = contrastRatio(foreground, background);
  if (ratio === null) {
    return null;
  }
  const largeText = isLargeText(fontSize, weight);
  return {ratio, fails: failsAA(ratio, largeText), largeText};
}

export function walkDom(node: unknown): DomIndex {
  const index = emptyIndex();
  const root = asObject(node);
  if (!root) {
    return index;
  }
  visit(root, 0, {seen: 0}, index);
  return index;
}

export function decodeInventory(value: unknown): Inventory|null {
  const fields = asObject(value);
  if (!fields) {
    return null;
  }
  return {
    scrollX: asNumber(fields.scrollX) ?? 0,
    scrollY: asNumber(fields.scrollY) ?? 0,
    stops: asArray(fields.stops).map(decodeStop).filter((stop): stop is FocusStop => stop !== null),
    texts: asArray(fields.texts).map(decodeText).filter((text): text is TextSample => text !== null),
    truncated: fields.truncated === true,
  };
}

export function viewportOrigin(result: unknown, scrollX: number, scrollY: number): Point|null {
  const model = asObject(asObject(result)?.model);
  if (!model) {
    return null;
  }
  const quad = asNumbers(model.border) ?? asNumbers(model.content);
  if (!quad || quad.length < 8 || quad.length % 2 !== 0) {
    return null;
  }
  let minX = quad[0];
  let minY = quad[1];
  for (let index = 0; index + 1 < quad.length; index += 2) {
    minX = Math.min(minX, quad[index]);
    minY = Math.min(minY, quad[index + 1]);
  }
  if (!Number.isFinite(minX) || !Number.isFinite(minY)) {
    return null;
  }
  return {x: minX - scrollX, y: minY - scrollY};
}

export function accessibleName(tree: unknown, backendNodeId: number): string|null {
  for (const node of asArray(asObject(tree)?.nodes)) {
    const fields = asObject(node);
    if (!fields || asInt(fields.backendDOMNodeId) !== backendNodeId) {
      continue;
    }
    const name = asObject(fields.name);
    const value = name && typeof name.value === 'string' ? name.value.trim() : '';
    if (!value) {
      return null;
    }
    return value.slice(0, 80);
  }
  return null;
}

export function badgePosition(
    kind: 'focus'|'contrast', box: {left: number, top: number}, textWidth: number|null,
    textRight: number|null): {left: number, top: number} {
  if (kind === 'contrast') {
    const right = textWidth !== null && textWidth >= 1 && textRight !== null ? textRight : box.left;
    return {left: Math.max(0, right + 6), top: Math.max(0, box.top)};
  }
  return {left: Math.max(0, box.left), top: Math.max(0, box.top - 20)};
}

export function nextRowIndex(count: number, index: number, key: string): number|null {
  if (count <= 0 || index < 0 || index >= count) {
    return null;
  }
  if (key === 'ArrowDown') {
    return Math.min(count - 1, index + 1);
  }
  if (key === 'ArrowUp') {
    return Math.max(0, index - 1);
  }
  if (key === 'Home') {
    return 0;
  }
  if (key === 'End') {
    return count - 1;
  }
  return null;
}

export function paintExpression(badges: FocusContrastBadge[]): string|null {
  const payload = {
    badges: badges.map(badge => ({
                  kind: badge.kind,
                  label: badge.label,
                  marker: badge.marker,
                  group: badge.kind,
                  snippet: badge.snippet,
                  x: badge.x,
                  y: badge.y,
                })),
  };
  let json = '';
  try {
    json = JSON.stringify(payload);
  } catch {
    return null;
  }
  return `globalThis.__shaarA11yOverlay && globalThis.__shaarA11yOverlay.paint(${json})`;
}

export const CLEAR_EXPRESSION =
    '(globalThis.__shaarA11yOverlay ? globalThis.__shaarA11yOverlay.clear() : true)';

export const COLLECT_EXPRESSION = `(() => {
  const maxStops = 30;
  const maxTexts = 30;
  const maxNodes = 2000;
  const selector = 'a[href], button, input, select, textarea, summary, [tabindex], [contenteditable="true"]';
  const blocked = new Set(['SCRIPT', 'STYLE', 'NOSCRIPT', 'OPTION', 'SVG']);

  function install() {
    if (globalThis.__shaarA11yOverlay) return;
    const host = document.createElement('div');
    host.id = 'shaar-a11y-overlay';
    host.setAttribute('data-shaar-a11y-host', '1');
    host.style.cssText = 'position:fixed;inset:0;pointer-events:none;z-index:2147483646;';
    const shadow = host.attachShadow({mode: 'open'});
    const style = document.createElement('style');
    style.textContent = [
      ':host { all: initial; }',
      '.badge { position: fixed; z-index: 2147483646; pointer-events: none;',
      '  font: 600 11px/18px -apple-system, BlinkMacSystemFont, sans-serif; color: #fff; }',
      '.focus { min-width: 18px; height: 18px; padding: 0 4px; box-sizing: border-box;',
      '  border-radius: 9px; background: #013C3C; box-shadow: 0 0 0 2px #C8F736;',
      '  display: flex; align-items: center; justify-content: center; }',
      '.contrast { height: 18px; padding: 0 5px; border-radius: 4px; background: #9f1239; }'
    ].join('');
    const layer = document.createElement('div');
    shadow.append(style, layer);
    document.documentElement.append(host);
    const place = (badge, item) => {
      const contrast = item.group === 'contrast' || item.kind === 'contrast';
      const group = contrast ? 'data-shaar-contrast' : 'data-shaar-focus';
      const node = document.querySelector('[' + group + '="' + item.marker + '"]');
      const rect = node ? node.getBoundingClientRect() : null;
      const x = rect ? rect.left : item.x;
      const y = rect ? rect.top : item.y;
      if (contrast) {
        let right = x;
        if (node) {
          const range = document.createRange();
          range.selectNodeContents(node);
          const textRect = range.getBoundingClientRect();
          if (textRect.width >= 1) right = textRect.right;
        }
        badge.style.left = Math.max(0, right + 6) + 'px';
        badge.style.top = Math.max(0, y) + 'px';
        return;
      }
      badge.style.left = Math.max(0, x) + 'px';
      badge.style.top = Math.max(0, y - 20) + 'px';
    };
    const reposition = () => {
      for (const badge of layer.children) place(badge, badge.__shaarItem || {});
    };
    window.addEventListener('scroll', reposition, true);
    window.addEventListener('resize', reposition);
    globalThis.__shaarA11yOverlay = {
      paint(payload) {
        layer.replaceChildren();
        const badges = payload && payload.badges ? payload.badges : [];
        for (const item of badges) {
          if (!Number.isFinite(item.x) || !Number.isFinite(item.y)) continue;
          const badge = document.createElement('div');
          badge.className = 'badge ' + (item.kind === 'contrast' ? 'contrast' : 'focus');
          badge.dataset.kind = item.kind === 'contrast' ? 'contrast' : 'focus';
          badge.dataset.snippet = item.snippet || '';
          badge.textContent = String(item.label || '');
          badge.__shaarItem = item;
          place(badge, item);
          layer.append(badge);
        }
        return true;
      },
      clear() {
        window.removeEventListener('scroll', reposition, true);
        window.removeEventListener('resize', reposition);
        host.remove();
        document.querySelectorAll('[data-shaar-focus]').forEach((node) => {
          node.removeAttribute('data-shaar-focus');
        });
        document.querySelectorAll('[data-shaar-contrast]').forEach((node) => {
          node.removeAttribute('data-shaar-contrast');
        });
        delete globalThis.__shaarA11yOverlay;
        return true;
      },
      read() {
        const focus = [];
        const contrast = [];
        for (const badge of layer.children) {
          if (badge.dataset.kind === 'contrast') {
            contrast.push({label: badge.textContent || '', snippet: badge.dataset.snippet || ''});
          } else {
            focus.push(badge.textContent || '');
          }
        }
        return {focus, contrast};
      }
    };
  }

  function skipped(node) {
    return !node || node.closest('#shaar-a11y-overlay') || node.closest('[data-shaar-inspector]');
  }

  function shown(node, style) {
    if (!style || skipped(node) || node.closest('[inert]')) return false;
    if (style.display === 'none' || style.visibility === 'hidden') return false;
    const rect = node.getBoundingClientRect();
    return rect.width >= 1 || rect.height >= 1;
  }

  function label(node) {
    const text = node.getAttribute('aria-label') || node.innerText || node.textContent || '';
    return text.replace(/\\s+/g, ' ').trim().slice(0, 80);
  }

  function ownText(node) {
    let text = '';
    for (const child of node.childNodes) {
      if (child.nodeType === 3) text += child.textContent || '';
    }
    return text.replace(/\\s+/g, ' ').trim().slice(0, 80);
  }

  install();
  document.querySelectorAll('[data-shaar-focus]').forEach((node) => {
    node.removeAttribute('data-shaar-focus');
  });
  document.querySelectorAll('[data-shaar-contrast]').forEach((node) => {
    node.removeAttribute('data-shaar-contrast');
  });

  const stops = [];
  const texts = [];
  let truncated = false;
  let order = 0;
  let seen = 0;
  function visit(node) {
    if (!node || node.nodeType !== 1) return;
    if (seen >= maxNodes) { truncated = true; return; }
    seen += 1;
    if (skipped(node) || blocked.has(node.tagName)) return;
    const style = getComputedStyle(node);
    const visible = shown(node, style);
    const focusable = visible && node.matches(selector) && !node.matches(':disabled') &&
        !(node.tagName === 'INPUT' && node.type === 'hidden') && node.tabIndex >= 0;
    if (focusable) {
      if (stops.length >= maxStops) truncated = true;
      else {
        const rect = node.getBoundingClientRect();
        node.setAttribute('data-shaar-focus', String(stops.length + 1));
        stops.push({
          id: stops.length + 1,
          tabIndex: node.tabIndex,
          documentOrder: order,
          name: label(node),
          x: rect.left,
          y: rect.top
        });
        order += 1;
      }
    }
    const snippet = ownText(node);
    if (visible && snippet) {
      if (texts.length >= maxTexts) truncated = true;
      else {
        const rect = node.getBoundingClientRect();
        node.setAttribute('data-shaar-contrast', String(texts.length + 1));
        texts.push({
          id: texts.length + 1,
          snippet,
          x: rect.left,
          y: rect.top,
          color: style.color,
          fontSize: style.fontSize,
          fontWeight: String(style.fontWeight)
        });
      }
    }
    if (seen >= maxNodes) { truncated = true; return; }
    for (const child of node.children) visit(child);
  }
  if (document.body) visit(document.body);
  return {scrollX: window.scrollX, scrollY: window.scrollY, stops, texts, truncated};
})()`;

export async function refreshFocusContrast(
    caller: FocusContrastCaller, active: () => boolean): Promise<FocusContrastRefresh> {
  const trace = emptyTrace();
  try {
    if (!active()) {
      return cancelled(trace);
    }
    const inventory = decodeInventory(await caller.evaluate(COLLECT_EXPRESSION));
    if (!inventory) {
      return failed(NO_STOPS, trace);
    }
    if (!active()) {
      return cancelled(trace);
    }
    const index = walkDom(await caller.elementsTree());
    if (!active()) {
      return cancelled(trace);
    }
    const ordered = orderFocusStops(inventory.stops);
    const names = await namesForStops(caller, ordered, index, trace);
    const focus = await focusBadges(caller, ordered, index, inventory, names, trace);
    const scored = await contrastBadges(caller, inventory, index, trace);
    if (!active()) {
      return cancelled(trace);
    }
    const badges = [...focus, ...scored.badges];
    const expression = paintExpression(badges);
    if (!expression) {
      return failed(NOT_DRAWN, trace);
    }
    await caller.evaluate(expression);
    if (!active()) {
      try {
        await caller.evaluate(CLEAR_EXPRESSION);
      } catch {
        // The page overlay is already gone.
      }
      return cancelled(trace);
    }
    return {
      cancelled: false,
      failure: null,
      summary: summaryText(focus.length, scored.badges.length, scored.limited, inventory.truncated),
      badges,
      rows: rowsFor(badges),
      trace,
    };
  } catch (error) {
    if (!active()) {
      return cancelled(trace);
    }
    return failed(failureMessage(error), trace);
  }
}

function earlierStop(lhs: FocusStop, rhs: FocusStop): number {
  if (lhs.tabIndex !== rhs.tabIndex) {
    return lhs.tabIndex - rhs.tabIndex;
  }
  return lhs.documentOrder - rhs.documentOrder;
}

function counted(count: number, singular: string, plural: string): string {
  if (count === 1) {
    return `1 ${singular}`;
  }
  return `${count} ${plural}`;
}

function emptyIndex(): DomIndex {
  return {focus: new Map(), contrast: new Map(), backend: new Map()};
}

function emptyTrace(): FocusContrastTrace {
  return {boxModel: false, backgroundColors: false, axNames: false, computedStyle: false};
}

function cancelled(trace: FocusContrastTrace): FocusContrastRefresh {
  return {cancelled: true, failure: null, summary: '', badges: [], rows: [], trace};
}

function failed(failure: string, trace: FocusContrastTrace): FocusContrastRefresh {
  return {cancelled: false, failure, summary: '', badges: [], rows: [], trace};
}

function rowsFor(badges: FocusContrastBadge[]): FocusContrastRow[] {
  return badges.map(badge => ({
                    id: `${badge.kind}-${badge.marker}`,
                    kind: badge.kind,
                    label: badge.label,
                    snippet: badge.snippet,
                    nodeId: badge.nodeId,
                  }));
}

function failureMessage(error: unknown): string {
  const text = error instanceof Error ? error.message : String(error);
  const trimmed = text.trim();
  if (!trimmed) {
    return 'The overlay stopped.';
  }
  return trimmed.slice(0, 180);
}

async function namesForStops(
    caller: FocusContrastCaller, stops: FocusStop[], index: DomIndex,
    trace: FocusContrastTrace): Promise<Map<number, string>> {
  const backendIds: number[] = [];
  for (const stop of stops) {
    const nodeId = index.focus.get(stop.id);
    const backend = nodeId === undefined ? null : index.backend.get(nodeId) ?? null;
    if (backend !== null) {
      backendIds.push(backend);
    }
  }
  if (backendIds.length === 0) {
    return new Map();
  }
  try {
    const names = await caller.accessibleNames(backendIds);
    trace.axNames = true;
    return names;
  } catch {
    return new Map();
  }
}

async function focusBadges(
    caller: FocusContrastCaller, stops: FocusStop[], index: DomIndex, inventory: Inventory,
    names: Map<number, string>, trace: FocusContrastTrace): Promise<FocusContrastBadge[]> {
  const badges: FocusContrastBadge[] = [];
  for (let offset = 0; offset < stops.length; offset++) {
    const stop = stops[offset];
    const nodeId = index.focus.get(stop.id) ?? null;
    const origin = await originFor(caller, nodeId, stop.origin, inventory, trace);
    const backend = nodeId === null ? null : index.backend.get(nodeId) ?? null;
    badges.push({
      kind: 'focus',
      label: String(offset + 1),
      marker: String(stop.id),
      snippet: (backend === null ? null : names.get(backend)) ?? stop.name,
      x: origin.x,
      y: origin.y,
      nodeId,
    });
  }
  return badges;
}

async function contrastBadges(
    caller: FocusContrastCaller, inventory: Inventory, index: DomIndex,
    trace: FocusContrastTrace): Promise<{badges: FocusContrastBadge[], limited: number}> {
  const badges: FocusContrastBadge[] = [];
  let limited = 0;
  for (const text of inventory.texts) {
    const nodeId = index.contrast.get(text.id);
    if (nodeId === undefined) {
      limited += 1;
      continue;
    }
    const style = textStyle(text);
    if (style) {
      trace.computedStyle = true;
    }
    const colors = await backgroundColorsFor(caller, nodeId, trace);
    const decision = decideContrast(style, colors);
    if (!decision) {
      limited += 1;
      continue;
    }
    if (!decision.fails) {
      continue;
    }
    const origin = await originFor(caller, nodeId, text.origin, inventory, trace);
    badges.push({
      kind: 'contrast',
      label: ratioText(decision.ratio),
      marker: String(text.id),
      snippet: text.snippet,
      x: origin.x,
      y: origin.y,
      nodeId,
    });
  }
  return {badges, limited};
}

async function originFor(
    caller: FocusContrastCaller, nodeId: number|null, fallback: Point, inventory: Inventory,
    trace: FocusContrastTrace): Promise<Point> {
  if (nodeId === null) {
    return fallback;
  }
  try {
    const model = await caller.call('DOM.getBoxModel', {nodeId});
    trace.boxModel = true;
    return viewportOrigin(model, inventory.scrollX, inventory.scrollY) ?? fallback;
  } catch {
    return fallback;
  }
}

function textStyle(text: TextSample): unknown|null {
  if (!text.color || !text.fontSize || !text.fontWeight) {
    return null;
  }
  return {
    computedStyle: [
      {name: 'color', value: text.color},
      {name: 'font-size', value: text.fontSize},
      {name: 'font-weight', value: text.fontWeight},
    ],
  };
}

async function backgroundColorsFor(caller: FocusContrastCaller, nodeId: number, trace: FocusContrastTrace):
    Promise<unknown> {
  try {
    const colors = await caller.call('CSS.getBackgroundColors', {nodeId});
    trace.backgroundColors = true;
    return colors;
  } catch {
    return null;
  }
}

function visit(node: Record<string, unknown>, depth: number, counter: {seen: number}, index: DomIndex): void {
  if (depth > 64 || counter.seen >= MAX_WALK_NODES) {
    return;
  }
  counter.seen += 1;
  readDomNode(node, index);
  for (const child of childrenOf(node)) {
    visit(child, depth + 1, counter, index);
  }
}

function childrenOf(node: Record<string, unknown>): Array<Record<string, unknown>> {
  const found: Array<Record<string, unknown>> = [];
  for (const child of asArray(node.children)) {
    const fields = asObject(child);
    if (fields) {
      found.push(fields);
    }
  }
  for (const child of asArray(node.shadowRoots)) {
    const fields = asObject(child);
    if (fields) {
      found.push(fields);
    }
  }
  const frame = asObject(node.contentDocument);
  if (frame) {
    found.push(frame);
  }
  return found;
}

function readDomNode(node: Record<string, unknown>, index: DomIndex): void {
  const nodeId = asInt(node.nodeId);
  if (nodeId === null) {
    return;
  }
  const backend = asInt(node.backendNodeId);
  if (backend !== null) {
    index.backend.set(nodeId, backend);
  }
  const pairs = attributePairs(node.attributes);
  const focus = markerId(pairs.get('data-shaar-focus'));
  const contrast = markerId(pairs.get('data-shaar-contrast'));
  if (focus !== null) {
    index.focus.set(focus, nodeId);
  }
  if (contrast !== null) {
    index.contrast.set(contrast, nodeId);
  }
}

function attributePairs(value: unknown): Map<string, string> {
  const pairs = new Map<string, string>();
  const raw: string[] = [];
  for (const item of asArray(value)) {
    if (typeof item === 'string') {
      raw.push(item);
    }
  }
  if (raw.length % 2 !== 0) {
    return pairs;
  }
  for (let index = 0; index + 1 < raw.length; index += 2) {
    pairs.set(raw[index], raw[index + 1]);
  }
  return pairs;
}

function markerId(value: string|undefined): number|null {
  if (!value || !/^-?\d+$/.test(value)) {
    return null;
  }
  return Number(value);
}

function decodeStop(value: unknown): FocusStop|null {
  const fields = asObject(value);
  if (!fields || typeof fields.name !== 'string') {
    return null;
  }
  const id = asInt(fields.id);
  const tabIndex = asInt(fields.tabIndex);
  const documentOrder = asInt(fields.documentOrder);
  const x = asNumber(fields.x);
  const y = asNumber(fields.y);
  if (id === null || tabIndex === null || documentOrder === null || x === null || y === null) {
    return null;
  }
  return {id, tabIndex, documentOrder, name: fields.name, origin: {x, y}};
}

function decodeText(value: unknown): TextSample|null {
  const fields = asObject(value);
  if (!fields || typeof fields.snippet !== 'string') {
    return null;
  }
  const id = asInt(fields.id);
  const x = asNumber(fields.x);
  const y = asNumber(fields.y);
  if (id === null || x === null || y === null) {
    return null;
  }
  return {
    id,
    snippet: fields.snippet,
    origin: {x, y},
    color: typeof fields.color === 'string' ? fields.color : '',
    fontSize: typeof fields.fontSize === 'string' ? fields.fontSize : '',
    fontWeight: typeof fields.fontWeight === 'string' ? fields.fontWeight : '',
  };
}

function styleProperty(style: unknown, name: string): string|null {
  for (const row of asArray(asObject(style)?.computedStyle)) {
    const fields = asObject(row);
    if (fields && fields.name === name && typeof fields.value === 'string') {
      return fields.value;
    }
  }
  return null;
}

function backgroundColors(colors: unknown): string[]|null {
  const listed: string[] = [];
  for (const item of asArray(asObject(colors)?.backgroundColors)) {
    if (typeof item === 'string') {
      listed.push(item);
    }
  }
  return listed.length > 0 ? listed : null;
}

function contrastRatio(foreground: Color, background: Color): number|null {
  if (background.alpha < 0.99) {
    return null;
  }
  const painted = over(foreground, background);
  if (painted.alpha < 0.99) {
    return null;
  }
  const front = luminance(painted);
  const back = luminance(background);
  return (Math.max(front, back) + 0.05) / (Math.min(front, back) + 0.05);
}

function flatten(colors: Color[]): Color|null {
  if (colors.length === 0) {
    return null;
  }
  let result = colors[colors.length - 1];
  for (let index = colors.length - 2; index >= 0; index--) {
    result = over(colors[index], result);
  }
  if (result.alpha < 0.99) {
    return null;
  }
  return result;
}

function over(front: Color, back: Color): Color {
  const alpha = front.alpha + back.alpha * (1 - front.alpha);
  if (alpha <= 0) {
    return {red: 0, green: 0, blue: 0, alpha: 0};
  }
  return {
    red: mix(front.red, front.alpha, back.red, back.alpha, alpha),
    green: mix(front.green, front.alpha, back.green, back.alpha, alpha),
    blue: mix(front.blue, front.alpha, back.blue, back.alpha, alpha),
    alpha,
  };
}

function mix(front: number, frontAlpha: number, back: number, backAlpha: number, alpha: number): number {
  return (front * frontAlpha + back * backAlpha * (1 - frontAlpha)) / alpha;
}

function luminance(color: Color): number {
  return 0.2126 * linear(color.red) + 0.7152 * linear(color.green) + 0.0722 * linear(color.blue);
}

function linear(channel: number): number {
  if (channel <= 0.04045) {
    return channel / 12.92;
  }
  return ((channel + 0.055) / 1.055) ** 2.4;
}

function pixels(text: string): number|null {
  const trimmed = text.trim().toLowerCase();
  if (!trimmed.endsWith('px')) {
    return null;
  }
  const value = Number(trimmed.slice(0, -2));
  return Number.isFinite(value) ? value : null;
}

function fontWeight(text: string): number|null {
  const trimmed = text.trim().toLowerCase();
  if (trimmed === 'normal') {
    return 400;
  }
  if (trimmed === 'bold') {
    return 700;
  }
  const value = Number(trimmed);
  return Number.isFinite(value) ? value : null;
}

function parseRGB(text: string): Color|null {
  const open = text.indexOf('(');
  const close = text.lastIndexOf(')');
  if (open < 0 || close <= open) {
    return null;
  }
  const parts = text.slice(open + 1, close).split(/[,/\s]+/).filter(part => part.length > 0);
  if (parts.length !== 3 && parts.length !== 4) {
    return null;
  }
  const red = channel(parts[0]);
  const green = channel(parts[1]);
  const blue = channel(parts[2]);
  const alpha = parts.length === 4 ? alphaValue(parts[3]) : 1;
  if (red === null || green === null || blue === null || alpha === null) {
    return null;
  }
  return {red, green, blue, alpha};
}

function parseHex(text: string): Color|null {
  const hex = text.slice(1);
  if (!/^[0-9a-f]+$/.test(hex)) {
    return null;
  }
  const expanded = hex.length === 3 || hex.length === 4 ? hex.split('').map(digit => digit + digit).join('') : hex;
  if (expanded.length !== 6 && expanded.length !== 8) {
    return null;
  }
  const value = Number.parseInt(expanded, 16);
  if (!Number.isFinite(value)) {
    return null;
  }
  if (expanded.length === 6) {
    return {
      red: ((value >> 16) & 0xff) / 255,
      green: ((value >> 8) & 0xff) / 255,
      blue: (value & 0xff) / 255,
      alpha: 1,
    };
  }
  return {
    red: ((value >> 24) & 0xff) / 255,
    green: ((value >> 16) & 0xff) / 255,
    blue: ((value >> 8) & 0xff) / 255,
    alpha: (value & 0xff) / 255,
  };
}

function channel(text: string): number|null {
  if (text.endsWith('%')) {
    const value = Number(text.slice(0, -1));
    return Number.isFinite(value) ? value / 100 : null;
  }
  const value = Number(text);
  return Number.isFinite(value) ? value / 255 : null;
}

function alphaValue(text: string): number|null {
  if (text.endsWith('%')) {
    const value = Number(text.slice(0, -1));
    return Number.isFinite(value) ? value / 100 : null;
  }
  const value = Number(text);
  return Number.isFinite(value) ? value : null;
}

function asObject(value: unknown): Record<string, unknown>|null {
  if (!value || typeof value !== 'object' || Array.isArray(value)) {
    return null;
  }
  return value as Record<string, unknown>;
}

function asArray(value: unknown): unknown[] {
  return Array.isArray(value) ? value : [];
}

function asInt(value: unknown): number|null {
  if (typeof value !== 'number' || !Number.isInteger(value)) {
    return null;
  }
  return value;
}

function asNumber(value: unknown): number|null {
  if (typeof value !== 'number' || !Number.isFinite(value)) {
    return null;
  }
  return value;
}

function asNumbers(value: unknown): number[]|null {
  if (!Array.isArray(value)) {
    return null;
  }
  const numbers: number[] = [];
  for (const item of value) {
    const number = asNumber(item);
    if (number === null) {
      return null;
    }
    numbers.push(number);
  }
  return numbers;
}

function asInts(value: unknown): number[] {
  const numbers: number[] = [];
  for (const item of asArray(value)) {
    const number = asInt(item);
    if (number !== null) {
      numbers.push(number);
    }
  }
  return numbers;
}
