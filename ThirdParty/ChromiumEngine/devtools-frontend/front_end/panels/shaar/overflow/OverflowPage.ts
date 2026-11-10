// Copyright 2026 The Shaar Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import {
  findOverflowCauses,
  type OverflowCause,
  type OverflowReport,
} from './OverflowFinder.js';

export const MOVED = 'moved';
export const FAILED = 'failed';

export interface CauseLabels {
  horizontal: string;
  vertical: string;
}

export interface PageMeasurement {
  href: string;
  truncated: boolean;
  nodes: unknown[];
}

export type Evaluate = (expression: string) => Promise<unknown>;

export class OverflowSession {
  causes: OverflowCause[] = [];
  scanned = false;
  scanning = false;
  failure: string|null = null;
  truncated = false;
  #generation = 0;

  reset(): void {
    this.#generation++;
    this.causes = [];
    this.scanned = false;
    this.scanning = false;
    this.failure = null;
    this.truncated = false;
  }

  async scan(evaluate: Evaluate, expectedHref: string): Promise<void> {
    const generation = ++this.#generation;
    this.scanning = true;
    this.failure = null;
    try {
      const value = await evaluate(collectExpression());
      if (generation !== this.#generation) {
        return;
      }
      const measured = readMeasurement(value);
      if (!measured) {
        this.#fail(FAILED);
        return;
      }
      if (expectedHref && !sameDocument(expectedHref, measured.href)) {
        this.causes = [];
        this.truncated = false;
        this.scanned = true;
        this.failure = MOVED;
        return;
      }
      const found = findOverflowCauses(measured.nodes);
      this.#apply(found, measured.truncated);
    } catch {
      if (generation !== this.#generation) {
        return;
      }
      this.#fail(FAILED);
    } finally {
      if (generation === this.#generation) {
        this.scanning = false;
      }
    }
  }

  #apply(found: OverflowReport, walkTruncated: boolean): void {
    this.causes = found.causes;
    this.truncated = walkTruncated || found.truncated;
    this.scanned = true;
    this.failure = null;
  }

  #fail(reason: string): void {
    this.causes = [];
    this.truncated = false;
    this.scanned = true;
    this.failure = reason;
  }
}

export function causeDetail(cause: OverflowCause, labels: CauseLabels): string {
  const parts: string[] = [];
  if (cause.axes.includes('horizontal')) {
    parts.push(labels.horizontal);
  }
  if (cause.axes.includes('vertical')) {
    parts.push(labels.vertical);
  }
  if (cause.uses100vw) {
    parts.push('100vw');
  }
  parts.push(`${cause.width}×${cause.height}`);
  return parts.join(' · ');
}

export function sameDocument(expected: string, actual: string): boolean {
  try {
    const left = new URL(expected);
    const right = new URL(actual);
    left.hash = '';
    right.hash = '';
    return withoutTrailingSlash(left.href) === withoutTrailingSlash(right.href);
  } catch {
    return expected === actual;
  }
}

function withoutTrailingSlash(href: string): string {
  if (href.endsWith('/')) {
    return href.slice(0, -1);
  }
  return href;
}

export function readMeasurement(value: unknown): PageMeasurement|null {
  if (!value || typeof value !== 'object') {
    return null;
  }
  const record = value as Record<string, unknown>;
  if (typeof record.href !== 'string' || !Array.isArray(record.nodes)) {
    return null;
  }
  return {
    href: record.href,
    truncated: record.truncated === true,
    nodes: record.nodes,
  };
}

export function collectExpression(): string {
  return `(() => {\n${selectorsUsing100vw.toString()}\n${clipsOverflow.toString()}\n${elementUses100vw.toString()}\n${selectorFor.toString()}\n${clearOverflowMarks.toString()}\n${collectOverflowInPage.toString()}\nreturn collectOverflowInPage();\n})()`;
}

export function highlightExpression(selector: string): string {
  return `(${highlightOverflowInPage.toString()})(${JSON.stringify(String(selector))})`;
}

function clipsOverflow(value: string): boolean {
  return value === 'auto' || value === 'scroll' || value === 'hidden' || value === 'clip' || value === 'overlay';
}

function selectorsUsing100vw(doc: Document): string[] {
  const widthProperties = [
    'width',
    'min-width',
    'max-width',
    'inline-size',
    'min-inline-size',
    'max-inline-size',
  ];
  const selectors: string[] = [];
  function visit(rules: CSSRuleList|undefined): void {
    if (!rules || selectors.length >= 200) {
      return;
    }
    for (let index = 0; index < rules.length; index++) {
      const rule = rules.item(index);
      if (!rule) {
        continue;
      }
      if (selectors.length >= 200) {
        return;
      }
      if (rule.type === 1 && 'selectorText' in rule && 'style' in rule) {
        const styleRule = rule as CSSStyleRule;
        for (const property of widthProperties) {
          const value = styleRule.style.getPropertyValue(property);
          if (value && value.indexOf('100vw') !== -1) {
            selectors.push(styleRule.selectorText);
            break;
          }
        }
      }
      if ('cssRules' in rule) {
        visit((rule as CSSGroupingRule).cssRules);
      }
      if ('styleSheet' in rule) {
        const sheet = (rule as CSSImportRule).styleSheet;
        if (sheet) {
          visit(sheet.cssRules ?? undefined);
        }
      }
    }
  }
  for (let index = 0; index < doc.styleSheets.length; index++) {
    const sheet = doc.styleSheets.item(index);
    if (!sheet) {
      continue;
    }
    try {
      visit(sheet.cssRules ?? undefined);
    } catch {
      // A cross-origin sheet cannot be read.
    }
  }
  return selectors;
}

