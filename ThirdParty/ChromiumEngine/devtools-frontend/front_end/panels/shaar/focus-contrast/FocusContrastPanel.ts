// Copyright 2026 The Shaar Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import * as i18n from '../../../core/i18n/i18n.js';
import * as SDK from '../../../core/sdk/sdk.js';
import type * as Protocol from '../../../generated/protocol.js';
import * as UI from '../../../ui/legacy/legacy.js';
import {html, render} from '../../../ui/lit/lit.js';

import {
  CLEAR_EXPRESSION,
  MAX_WALK_NODES,
  nextRowIndex,
  NO_STOPS,
  NOT_DRAWN,
  NOT_READY,
  refreshFocusContrast,
  walkDom,
  type FocusContrastCaller,
  type FocusContrastRow,
} from './FocusContrast.js';

const UIStrings = {
  /**
   * @description Heading of the Focus panel. The panel numbers tab stops and badges failing contrast.
   */
  title: 'Focus & contrast',
  /**
   * @description Explanation under the Focus panel heading.
   */
  lede: 'Number the tab order and mark text that fails WCAG AA while you work.',
  /**
   * @description Toggle that paints tab stops and contrast badges on the inspected page.
   */
  showOnPage: 'Show on the page',
  /**
   * @description Empty state before the overlay is turned on.
   */
  emptyOff: 'Turn this on to paint numbered tab stops and badge the pairs that fail WCAG AA.',
  /**
   * @description Empty state when the page has no tab stops.
   */
  emptyOn: 'No tab stops on this page.',
  /**
   * @description Status shown while the first pass is still reading the page.
   */
  reading: 'Reading the page.',
  /**
   * @description Section heading for the numbered tab stops.
   */
  tabOrder: 'Tab order',
  /**
   * @description Section heading for text that fails contrast.
   */
  contrast: 'Contrast',
  /**
   * @description Hint for moving through the result list from the keyboard.
   */
  hint: 'Arrow keys move through the list. Enter highlights that node on the page.',
  /**
   * @description Error when DevTools has no page to inspect.
   */
  notReady: 'This page is not ready for the overlay.',
  /**
   * @description Error when the page script did not return tab stops.
   */
  noStops: 'The page did not list its tab stops.',
  /**
   * @description Error when the badges could not be sent back to the page.
   */
  notDrawn: 'The overlay could not be drawn.',
  /**
   * @description Accessible name for a tab stop row. PH1 is the number. PH2 is the control name.
   * @example {3} PH1
   * @example {Submit} PH2
   */
  tabStopRow: 'Tab stop {PH1}, {PH2}',
  /**
   * @description Accessible name for a contrast row. PH1 is the ratio. PH2 is the text snippet.
   * @example {2.5} PH1
   * @example {Buy now} PH2
   */
  contrastRow: 'Contrast {PH1}, {PH2}',
} as const;

const str_ = i18n.i18n.registerUIStrings('panels/shaar/focus-contrast/FocusContrastPanel.ts', UIStrings);
const i18nString = i18n.i18n.getLocalizedString.bind(undefined, str_);

const REFRESH_MS = 2000;

export class FocusContrastPanel extends UI.Panel.Panel {
  #enabled = false;
  #running = false;
  #reading = false;
  #failure: string|null = null;
  #summary = '';
  #rows: FocusContrastRow[] = [];
  #generation = 0;
  #timer = 0;

  constructor() {
    super('shaar-focus-contrast', /* useShadowDom */ true);
    this.requestUpdate();
  }

