// Copyright 2026 The Shaar Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import * as Common from '../../../core/common/common.js';
import * as i18n from '../../../core/i18n/i18n.js';
import * as SDK from '../../../core/sdk/sdk.js';
import * as TextUtils from '../../../core/text_utils/text_utils.js';
import type * as Protocol from '../../../generated/protocol.js';
import * as UI from '../../../ui/legacy/legacy.js';
import {html, render} from '../../../ui/lit/lit.js';

import {
  diffServerHTML,
  treeFromSnapshot,
  type HydrationMismatch,
  type HydrationNotice,
  type HydrationReport,
  type SnapshotPayload,
} from './HydrationDiff.js';
import {
  attachLoadWait,
  pageDomSettle,
  pickDocumentResource,
  RequestSettleTracker,
  waitForQuiet,
} from './HydrationSettle.js';

const UIStrings = {
  /**
   * @description Title of the Hydration panel.
   */
  title: 'Hydration',
  /**
   * @description Short description under the Hydration title.
   */
  lede: 'Server HTML against the hydrated page.',
  /**
   * @description Button that compares server HTML with the hydrated page.
   */
  compare: 'Compare',
  /**
   * @description Button that reloads the page, then compares server HTML with the hydrated page.
   */
  reloadAndCompare: 'Reload and compare',
  /**
   * @description Status shown before a comparison has run.
   */
  idle: 'Compare the server HTML with the hydrated page.',
  /**
   * @description Status shown when no page is open.
   */
  noPage: 'Open a page, then compare.',
  /**
   * @description Status shown when the document response body could not be read.
   */
  noDocument: 'The document response is not available. Reload and compare to capture it.',
  /**
   * @description Status shown while a comparison is running.
   */
  working: 'Comparing…',
  /**
   * @description Status shown when the document body came from Network.getResponseBody.
   */
  networkSource: 'Document response from Network.getResponseBody.',
  /**
   * @description Status shown when the network log has no document body and the cached resource was used.
   */
  resourceSource:
      'The network log has no document body. Compared the cached document instead. Reload and compare to capture Network.getResponseBody.',
  /**
   * @description Status shown when the server HTML and the hydrated page match.
   */
  noMismatches: 'No mismatched nodes or attributes.',
  /**
   * @description Count of mismatches in the list.
   * @example {3} PH1
   */
  mismatchCount: '{PH1} mismatches',
  /**
   * @description Status shown when the mismatch list was cut off.
   * @example {80} PH1
   */
  truncated: 'Showing the first {PH1} mismatches.',
  /**
   * @description Banner shown when the response is not HTML.
   */
  notHtml: 'The document response is not HTML, so there is no server markup to diff.',
  /**
   * @description Banner shown when the server body has no rendered content.
   */
  clientShellEmpty: 'This document is only a client shell. The server HTML has no rendered body content.',
  /**
   * @description Banner shown when the server body is only an empty framework mount.
   */
  clientShellMount:
      'This document is only a client shell. The server HTML has an empty mount and the page content is rendered on the client.',
  /**
   * @description Label for a node that is in the server HTML and not on the page.
   */
  kindMissing: 'Missing',
  /**
   * @description Label for a node that is on the page and not in the server HTML.
   */
  kindExtra: 'Extra',
  /**
   * @description Label for an attribute that differs.
   */
  kindAttribute: 'Attribute',
  /**
   * @description Label for text that differs.
   */
  kindText: 'Text',
  /**
   * @description Detail for a node that exists only in the server HTML.
   */
  detailMissing: 'In the server HTML only',
  /**
   * @description Detail for a node that exists only on the hydrated page.
   */
  detailExtra: 'On the page only',
  /**
   * @description Detail for an attribute change.
   * @example {class} PH1
   * @example {old} PH2
   * @example {new} PH3
   */
  detailAttribute: '{PH1} is "{PH2}" on the server and "{PH3}" on the page',
  /**
   * @description Detail for a text change.
   * @example {Server} PH1
   * @example {Page} PH2
   */
  detailText: '"{PH1}" on the server and "{PH2}" on the page',
  /**
   * @description Hint on a row that opens the node in Elements.
   */
  jump: 'Elements',
  /**
   * @description Accessible name for a mismatch that can open the node in Elements.
   * @example {body > p is on the page only} PH1
   */
  showInElements: 'Show in Elements. {PH1}',
} as const;