function elementUses100vw(el: Element, selectors: string[]): boolean {
  const style = el.getAttribute('style') || '';
  if (style.indexOf('100vw') !== -1 &&
      /(?:^|;)\s*(?:min-|max-)?(?:inline-size|width)\s*:[^;]*100vw/i.test(style)) {
    return true;
  }
  for (const selector of selectors) {
    try {
      if (el.matches(selector)) {
        return true;
      }
    } catch {
      // The page cannot match this selector.
    }
  }
  return false;
}

function selectorFor(el: Element, doc: Document): string {
  if (el.id) {
    const id = `#${CSS.escape(el.id)}`;
    try {
      if (doc.querySelectorAll(id).length === 1) {
        return id;
      }
    } catch {
      // Keep walking.
    }
  }
  const parts: string[] = [];
  let current: Element|null = el;
  let depth = 0;
  while (current && current.nodeType === 1 && depth < 5) {
    const parent: Element|null = current.parentElement;
    let segment = current.tagName.toLowerCase();
    if (parent) {
      const same: Element[] = [];
      for (let index = 0; index < parent.children.length; index++) {
        const child = parent.children.item(index);
        if (child && child.tagName === current.tagName) {
          same.push(child);
        }
      }
      if (same.length > 1) {
        segment += `:nth-of-type(${same.indexOf(current) + 1})`;
      }
    }
    parts.unshift(segment);
    current = parent;
    depth += 1;
  }
  const selector = parts.join(' > ');
  if (selector.length > 180) {
    return selector.slice(0, 180);
  }
  return selector;
}

function clearOverflowMarks(doc: Document): void {
  const marked = doc.querySelectorAll('[data-shaar-overflow-mark]');
  for (const node of marked) {
    if (!(node instanceof HTMLElement)) {
      continue;
    }
    node.style.outline = node.getAttribute('data-shaar-overflow-outline') || '';
    node.removeAttribute('data-shaar-overflow-outline');
    node.removeAttribute('data-shaar-overflow-mark');
  }
}

function collectOverflowInPage(): {href: string, truncated: boolean, nodes: object[]} {
  const scanLimit = 8000;
  const doc = document;
  clearOverflowMarks(doc);
  const vwSelectors = selectorsUsing100vw(doc);
  const nodes: object[] = [];
  let next = 1;
  let truncatedWalk = false;

  function visit(el: Element|null, parentId: string|null): void {
    if (!el || el.nodeType !== 1 || truncatedWalk) {
      return;
    }
    const tag = el.tagName.toLowerCase();
    if (tag === 'script' || tag === 'style' || tag === 'link' || tag === 'meta' || tag === 'noscript' ||
        tag === 'head' || tag === 'title') {
      return;
    }
    if (!(el instanceof HTMLElement)) {
      for (let index = 0; index < el.children.length; index++) {
        visit(el.children.item(index), parentId);
      }
      return;
    }
    if (el.dataset.shaarInspector != null) {
      return;
    }
    if (el.getClientRects().length === 0) {
      return;
    }
    if (nodes.length >= scanLimit) {
      truncatedWalk = true;
      return;
    }
    const id = String(next++);
    const rect = el.getBoundingClientRect();
    const view = doc.defaultView;
    const style = view ? view.getComputedStyle(el) : null;
    nodes.push({
      id,
      parentId,
      scrollWidth: el.scrollWidth,
      clientWidth: el.clientWidth,
      scrollHeight: el.scrollHeight,
      clientHeight: el.clientHeight,
      left: rect.left,
      right: rect.right,
      top: rect.top,
      bottom: rect.bottom,
      contentLeft: rect.left + el.clientLeft,
      contentRight: rect.left + el.clientLeft + el.clientWidth,
      contentTop: rect.top + el.clientTop,
      contentBottom: rect.top + el.clientTop + el.clientHeight,
      clipsHorizontal: style ? clipsOverflow(style.overflowX) : false,
      clipsVertical: style ? clipsOverflow(style.overflowY) : false,
      uses100vw: elementUses100vw(el, vwSelectors),
      selector: selectorFor(el, doc),
      tag,
      width: Math.round(rect.width),
      height: Math.round(rect.height),
      rendered: true,
    });
    for (let index = 0; index < el.children.length; index++) {
      visit(el.children.item(index), id);
    }
  }

  if (doc.documentElement) {
    visit(doc.documentElement, null);
  }
  return {href: location.href, truncated: truncatedWalk, nodes};
}

function highlightOverflowInPage(selector: string): boolean {
  const marked = document.querySelectorAll('[data-shaar-overflow-mark]');
  for (const node of marked) {
    if (!(node instanceof HTMLElement)) {
      continue;
    }
    node.style.outline = node.getAttribute('data-shaar-overflow-outline') || '';
    node.removeAttribute('data-shaar-overflow-outline');
    node.removeAttribute('data-shaar-overflow-mark');
  }
  if (!selector) {
    return false;
  }
  let el: Element|null = null;
  try {
    el = document.querySelector(selector);
  } catch {
    return false;
  }
  if (!(el instanceof HTMLElement)) {
    return false;
  }
  el.setAttribute('data-shaar-overflow-outline', el.style.outline || '');
  el.setAttribute('data-shaar-overflow-mark', '1');
  el.style.outline = '2px solid rgb(229, 72, 77)';
  el.style.outlineOffset = '2px';
  try {
    el.scrollIntoView({block: 'nearest', inline: 'nearest'});
  } catch {
    // The element is still outlined.
  }
  return true;
}