  override performUpdate(): void {
    const focusRows = this.#rows.filter(row => row.kind === 'focus');
    const contrastRows = this.#rows.filter(row => row.kind === 'contrast');
    const failure = failureText(this.#failure);
    const showEmptyOff = !this.#enabled && !failure;
    const showEmptyOn = this.#enabled && !failure && !this.#reading && this.#rows.length === 0 && this.#summary !== '';
    // clang-format off
    render(html`
      <style>
        .focus-panel {
          box-sizing: border-box;
          height: 100%;
          overflow: auto;
          padding: 12px 14px 18px;
          color: var(--sys-color-on-surface);
          background: var(--sys-color-cdt-base);
          font-family: var(--default-font-family);
          font-size: 12px;
          line-height: 1.4;
        }
        .focus-header {
          display: flex;
          gap: 10px;
          align-items: flex-start;
        }
        .focus-logo {
          flex: 0 0 auto;
          min-width: 22px;
          height: 22px;
          padding: 0 6px;
          box-sizing: border-box;
          border-radius: 11px;
          background: #013C3C;
          box-shadow: 0 0 0 2px #C8F736;
          color: #C8F736;
          font-size: 12px;
          font-weight: 700;
          line-height: 22px;
          text-align: center;
        }
        h1 {
          margin: 0;
          font-size: 14px;
          font-weight: 650;
        }
        .focus-lede {
          margin: 2px 0 0;
          color: var(--sys-color-on-surface-subtle);
        }
        .focus-toolbar {
          display: flex;
          flex-wrap: wrap;
          gap: 8px;
          align-items: center;
          margin-top: 12px;
        }
        .focus-toggle {
          display: inline-flex;
          align-items: center;
          gap: 8px;
          border: 1px solid var(--sys-color-divider-prominent);
          border-radius: 999px;
          background: var(--sys-color-cdt-base-container);
          color: var(--sys-color-on-surface);
          padding: 3px 10px 3px 4px;
          font: inherit;
          font-weight: 650;
        }
        .focus-toggle[aria-pressed='true'] {
          background: var(--sys-color-tonal-container);
          color: var(--sys-color-on-tonal-container);
          border-color: transparent;
        }
        .focus-knob {
          position: relative;
          width: 28px;
          height: 16px;
          border-radius: 8px;
          background: var(--sys-color-divider-prominent);
        }
        .focus-knob::after {
          content: '';
          position: absolute;
          top: 2px;
          left: 2px;
          width: 12px;
          height: 12px;
          border-radius: 50%;
          background: #fff;
          transition: left 120ms ease;
        }
        .focus-toggle[aria-pressed='true'] .focus-knob {
          background: var(--shaar-accent, var(--sys-color-primary));
        }
        .focus-toggle[aria-pressed='true'] .focus-knob::after {
          left: 14px;
        }
        .focus-toggle:focus-visible,
        .focus-row:focus-visible {
          outline: 2px solid var(--sys-color-state-focus-ring);
          outline-offset: 2px;
        }
        .focus-summary {
          margin-left: auto;
          color: var(--sys-color-on-surface-subtle);
          font-variant-numeric: tabular-nums;
        }
        .focus-status {
          margin: 10px 0 0;
        }
        .focus-status.error {
          padding: 8px 10px;
          border-radius: 6px;
          border-left: 3px solid var(--sys-color-error);
          background: var(--sys-color-surface2);
          color: var(--sys-color-error);
        }
        .focus-empty {
          margin: 12px 0 0;
          padding: 10px 12px;
          border-radius: 8px;
          background: var(--shaar-section, var(--sys-color-surface2));
          color: var(--sys-color-on-surface);
        }
        .focus-empty p {
          margin: 8px 0 0;
        }
        .focus-sample {
          display: flex;
          gap: 8px;
          align-items: center;
        }
        .focus-sample .focus-mark.contrast {
          color: #fff;
        }
        .focus-section {
          margin: 14px 0 0;
        }
        .focus-section h2 {
          margin: 0 0 6px;
          color: var(--sys-color-on-surface-subtle);
          font-size: 10px;
          font-weight: 700;
          letter-spacing: 0.04em;
          text-transform: uppercase;
        }
        .focus-list {
          display: flex;
          flex-direction: column;
          gap: 4px;
          margin: 0;
          padding: 0;
          list-style: none;
        }
        .focus-row {
          display: flex;
          gap: 8px;
          align-items: center;
          width: 100%;
          margin: 0;
          padding: 5px 8px;
          border: 1px solid var(--sys-color-divider);
          border-radius: 6px;
          background: var(--sys-color-base-container);
          color: inherit;
          text-align: left;
          font: inherit;
          cursor: pointer;
        }
        .focus-row:hover {
          border-color: var(--sys-color-divider-prominent);
        }
        .focus-mark {
          flex: 0 0 auto;
          min-width: 18px;
          height: 18px;
          padding: 0 5px;
          box-sizing: border-box;
          border-radius: 9px;
          background: #013C3C;
          box-shadow: 0 0 0 2px #C8F736;
          color: #C8F736;
          font-size: 11px;
          font-weight: 700;
          line-height: 18px;
          text-align: center;
          font-variant-numeric: tabular-nums;
        }
        .focus-mark.contrast {
          border-radius: 4px;
          background: #9f1239;
          box-shadow: none;
          color: #fff;
          font-weight: 650;
        }
        .focus-snippet {
          min-width: 0;
          overflow: hidden;
          text-overflow: ellipsis;
          white-space: nowrap;
        }
        .focus-hint {
          margin: 10px 0 0;
          color: var(--sys-color-on-surface-subtle);
        }
        @media (prefers-reduced-motion: reduce) {
          .focus-knob::after { transition: none; }
        }
      </style>
      <div class="focus-panel">
        <header class="focus-header">
          <span class="focus-logo" aria-hidden="true">1</span>
          <div>
            <h1>${i18nString(UIStrings.title)}</h1>
            <p class="focus-lede">${i18nString(UIStrings.lede)}</p>
          </div>
        </header>
        <div class="focus-toolbar">
          <button class="focus-toggle" type="button"
              aria-pressed=${this.#enabled ? 'true' : 'false'} @click=${this.#toggle}>
            <span class="focus-knob" aria-hidden="true"></span>
            ${i18nString(UIStrings.showOnPage)}
          </button>
          <span class="focus-summary" aria-live="polite">${this.#summary}</span>
        </div>
        <p class="focus-status error" role="alert" ?hidden=${!failure}>${failure}</p>
        <p class="focus-status" ?hidden=${!this.#reading}>${i18nString(UIStrings.reading)}</p>
        <div class="focus-empty" ?hidden=${!showEmptyOff && !showEmptyOn}>
          <div class="focus-sample" aria-hidden="true" ?hidden=${showEmptyOn}>
            <span class="focus-mark">1</span>
            <span class="focus-mark contrast">4.48</span>
          </div>
          <p>${showEmptyOn ? i18nString(UIStrings.emptyOn) : i18nString(UIStrings.emptyOff)}</p>
        </div>
        ${section(i18nString(UIStrings.tabOrder), focusRows, this.#choose, this.#onListKey)}
        ${section(i18nString(UIStrings.contrast), contrastRows, this.#choose, this.#onListKey)}
        <p class="focus-hint" ?hidden=${this.#rows.length === 0}>${i18nString(UIStrings.hint)}</p>
      </div>
    `, this.contentElement);
    // clang-format on
  }

  override willHide(): void {
    this.#stop();
    super.willHide();
  }

  #toggle = (): void => {
    if (this.#enabled) {
      this.#stop();
      return;
    }
    this.#start();
  };