const str_ = i18n.i18n.registerUIStrings('panels/shaar/hydration-diff/HydrationPanel.ts', UIStrings);
const i18nString = i18n.i18n.getLocalizedString.bind(undefined, str_);

const LOAD_TIMEOUT_MS = 15000;
const SETTLE_QUIET_MS = 400;
const SETTLE_CAP_MS = 3000;

export type DocumentSource = 'network'|'resource';
type StatusTone = 'info'|'ok'|'error';

export class DocumentBodyUnavailable extends Error {
  constructor() {
    super('document body unavailable');
    this.name = 'DocumentBodyUnavailable';
  }
}

export interface DocumentHTML {
  html: string;
  source: DocumentSource;
}

export class HydrationPanel extends UI.Panel.Panel {
  #running = false;
  #status = '';
  #tone: StatusTone = 'info';
  #notice: string|null = null;
  #rows: HydrationMismatch[] = [];
  #count = '';

  constructor() {
    super('shaar-hydration', /* useShadowDom */ true);
    this.#status = i18nString(UIStrings.idle);
    this.requestUpdate();
  }

  override performUpdate(): void {
    const compare = this.#compare;
    const reload = this.#reload;
    // clang-format off
    render(html`
      <style>
        .hydration {
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
        .hydration-title {
          margin: 0;
          font-size: 14px;
          font-weight: 650;
        }
        .hydration-lede {
          margin: 2px 0 0;
          color: var(--sys-color-on-surface-subtle);
        }
        .hydration-toolbar {
          display: flex;
          flex-wrap: wrap;
          gap: 6px;
          align-items: center;
          margin-top: 10px;
        }
        .hydration-button,
        button.hydration-row {
          appearance: none;
          box-sizing: border-box;
        }
        .hydration-button {
          border: 1px solid var(--sys-color-divider-prominent);
          border-radius: 4px;
          background: var(--sys-color-cdt-base-container);
          color: var(--sys-color-on-surface);
          padding: 4px 10px;
          font: inherit;
        }
        .hydration-button.primary {
          background: var(--sys-color-tonal-container);
          color: var(--sys-color-on-tonal-container);
          border-color: transparent;
          font-weight: 650;
        }
        .hydration-button:disabled {
          opacity: 0.55;
        }
        .hydration-button:focus-visible,
        .hydration-row:focus-visible {
          outline: 2px solid var(--sys-color-state-focus-ring);
          outline-offset: 2px;
        }
        .hydration-count {
          margin-left: auto;
          color: var(--sys-color-on-surface-subtle);
          font-variant-numeric: tabular-nums;
        }
        .hydration-status,
        .hydration-notice {
          margin: 10px 0 0;
        }
        .hydration-status.ok {
          color: var(--sys-color-primary);
          font-weight: 650;
        }
        .hydration-status.error {
          padding: 8px 10px;
          border-radius: 6px;
          border-left: 3px solid var(--sys-color-error);
          background: var(--sys-color-surface2);
          color: var(--sys-color-error);
        }
        .hydration-notice {
          padding: 8px 10px;
          border-radius: 6px;
          border-left: 3px solid var(--shaar-accent, var(--sys-color-primary));
          background: var(--sys-color-tonal-container);
          color: var(--sys-color-on-tonal-container);
        }
        .hydration-notice[hidden] {
          display: none;
        }
        .hydration-list {
          display: flex;
          flex-direction: column;
          gap: 4px;
          margin: 10px 0 0;
          padding: 0;
          list-style: none;
        }
        .hydration-row {
          display: flex;
          flex-wrap: wrap;
          gap: 4px 10px;
          align-items: baseline;
          width: 100%;
          margin: 0;
          padding: 6px 8px;
          border: 1px solid var(--sys-color-divider);
          border-radius: 4px;
          background: var(--sys-color-base-container);
          color: inherit;
          text-align: left;
          font: inherit;
        }
        button.hydration-row {
          cursor: pointer;
        }
        button.hydration-row:hover {
          border-color: var(--sys-color-divider-prominent);
        }
        .hydration-kind {
          flex: 0 0 auto;
          min-width: 5.6em;
          font-size: 10px;
          font-weight: 700;
          letter-spacing: 0.04em;
          text-transform: uppercase;
        }
        .hydration-path {
          flex: 1 1 12em;
          font-family: ui-monospace, monospace;
          overflow-wrap: anywhere;
        }
        .hydration-detail {
          flex: 1 1 12em;
          color: var(--sys-color-on-surface-subtle);
          overflow-wrap: anywhere;
        }
        .hydration-jump {
          margin-left: auto;
          color: var(--sys-color-primary);
          font-weight: 650;
        }
        .hydration-missing {
          border-left: 3px solid var(--sys-color-primary);
        }
        .hydration-missing .hydration-kind {
          color: var(--sys-color-primary);
        }
        .hydration-extra,
        .hydration-attribute,
        .hydration-text {
          border-left: 3px solid var(--sys-color-error);
        }
        .hydration-extra .hydration-kind,
        .hydration-attribute .hydration-kind,
        .hydration-text .hydration-kind {
          color: var(--sys-color-error);
        }
      </style>
      <div class="hydration">
        <h1 class="hydration-title">${i18nString(UIStrings.title)}</h1>
        <p class="hydration-lede">${i18nString(UIStrings.lede)}</p>
        <div class="hydration-toolbar">
          <button class="hydration-button primary" type="button" ?disabled=${this.#running} @click=${compare}>
            ${i18nString(UIStrings.compare)}
          </button>
          <button class="hydration-button" type="button" ?disabled=${this.#running} @click=${reload}>
            ${i18nString(UIStrings.reloadAndCompare)}
          </button>
          <span class="hydration-count">${this.#count}</span>
        </div>
        <p class=${statusClass(this.#tone)} role=${statusRole(this.#tone)}>${this.#status}</p>
        <p class="hydration-notice" ?hidden=${this.#notice === null}>${this.#notice ?? ''}</p>
        <ul class="hydration-list">
          ${this.#rows.map(row => rowTemplate(row))}
        </ul>
      </div>
    `, this.contentElement);
    // clang-format on
  }

