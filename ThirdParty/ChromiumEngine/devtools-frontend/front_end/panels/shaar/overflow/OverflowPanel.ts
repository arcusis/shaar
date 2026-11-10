// Copyright 2026 The Shaar Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import * as Common from '../../../core/common/common.js';
import * as i18n from '../../../core/i18n/i18n.js';
import * as SDK from '../../../core/sdk/sdk.js';
import * as UI from '../../../ui/legacy/legacy.js';
import {html, render} from '../../../ui/lit/lit.js';

import {CAUSE_LIMIT, type OverflowCause} from './OverflowFinder.js';
import {
  causeDetail,
  FAILED,
  highlightExpression,
  MOVED,
  OverflowSession,
} from './OverflowPage.js';

const UIStrings = {
  /**
   * @description Title of the Overflow panel. The panel lists elements that make the page scroll.
   */
  title: 'Overflow',
  /**
   * @description Short description under the Overflow title.
   */
  lede: 'Elements that make this page scroll.',
  /**
   * @description Button that scans the page for overflow.
   */
  find: 'Find overflow',
  /**
   * @description Status shown before a scan has run.
   */
  idle: 'Find the elements that cause this page to scroll.',
  /**
   * @description Status shown when no page is open.
   */
  noPage: 'Open a page, then find overflow.',
  /**
   * @description Status shown while the scan is running.
   */
  scanning: 'Scanning the page…',
  /**
   * @description Status shown when the scan finds nothing.
   */
  none: 'No overflowing elements',
  /**
   * @description Status shown when the scan could not finish.
   */
  failed: 'The overflow scan could not finish.',
  /**
   * @description Status shown when the page navigated before the scan finished.
   */
  moved: 'The page changed before the scan finished.',
  /**
   * @description Status shown when the list was cut off.
   * @example {100} PH1
   */
  truncated: 'Showing the first {PH1} overflowing elements.',
  /**
   * @description Count of one overflowing element.
   */
  oneCause: '1 overflowing element',
  /**
   * @description Count of overflowing elements.
   * @example {3} PH1
   */
  manyCauses: '{PH1} overflowing elements',
  /**
   * @description Axis label for horizontal overflow.
   */
  horizontal: 'Horizontal',
  /**
   * @description Axis label for vertical overflow.
   */
  vertical: 'Vertical',
  /**
   * @description Hint on a row that opens the element in Elements.
   */
  jump: 'Elements',
  /**
   * @description Accessible name for a row that opens the element in Elements.
   * @example {#wide. Horizontal · 2400×30} PH1
   */
  showInElements: 'Show in Elements. {PH1}',
} as const;

const str_ = i18n.i18n.registerUIStrings('panels/shaar/overflow/OverflowPanel.ts', UIStrings);
const i18nString = i18n.i18n.getLocalizedString.bind(undefined, str_);

const LABELS = {
  horizontal: (): string => i18nString(UIStrings.horizontal),
  vertical: (): string => i18nString(UIStrings.vertical),
};

export class OverflowPanel extends UI.Panel.Panel {
  #session = new OverflowSession();
  #generation = 0;
  #running = false;
  #failure: string|null = null;
  #causes: OverflowCause[] = [];
  #scanned = false;
  #truncated = false;
  #url = '';
  #seen = false;
  #descriptor: Common.EventTarget.EventDescriptor|null = null;

  constructor() {
    super('shaar-overflow', /* useShadowDom */ true);
    this.requestUpdate();
  }

  override wasShown(): void {
    super.wasShown();
    this.#subscribe();
    const url = pageTarget()?.inspectedURL() ?? '';
    if (this.#seen && url !== this.#url) {
      this.#reset();
    }
    this.#url = url;
    this.#seen = true;
  }

  override willHide(): void {
    super.willHide();
    this.#unsubscribe();
  }