  #start(): void {
    this.#enabled = true;
    this.#failure = null;
    this.#generation += 1;
    const token = this.#generation;
    void this.#refresh(token);
    this.#timer = window.setInterval(() => {
      void this.#refresh(token);
    }, REFRESH_MS);
    this.requestUpdate();
  }

  #stop(): void {
    this.#generation += 1;
    this.#enabled = false;
    if (this.#timer) {
      window.clearInterval(this.#timer);
      this.#timer = 0;
    }
    this.#summary = '';
    this.#failure = null;
    this.#rows = [];
    this.#reading = false;
    const target = pageTarget();
    if (target) {
      void clearOverlay(target);
    }
    this.requestUpdate();
  }

  async #refresh(token: number): Promise<void> {
    if (this.#running || token !== this.#generation) {
      return;
    }
    this.#running = true;
    this.#reading = this.#rows.length === 0;
    this.requestUpdate();
    try {
      const target = pageTarget();
      if (!target) {
        if (token === this.#generation) {
          this.#failure = NOT_READY;
          this.#summary = '';
          this.#rows = [];
        }
        return;
      }
      const result = await refreshFocusContrast(
          new TargetCaller(target), () => token === this.#generation && this.#enabled);
      if (token !== this.#generation || result.cancelled) {
        return;
      }
      if (result.failure) {
        this.#failure = result.failure;
        if (result.failure === NO_STOPS || result.failure === NOT_DRAWN) {
          this.#summary = '';
          this.#rows = [];
        }
        return;
      }
      this.#failure = null;
      this.#summary = result.summary;
      this.#rows = result.rows;
    } finally {
      this.#running = false;
      this.#reading = false;
      if (token === this.#generation) {
        this.requestUpdate();
      }
    }
  }

  #choose = (row: FocusContrastRow): void => {
    const target = pageTarget();
    if (!target || row.nodeId === null) {
      return;
    }
    const rose = row.kind === 'contrast';
    void target.overlayAgent().invoke_highlightNode({
      highlightConfig: {
        showInfo: false,
        contentColor: rose ? {r: 159, g: 18, b: 57, a: 0.22} : {r: 1, g: 60, b: 60, a: 0.25},
        borderColor: rose ? {r: 159, g: 18, b: 57, a: 1} : {r: 200, g: 247, b: 54, a: 1},
      },
      nodeId: row.nodeId as Protocol.DOM.NodeId,
    });
  };

  #onListKey = (event: KeyboardEvent): void => {
    const current = event.target;
    if (!(current instanceof HTMLButtonElement) || !current.classList.contains('focus-row')) {
      return;
    }
    const list = current.closest('ul');
    const buttons = list ? [...list.querySelectorAll('button.focus-row')] : [];
    const next = nextRowIndex(buttons.length, buttons.indexOf(current), event.key);
    const target = next === null ? null : buttons[next];
    if (!(target instanceof HTMLButtonElement) || target === current) {
      return;
    }
    event.preventDefault();
    target.focus();
  };
}