  #compare = (): void => {
    void this.#run(false);
  };

  #reload = (): void => {
    void this.#run(true);
  };

  async #run(reload: boolean): Promise<void> {
    if (this.#running) {
      return;
    }
    this.#running = true;
    this.#status = i18nString(UIStrings.working);
    this.#tone = 'info';
    this.#notice = null;
    this.#rows = [];
    this.#count = '';
    this.requestUpdate();
    try {
      const target = SDK.TargetManager.TargetManager.instance().primaryPageTarget();
      if (!target) {
        this.#fail(i18nString(UIStrings.noPage));
        return;
      }
      if (reload) {
        await reloadPage(target);
      }
      const documentHTML = await readDocumentHTML(target);
      const hydrated = await captureHydratedBody(target);
      this.#applyReport(diffServerHTML(documentHTML.html, hydrated), documentHTML.source);
    } catch (error) {
      if (error instanceof DocumentBodyUnavailable) {
        this.#fail(i18nString(UIStrings.noDocument));
        return;
      }
      this.#fail(error instanceof Error ? error.message : String(error));
    } finally {
      this.#running = false;
      this.requestUpdate();
    }
  }

  #fail(message: string): void {
    this.#status = message;
    this.#tone = 'error';
    this.#notice = null;
    this.#rows = [];
    this.#count = '';
  }

  #applyReport(report: HydrationReport, source: DocumentSource): void {
    const sourceText = sourceStatus(source);
    if (report.mismatches.length === 0 && !report.notice) {
      this.#status = `${sourceText} ${i18nString(UIStrings.noMismatches)}`;
      this.#tone = 'ok';
      this.#count = '';
    } else if (report.truncated) {
      this.#status = `${sourceText} ${i18nString(UIStrings.truncated, {PH1: String(report.mismatches.length)})}`;
      this.#tone = 'info';
      this.#count = i18nString(UIStrings.mismatchCount, {PH1: String(report.mismatches.length)});
    } else if (report.mismatches.length === 0) {
      this.#status = sourceText;
      this.#tone = 'info';
      this.#count = '';
    } else {
      this.#status = sourceText;
      this.#tone = 'info';
      this.#count = i18nString(UIStrings.mismatchCount, {PH1: String(report.mismatches.length)});
    }
    this.#notice = noticeText(report.notice);
    this.#rows = report.mismatches;
  }
}