  override performUpdate(): void {
    const find = this.#find;
    const failure = failureText(this.#failure);
    const showIdle = !this.#running && !this.#scanned && !failure;
    const showEmpty = this.#scanned && !this.#running && !failure && this.#causes.length === 0;
    const labels = {horizontal: LABELS.horizontal(), vertical: LABELS.vertical()};
    // clang-format off
    render(html`
      <style>
        .overflow {
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
        .overflow-header {
          display: flex;
          gap: 10px;
          align-items: flex-start;
        }
        .overflow-mark {
          flex: 0 0 auto;
          min-width: 22px;
          height: 22px;
          padding: 0 6px;
          box-sizing: border-box;
          border-radius: 11px;
          background: #013C3C;
          box-shadow: 0 0 0 2px #C8F736;
          color: #C8F736;
          font-size: 13px;
          font-weight: 700;
          line-height: 22px;
          text-align: center;
        }
        h1 {
          margin: 0;
          font-size: 14px;
          font-weight: 650;
        }
        .overflow-lede {
          margin: 2px 0 0;
          color: var(--sys-color-on-surface-subtle);
        }
        .overflow-toolbar {
          display: flex;
          flex-wrap: wrap;
          gap: 8px;
          align-items: center;
          margin-top: 12px;
        }
        .overflow-button,
        button.overflow-row {
          appearance: none;
          box-sizing: border-box;
          font: inherit;
        }
        .overflow-button {
          border: 1px solid transparent;
          border-radius: 4px;
          background: var(--sys-color-tonal-container);
          color: var(--sys-color-on-tonal-container);
          padding: 4px 10px;
          font-weight: 650;
        }
        .overflow-button:disabled {
          opacity: 0.55;
        }
        .overflow-count {
          margin-left: auto;
          color: var(--sys-color-on-surface-subtle);
          font-variant-numeric: tabular-nums;
        }
        .overflow-status,
        .overflow-notice {
          margin: 10px 0 0;
        }
        .overflow-status.error {
          color: var(--sys-color-error);
        }
        .overflow-list {
          list-style: none;
          margin: 10px 0 0;
          padding: 0;
          display: flex;
          flex-direction: column;
          gap: 6px;
        }
        .overflow-row {
          display: grid;
          grid-template-columns: minmax(0, 1fr) auto;
          gap: 2px 12px;
          width: 100%;
          text-align: left;
          border: 1px solid var(--sys-color-divider-prominent);
          border-radius: 6px;
          background: var(--sys-color-cdt-base-container);
          color: inherit;
          padding: 8px 10px;
        }
        .overflow-row.vw {
          box-shadow: inset 3px 0 #e5484d;
        }
        .overflow-selector {
          font-family: ui-monospace, monospace;
          overflow-wrap: anywhere;
        }
        .overflow-detail {
          grid-column: 1;
          color: var(--sys-color-on-surface-subtle);
        }
        .overflow-jump {
          grid-column: 2;
          grid-row: 1 / span 2;
          align-self: center;
          color: var(--sys-color-primary);
        }
        .overflow-button:focus-visible,
        .overflow-row:focus-visible {
          outline: 2px solid var(--sys-color-state-focus-ring);
          outline-offset: 2px;
        }
      </style>
      <section class="overflow">
        <div class="overflow-header">
          <div class="overflow-mark" aria-hidden="true">↔</div>
          <div>
            <h1>${i18nString(UIStrings.title)}</h1>
            <p class="overflow-lede">${i18nString(UIStrings.lede)}</p>
          </div>
        </div>
        <div class="overflow-toolbar">
          <button class="overflow-button" type="button" ?disabled=${this.#running} @click=${find}>
            ${i18nString(UIStrings.find)}
          </button>
          ${this.#causes.length ? html`<span class="overflow-count">${countText(this.#causes.length)}</span>` : ''}
        </div>
        ${failure ? html`<p class="overflow-status error" role="alert">${failure}</p>` : ''}
        ${this.#running ? html`<p class="overflow-status" role="status">${i18nString(UIStrings.scanning)}</p>` : ''}
        ${showIdle ? html`<p class="overflow-status" role="status">${i18nString(UIStrings.idle)}</p>` : ''}
        ${showEmpty ? html`<p class="overflow-status" role="status">${i18nString(UIStrings.none)}</p>` : ''}
        ${this.#truncated ? html`<p class="overflow-notice">${i18nString(UIStrings.truncated, {PH1: CAUSE_LIMIT})}</p>` : ''}
        ${this.#causes.length ? html`
          <ul class="overflow-list">
            ${this.#causes.map(cause => rowTemplate(cause, labels, this.#show))}
          </ul>
        ` : ''}
      </section>
    `, this.contentElement);
    // clang-format on
  }

  #find = (): void => {
    const target = pageTarget();
    if (!target) {
      this.#failure = 'unavailable';
      this.#scanned = false;
      this.#causes = [];
      this.requestUpdate();
      return;
    }
    const generation = ++this.#generation;
    this.#running = true;
    this.#failure = null;
    this.#url = target.inspectedURL();
    this.requestUpdate();
    void this.#run(target, generation);
  };

  async #run(target: SDK.Target.Target, generation: number): Promise<void> {
    try {
      const caller = new TargetCaller(target);
      await this.#session.scan(expression => caller.evaluate(expression), target.inspectedURL());
      if (generation !== this.#generation) {
        return;
      }
      this.#failure = this.#session.failure;
      this.#causes = this.#session.causes;
      this.#truncated = this.#session.truncated;
      this.#scanned = this.#session.scanned;
    } catch {
      if (generation !== this.#generation) {
        return;
      }
      this.#failure = FAILED;
      this.#scanned = true;
      this.#causes = [];
    } finally {
      if (generation === this.#generation) {
        this.#running = false;
        this.requestUpdate();
      }
    }
  }

  #show = (cause: OverflowCause): void => {
    const target = pageTarget();
    if (!target) {
      return;
    }
    void showCause(target, cause.selector);
  };

  #reset(): void {
    this.#generation++;
    this.#session.reset();
    this.#running = false;
    this.#failure = null;
    this.#causes = [];
    this.#scanned = false;
    this.#truncated = false;
    this.requestUpdate();
  }

  #subscribe(): void {
    this.#unsubscribe();
    const model = pageTarget()?.model(SDK.ResourceTreeModel.ResourceTreeModel);
    if (!model) {
      return;
    }
    this.#descriptor = model.addEventListener(SDK.ResourceTreeModel.Events.FrameNavigated, event => {
      if (!event.data.isMainFrame()) {
        return;
      }
      this.#url = event.data.url;
      this.#reset();
    });
  }