class TargetCaller implements FocusContrastCaller {
  #target: SDK.Target.Target;

  constructor(target: SDK.Target.Target) {
    this.#target = target;
  }

  async evaluate(expression: string): Promise<unknown> {
    const response = await this.#target.runtimeAgent().invoke_evaluate({
      expression,
      returnByValue: true,
      awaitPromise: true,
    });
    const error = response.getError();
    if (error) {
      throw new Error(error);
    }
    if (response.exceptionDetails) {
      const details = response.exceptionDetails;
      throw new Error(details.exception?.description || details.text || 'The page script failed.');
    }
    return response.result.value;
  }

  async elementsTree(): Promise<unknown> {
    const domModel = this.#target.model(SDK.DOMModel.DOMModel);
    if (!domModel) {
      return null;
    }
    const document = domModel.existingDocument() ?? await domModel.requestDocument();
    if (!document) {
      return null;
    }
    const loaded = loadedPayload(document, {seen: 0});
    const index = walkDom(loaded);
    if (index.focus.size > 0 || index.contrast.size > 0) {
      return loaded;
    }
    const children = await queryMarkers(this.#target, domModel, document.id);
    return {nodeId: document.id, children};
  }

  async accessibleNames(backendNodeIds: number[]): Promise<Map<number, string>> {
    const names = new Map<number, string>();
    const axModel = this.#target.model(SDK.AccessibilityModel.AccessibilityModel);
    if (!axModel || backendNodeIds.length === 0) {
      return names;
    }
    for (const backendNodeId of backendNodeIds) {
      const response = await axModel.agent.invoke_getPartialAXTree({
        backendNodeId: backendNodeId as Protocol.DOM.BackendNodeId,
        fetchRelatives: false,
      });
      if (response.getError()) {
        continue;
      }
      for (const node of response.nodes ?? []) {
        const value = node.name?.value;
        if (typeof value === 'string' && value.trim()) {
          names.set(backendNodeId, value.trim().slice(0, 80));
          break;
        }
      }
    }
    return names;
  }

  async call(method: string, params: Record<string, unknown>): Promise<unknown> {
    const response = await dispatch(this.#target, method, params);
    const error = response.getError();
    if (error) {
      throw new Error(error);
    }
    return response;
  }
}

function loadedPayload(node: SDK.DOMModel.DOMNode, counter: {seen: number}): Record<string, unknown>|null {
  if (counter.seen >= MAX_WALK_NODES) {
    return null;
  }
  counter.seen += 1;
  const attributes: string[] = [];
  for (const attribute of node.attributes()) {
    attributes.push(attribute.name, attribute.value);
  }
  const children: Array<Record<string, unknown>> = [];
  for (const child of node.children() ?? []) {
    const payload = loadedPayload(child, counter);
    if (payload) {
      children.push(payload);
    }
  }
  for (const shadow of node.shadowRoots()) {
    const payload = loadedPayload(shadow, counter);
    if (payload) {
      children.push(payload);
    }
  }
  const frame = node.contentDocument();
  return {
    nodeId: node.id,
    backendNodeId: node.backendNodeId(),
    attributes,
    children,
    contentDocument: frame ? loadedPayload(frame, counter) : null,
  };
}

async function queryMarkers(
    target: SDK.Target.Target, domModel: SDK.DOMModel.DOMModel,
    rootId: Protocol.DOM.NodeId): Promise<unknown[]> {
  const nodes: unknown[] = [];
  for (const selector of ['[data-shaar-focus]', '[data-shaar-contrast]']) {
    const ids = await domModel.querySelectorAll(rootId, selector) ?? [];
    for (const nodeId of ids) {
      const loaded = domModel.nodeForId(nodeId);
      if (loaded) {
        const payload = loadedPayload(loaded, {seen: 0});
        if (payload) {
          nodes.push(payload);
        }
        continue;
      }
      const described = await target.domAgent().invoke_describeNode({nodeId, depth: 1, pierce: false});
      if (!described.getError() && described.node) {
        nodes.push(described.node);
      }
    }
  }
  return nodes;
}

async function clearOverlay(target: SDK.Target.Target): Promise<void> {
  const caller = new TargetCaller(target);
  try {
    await caller.evaluate(CLEAR_EXPRESSION);
  } catch {
    // The page overlay is already gone.
  }
  try {
    await target.overlayAgent().invoke_hideHighlight();
  } catch {
    // Highlight was not showing.
  }
}

function pageTarget(): SDK.Target.Target|null {
  return SDK.TargetManager.TargetManager.instance().primaryPageTarget();
}

function failureText(failure: string|null): string {
  if (failure === NOT_READY) {
    return i18nString(UIStrings.notReady);
  }
  if (failure === NO_STOPS) {
    return i18nString(UIStrings.noStops);
  }
  if (failure === NOT_DRAWN) {
    return i18nString(UIStrings.notDrawn);
  }
  return failure ?? '';
}

function section(
    title: string, rows: FocusContrastRow[], choose: (row: FocusContrastRow) => void,
    onKey: (event: KeyboardEvent) => void): ReturnType<typeof html> {
  if (rows.length === 0) {
    return html``;
  }
  // clang-format off
  return html`
    <section class="focus-section">
      <h2>${title}</h2>
      <ul class="focus-list" aria-label=${title} @keydown=${onKey}>
        ${rows.map(row => html`
          <li>
            <button class="focus-row" type="button" title=${row.snippet}
                aria-label=${rowName(row)} @click=${() => choose(row)}>
              <span class=${row.kind === 'contrast' ? 'focus-mark contrast' : 'focus-mark'}>${row.label}</span>
              <span class="focus-snippet">${row.snippet}</span>
            </button>
          </li>
        `)}
      </ul>
    </section>
  `;
  // clang-format on
}

function rowName(row: FocusContrastRow): string {
  if (row.kind === 'contrast') {
    return i18nString(UIStrings.contrastRow, {PH1: row.label, PH2: row.snippet});
  }
  return i18nString(UIStrings.tabStopRow, {PH1: row.label, PH2: row.snippet});
}

async function dispatch(
    target: SDK.Target.Target, method: string,
    params: Record<string, unknown>): Promise<Protocol.ProtocolResponseWithError> {
  const nodeId = params.nodeId as Protocol.DOM.NodeId;
  switch (method) {
    case 'DOM.getBoxModel':
      return await target.domAgent().invoke_getBoxModel({nodeId});
    case 'CSS.getBackgroundColors':
      return await target.cssAgent().invoke_getBackgroundColors({nodeId});
    default:
      throw new Error(method);
  }
}