export async function readDocumentHTML(target: SDK.Target.Target): Promise<DocumentHTML> {
  const model = target.model(SDK.ResourceTreeModel.ResourceTreeModel);
  const frame = model?.mainFrame ?? null;
  if (!frame) {
    throw new DocumentBodyUnavailable();
  }
  const resource = documentResource(frame);
  const request = resource?.request ?? null;
  if (request) {
    const html = textFromContent(await request.requestContentData());
    if (html !== null) {
      return {html, source: 'network'};
    }
  }
  if (resource) {
    const html = textFromContent(await resource.requestContentData());
    if (html !== null) {
      return {html, source: 'resource'};
    }
  }
  throw new DocumentBodyUnavailable();
}

export async function captureHydratedBody(target: SDK.Target.Target): Promise<ReturnType<typeof treeFromSnapshot>> {
  const snapshot = await target.domsnapshotAgent().invoke_captureSnapshot({computedStyles: []});
  const error = snapshot.getError();
  if (error) {
    throw new Error(error);
  }
  return treeFromSnapshot(snapshot as SnapshotPayload);
}

function documentResource(frame: SDK.ResourceTreeModel.ResourceTreeFrame): SDK.Resource.Resource|null {
  const candidates = frame.resources().map(resource => ({
    url: resource.url,
    isDocument: resource.contentType() === Common.ResourceType.resourceTypes.Document,
    loaderId: resource.loaderId,
    isRedirect: resource.request?.isRedirect() ?? false,
    resource,
  }));
  return pickDocumentResource(frame.url, frame.loaderId, candidates)?.resource ?? null;
}

async function reloadPage(target: SDK.Target.Target): Promise<void> {
  const model = target.model(SDK.ResourceTreeModel.ResourceTreeModel);
  if (!model) {
    return;
  }
  const network = target.model(SDK.NetworkManager.NetworkManager);
  const tracker = new RequestSettleTracker();
  const stopNetwork = network ? watchNetwork(network, tracker) : null;
  try {
    const loaded = attachLoadWait(
        listener => {
          model.addEventListener(SDK.ResourceTreeModel.Events.Load, listener);
        },
        listener => {
          model.removeEventListener(SDK.ResourceTreeModel.Events.Load, listener);
        },
        LOAD_TIMEOUT_MS);
    model.reloadPage(true);
    const didLoad = await loaded;
    if (!didLoad) {
      return;
    }
    // Load fires before client hydration and late fetches mutate the DOM.
    await Promise.all([
      settleDom(target),
      waitForQuiet(() => tracker.inflight(), listener => tracker.subscribe(listener), SETTLE_QUIET_MS, SETTLE_CAP_MS),
    ]);
  } finally {
    stopNetwork?.();
  }
}

function watchNetwork(manager: SDK.NetworkManager.NetworkManager, tracker: RequestSettleTracker): () => void {
  const descriptors: Common.EventTarget.EventDescriptor[] = [
    manager.addEventListener(SDK.NetworkManager.Events.RequestStarted, event => {
      tracker.start(settleRequest(event.data.request));
    }),
    manager.addEventListener(SDK.NetworkManager.Events.RequestFinished, event => {
      tracker.finish(settleRequest(event.data));
    }),
  ];
  return () => {
    Common.EventTarget.removeEventListeners(descriptors);
  };
}

function settleRequest(request: SDK.NetworkRequest.NetworkRequest): {id: string, settles: boolean} {
  const type = request.resourceType();
  const types = Common.ResourceType.resourceTypes;
  const settles = type === types.Document || type === types.Script || type === types.Stylesheet ||
      type === types.XHR || type === types.Fetch || type === types.Image || type === types.Font;
  return {id: request.requestId(), settles};
}

async function settleDom(target: SDK.Target.Target): Promise<void> {
  const runtimeModel = target.model(SDK.RuntimeModel.RuntimeModel);
  const context = runtimeModel?.defaultExecutionContext() ?? null;
  if (!context) {
    return;
  }
  const expression = `(${pageDomSettle.toString()})(${SETTLE_QUIET_MS}, ${SETTLE_CAP_MS})`;
  try {
    await context.evaluate(
        {
          expression,
          includeCommandLineAPI: false,
          silent: true,
          returnByValue: true,
        },
        false, true);
  } catch {
    // A second navigation can destroy the context before the quiet window ends.
  }
}