  #unsubscribe(): void {
    if (!this.#descriptor) {
      return;
    }
    Common.EventTarget.removeEventListeners([this.#descriptor]);
    this.#descriptor = null;
  }
}

function rowTemplate(
    cause: OverflowCause, labels: {horizontal: string, vertical: string},
    show: (cause: OverflowCause) => void): ReturnType<typeof html> {
  const detail = causeDetail(cause, labels);
  const summary = `${cause.selector}. ${detail}`;
  const rowClass = cause.uses100vw ? 'overflow-row vw' : 'overflow-row';
  return html`
    <li>
      <button
        type="button"
        class=${rowClass}
        aria-label=${i18nString(UIStrings.showInElements, {PH1: summary})}
        @click=${() => show(cause)}>
        <span class="overflow-selector">${cause.selector || cause.tag}</span>
        <span class="overflow-detail">${detail}</span>
        <span class="overflow-jump">${i18nString(UIStrings.jump)}</span>
      </button>
    </li>
  `;
}

function countText(count: number): string {
  if (count === 1) {
    return i18nString(UIStrings.oneCause);
  }
  return i18nString(UIStrings.manyCauses, {PH1: count});
}

function failureText(failure: string|null): string {
  if (failure === 'unavailable') {
    return i18nString(UIStrings.noPage);
  }
  if (failure === MOVED) {
    return i18nString(UIStrings.moved);
  }
  if (failure === FAILED) {
    return i18nString(UIStrings.failed);
  }
  return '';
}

async function showCause(target: SDK.Target.Target, selector: string): Promise<void> {
  const caller = new TargetCaller(target);
  try {
    await caller.evaluate(highlightExpression(selector));
  } catch {
    // The outline is optional. Elements can still open.
  }
  await revealSelector(target, selector);
}

async function revealSelector(target: SDK.Target.Target, selector: string): Promise<void> {
  const response = await target.runtimeAgent().invoke_evaluate({
    expression: `document.querySelector(${JSON.stringify(selector)})`,
    objectGroup: 'shaar-overflow',
  });
  if (response.getError() || response.exceptionDetails) {
    return;
  }
  const objectId = response.result.objectId;
  if (!objectId) {
    return;
  }
  try {
    const model = target.model(SDK.DOMModel.DOMModel);
    const node = model ? await model.pushNodeToFrontend(objectId) : null;
    if (node) {
      await Common.Revealer.reveal(node);
    }
  } finally {
    try {
      await target.runtimeAgent().invoke_releaseObjectGroup({objectGroup: 'shaar-overflow'});
    } catch {
      // The object group is already gone.
    }
  }
}

class TargetCaller {
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
}

function pageTarget(): SDK.Target.Target|null {
  return SDK.TargetManager.TargetManager.instance().primaryPageTarget();
}