async function revealBackendNode(backendNodeId: number): Promise<void> {
  const target = SDK.TargetManager.TargetManager.instance().primaryPageTarget();
  if (!target) {
    return;
  }
  const deferred = new SDK.DOMModel.DeferredDOMNode(target, backendNodeId as Protocol.DOM.BackendNodeId);
  const node = await deferred.resolvePromise();
  if (node) {
    await Common.Revealer.reveal(node);
  }
}

function sourceStatus(source: DocumentSource): string {
  if (source === 'network') {
    return i18nString(UIStrings.networkSource);
  }
  return i18nString(UIStrings.resourceSource);
}

function textFromContent(data: TextUtils.ContentData.ContentDataOrError): string|null {
  if (TextUtils.ContentData.ContentData.isError(data) || !data.isTextContent) {
    return null;
  }
  return data.text;
}

function noticeText(notice: HydrationNotice|null): string|null {
  if (notice === null) {
    return null;
  }
  if (notice === 'not-html') {
    return i18nString(UIStrings.notHtml);
  }
  if (notice === 'client-shell-empty') {
    return i18nString(UIStrings.clientShellEmpty);
  }
  return i18nString(UIStrings.clientShellMount);
}

function statusClass(tone: StatusTone): string {
  return `hydration-status ${tone}`;
}

function statusRole(tone: StatusTone): string {
  if (tone === 'error') {
    return 'alert';
  }
  return 'status';
}

function kindLabel(kind: HydrationMismatch['kind']): string {
  if (kind === 'missing') {
    return i18nString(UIStrings.kindMissing);
  }
  if (kind === 'extra') {
    return i18nString(UIStrings.kindExtra);
  }
  if (kind === 'attribute') {
    return i18nString(UIStrings.kindAttribute);
  }
  return i18nString(UIStrings.kindText);
}

function detailText(mismatch: HydrationMismatch): string {
  if (mismatch.kind === 'missing') {
    return i18nString(UIStrings.detailMissing);
  }
  if (mismatch.kind === 'extra') {
    return i18nString(UIStrings.detailExtra);
  }
  if (mismatch.kind === 'attribute') {
    return i18nString(UIStrings.detailAttribute, {
      PH1: mismatch.attributeName,
      PH2: mismatch.server,
      PH3: mismatch.page,
    });
  }
  return i18nString(UIStrings.detailText, {
    PH1: mismatch.server,
    PH2: mismatch.page,
  });
}

function rowSummary(mismatch: HydrationMismatch): string {
  return `${mismatch.path}. ${detailText(mismatch)}`;
}

function focusRow(current: EventTarget|null, delta: number): void {
  if (!(current instanceof HTMLElement)) {
    return;
  }
  const list = current.closest('.hydration-list');
  const buttons = list?.querySelectorAll('button.hydration-row');
  if (!buttons) {
    return;
  }
  const position = Array.prototype.indexOf.call(buttons, current);
  const target = buttons[position + delta];
  if (target instanceof HTMLElement) {
    target.focus();
  }
}

function rowClass(kind: HydrationMismatch['kind']): string {
  return `hydration-row hydration-${kind}`;
}

function rowTemplate(row: HydrationMismatch): ReturnType<typeof html> {
  const summary = rowSummary(row);
  const body = html`
    <span class="hydration-kind">${kindLabel(row.kind)}</span>
    <span class="hydration-path">${row.path}</span>
    <span class="hydration-detail">${detailText(row)}</span>
  `;
  if (row.backendNodeId === null) {
    return html`<li><div class=${rowClass(row.kind)}>${body}</div></li>`;
  }
  const backendNodeId = row.backendNodeId;
  const label = i18nString(UIStrings.showInElements, {PH1: summary});
  return html`
    <li>
      <button
        type="button"
        class=${rowClass(row.kind)}
        aria-label=${label}
        @click=${() => {
          void revealBackendNode(backendNodeId);
        }}
        @keydown=${(event: KeyboardEvent) => {
          if (event.key === 'ArrowDown') {
            event.preventDefault();
            focusRow(event.currentTarget, 1);
            return;
          }
          if (event.key === 'ArrowUp') {
            event.preventDefault();
            focusRow(event.currentTarget, -1);
          }
        }}>
        ${body}
        <span class="hydration-jump">${i18nString(UIStrings.jump)}</span>
      </button>
    </li>
  `;
}
