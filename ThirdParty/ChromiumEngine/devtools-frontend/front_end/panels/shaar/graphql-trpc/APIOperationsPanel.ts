// Copyright 2026 The Shaar Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import * as Common from '../../../core/common/common.js';
import * as i18n from '../../../core/i18n/i18n.js';
import type * as SDK from '../../../core/sdk/sdk.js';
import * as UI from '../../../ui/legacy/legacy.js';
import {html, nothing, render, type TemplateResult} from '../../../ui/lit/lit.js';

import {
  callLabel,
  columnText,
  moveIndex,
  operationMatches,
  type APIFilter,
  type APIOperation,
} from './APIOperations.js';
import {Events as WatchEvents, installAPIOperationWatch, type APIOperationWatch} from './APIOperationWatch.js';

const UIStrings = {
  /**
   * @description Title of the API operations panel.
   */
  title: 'API operations',
  /**
   * @description Short description under the API operations title.
   */
  lede: 'GraphQL and tRPC calls, named from the request. Arrow keys move. Enter opens the call in Network.',
  /**
   * @description Accessible name for the operation search field.
   */
  search: 'Filter by operation',
  /**
   * @description Accessible name for the operation filter.
   */
  filter: 'Show',
  /**
   * @description Filter that shows every GraphQL and tRPC operation.
   */
  all: 'All',
  /**
   * @description Filter that shows GraphQL operations. The product name stays in English.
   */
  graphql: 'GraphQL',
  /**
   * @description Filter that shows tRPC operations. The product name stays in English.
   */
  trpc: 'tRPC',
  /**
   * @description Filter that shows operations whose JSON response has errors.
   */
  errorsFilter: 'Errors',
  /**
   * @description Count of API operations in the list.
   * @example {12} PH1
   */
  operationCount: '{PH1} operations',
  /**
   * @description Count of API operations whose JSON response has errors.
   * @example {2} PH1
   */
  errorCount: '{PH1} with errors',
  /**
   * @description Column header for the operation name.
   */
  operation: 'Operation',
  /**
   * @description Column header for the GraphQL or tRPC call type.
   */
  call: 'Call',
  /**
   * @description Column header for the HTTP status.
   */
  status: 'Status',
  /**
   * @description Column header for the URL path.
   */
  path: 'Path',
  /**
   * @description Badge on an operation whose JSON response contains errors.
   */
  errors: 'errors',
  /**
   * @description Status shown before any GraphQL or tRPC call has been recorded.
   */
  empty: 'No API operations yet',
  /**
   * @description Explanation shown before any GraphQL or tRPC call has been recorded.
   */
  emptyDetail: 'Calls show up here with the operation name, the call type, and a red marker when the response JSON has errors',
  /**
   * @description Status shown when the current filter matches nothing.
   */
  noMatch: 'No operations match this filter',
  /**
   * @description Sentence shown for an operation whose JSON response contains errors. HTTP status is separate.
   */
  responseHasErrors: 'Response has errors',
  /**
   * @description Button that reveals the selected request in the Network panel.
   */
  openInNetwork: 'Open in Network',
  /**
   * @description Button that copies the operation name and call type.
   */
  copyName: 'Copy name',
  /**
   * @description Announcement after the operation name is copied.
   */
  copied: 'Copied the operation name',
  /**
   * @description Status shown while a request has no HTTP status yet.
   */
  pending: 'Pending',
  /**
   * @description Status shown when the network log cannot be read.
   */
  logUnavailable: 'The network log isn’t available',
  /**
   * @description Accessible name for the operation list.
   */
  list: 'API operations',
  /**
   * @description Accessible name for an operation whose response JSON has errors.
   * @example {Continents · query} PH1
   */
  rowWithErrors: '{PH1}. Response has errors.',
} as const;

const str_ = i18n.i18n.registerUIStrings('panels/shaar/graphql-trpc/APIOperationsPanel.ts', UIStrings);
const i18nString = i18n.i18n.getLocalizedString.bind(undefined, str_);

const PAGE_STEP = 8;

interface OperationRow {
  request: SDK.NetworkRequest.NetworkRequest;
  operation: APIOperation;
}

export class APIOperationsPanel extends UI.Panel.Panel {
  #attached = false;
  #watch: APIOperationWatch|null = null;
  #listeners: Common.EventTarget.EventDescriptor[] = [];
  #ids = new WeakMap<SDK.NetworkRequest.NetworkRequest, string>();
  #idCounter = 0;
  #filter: APIFilter = 'all';
  #search = '';
  #selected: SDK.NetworkRequest.NetworkRequest|null = null;
  #banner: string|null = null;
  #scrollSelection = false;

  constructor() {
    super('shaar-graphql-trpc', /* useShadowDom */ true);
    this.requestUpdate();
  }

  override wasShown(): void {
    super.wasShown();
    this.#attach();
  }

  override onDetach(): void {
    super.onDetach();
    Common.EventTarget.removeEventListeners(this.#listeners);
    this.#listeners = [];
    this.#attached = false;
    this.#watch = null;
  }

  override performUpdate(): void {
    const visible = this.#visibleRows();
    const selected = visible.find(row => row.request === this.#selected) ?? null;
    const selectedId = selected ? this.#idFor(selected.request) : '';
    const errorCount = visible.reduce((count, row) => count + (row.operation.hasErrors ? 1 : 0), 0);
    const listKey = this.#onListKey;
    const rowClick = this.#onRowClick;
    const view = (_input: undefined, _output: undefined, target: HTMLElement): void => {
    void _input;
    void _output;
    // clang-format off
    render(html`
      <style>${panelCSS()}</style>
      <div class="api" @keydown=${this.#onPanelKey}>
        <header class="api-header">
          <div class="api-heading">
            <span class="api-mark" aria-hidden="true"></span>
            <h1 class="api-title">${i18nString(UIStrings.title)}</h1>
          </div>
          <p class="api-count">
            <span>${i18nString(UIStrings.operationCount, {PH1: String(visible.length)})}</span>
            ${errorCount > 0 ? html`<span class="api-count-errors">${i18nString(UIStrings.errorCount, {PH1: String(errorCount)})}</span>` : nothing}
          </p>
        </header>
        <p class="api-lede">${i18nString(UIStrings.lede)}</p>
        <div class="api-toolbar">
          <input class="api-search" type="search" spellcheck="false" autocomplete="off"
            placeholder=${i18nString(UIStrings.search)}
            aria-label=${i18nString(UIStrings.search)}
            .value=${this.#search}
            @input=${this.#onSearch}>
          <fieldset class="api-filters" @change=${this.#onFilter}>
            <legend class="api-legend">${i18nString(UIStrings.filter)}</legend>
            ${filterChoice('all', i18nString(UIStrings.all), this.#filter)}
            ${filterChoice('graphql', i18nString(UIStrings.graphql), this.#filter)}
            ${filterChoice('trpc', i18nString(UIStrings.trpc), this.#filter)}
            ${filterChoice('errors', i18nString(UIStrings.errorsFilter), this.#filter)}
          </fieldset>
        </div>
        ${this.#banner ? html`<p class="api-banner" role="alert">${this.#banner}</p>` : nothing}
        ${visible.length === 0 ? emptyState((this.#watch?.operations().size ?? 0) === 0) : html`
          <div class="api-head" aria-hidden="true">
            <span>${i18nString(UIStrings.operation)}</span>
            <span>${i18nString(UIStrings.call)}</span>
            <span>${i18nString(UIStrings.status)}</span>
            <span>${i18nString(UIStrings.path)}</span>
          </div>
          <div class="api-list" role="listbox" tabindex="0" aria-label=${i18nString(UIStrings.list)}
            aria-activedescendant=${selectedId} @keydown=${listKey}>
            ${visible.map(row => rowTemplate(row, this.#idFor(row.request), row.request === this.#selected, rowClick))}
          </div>
        `}
        ${selected ? detailTemplate(selected, this.#openSelected, this.#copySelected) : nothing}
      </div>
    `, target);
    // clang-format on
    };
    view(undefined, undefined, this.contentElement);
    if (this.#scrollSelection) {
      this.#scrollSelection = false;
      this.contentElement.querySelector('.api-row.selected')?.scrollIntoView({block: 'nearest'});
    }
  }

  #attach(): void {
    if (this.#attached) {
      return;
    }
    try {
      this.#watch = installAPIOperationWatch();
    } catch (error) {
      this.#banner = error instanceof Error && error.message ? error.message : i18nString(UIStrings.logUnavailable);
      this.requestUpdate();
      return;
    }
    this.#attached = true;
    this.#listeners = [
      this.#watch.addEventListener(WatchEvents.Changed, this.#onChanged),
    ];
    this.#onChanged();
  }

  #onChanged = (): void => {
    if (this.#selected && !this.#watch?.operations().has(this.#selected)) {
      this.#selected = null;
    }
    this.requestUpdate();
  };

  #visibleRows(): OperationRow[] {
    const rows: OperationRow[] = [];
    for (const [request, operation] of this.#watch?.operations() ?? []) {
      if (operationMatches(operation, this.#filter, this.#search)) {
        rows.push({request, operation});
      }
    }
    return rows;
  }

  #idFor(request: SDK.NetworkRequest.NetworkRequest): string {
    const existing = this.#ids.get(request);
    if (existing) {
      return existing;
    }
    const id = `shaar-api-op-${++this.#idCounter}`;
    this.#ids.set(request, id);
    return id;
  }

  #onSearch = (event: Event): void => {
    if (!(event.target instanceof HTMLInputElement)) {
      return;
    }
    this.#search = event.target.value;
    this.requestUpdate();
  };

  #onFilter = (event: Event): void => {
    if (!(event.target instanceof HTMLInputElement)) {
      return;
    }
    const value = event.target.value;
    if (value === 'all' || value === 'graphql' || value === 'trpc' || value === 'errors') {
      this.#filter = value;
      this.requestUpdate();
    }
  };

  #onPanelKey = (event: KeyboardEvent): void => {
    if (event.key !== '/' || event.metaKey || event.ctrlKey || event.altKey) {
      return;
    }
    if (event.target instanceof HTMLInputElement || event.target instanceof HTMLTextAreaElement) {
      return;
    }
    event.preventDefault();
    this.contentElement.querySelector<HTMLInputElement>('.api-search')?.focus();
  };

  #onListKey = (event: KeyboardEvent): void => {
    const visible = this.#visibleRows();
    if (event.key === 'ArrowDown' || event.key === 'ArrowUp' || event.key === 'PageDown' || event.key === 'PageUp') {
      event.preventDefault();
      this.#move(keyDelta(event.key), visible);
      return;
    }
    if (event.key === 'Home' || event.key === 'End') {
      event.preventDefault();
      if (visible.length === 0) {
        return;
      }
      const next = event.key === 'Home' ? 0 : visible.length - 1;
      this.#selected = visible[next].request;
      this.#scrollSelection = true;
      this.requestUpdate();
      return;
    }
    if (event.key === 'Enter') {
      event.preventDefault();
      this.#revealSelected();
      return;
    }
    if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === 'c') {
      event.preventDefault();
      this.#copySelected();
    }
  };

  #move(delta: number, visible: OperationRow[]): void {
    const current = this.#selected ? visible.findIndex(row => row.request === this.#selected) : -1;
    const next = moveIndex(visible.length, current, delta);
    this.#selected = next < 0 ? null : visible[next].request;
    this.#scrollSelection = true;
    this.requestUpdate();
  }

  #onRowClick = (event: Event): void => {
    const element = event.currentTarget;
    if (!(element instanceof HTMLElement)) {
      return;
    }
    const id = element.dataset.rowId;
    const match = this.#visibleRows().find(row => this.#idFor(row.request) === id);
    if (!match) {
      return;
    }
    this.#selected = match.request;
    this.requestUpdate();
    void this.#open(match.request);
  };

  #openSelected = (): void => {
    this.#revealSelected();
  };

  #copySelected = (): void => {
    if (!this.#selected) {
      return;
    }
    const operation = this.#watch?.operations().get(this.#selected);
    if (!operation) {
      return;
    }
    try {
      UI.UIUtils.copyTextToClipboard(columnText(operation), i18nString(UIStrings.copied));
    } catch (error) {
      this.#banner = error instanceof Error ? error.message : String(error);
      this.requestUpdate();
    }
  };

  #revealSelected(): void {
    if (this.#selected) {
      void this.#open(this.#selected);
    }
  }

  async #open(request: SDK.NetworkRequest.NetworkRequest): Promise<void> {
    try {
      await Common.Revealer.reveal(request);
      if (this.#banner) {
        this.#banner = null;
        this.requestUpdate();
      }
    } catch (error) {
      this.#banner = error instanceof Error ? error.message : String(error);
      this.requestUpdate();
    }
  }
}

function emptyState(noCalls: boolean): TemplateResult {
  if (noCalls) {
    return html`
      <div class="api-empty" role="status">
        <p class="api-empty-title">${i18nString(UIStrings.empty)}</p>
        <p>${i18nString(UIStrings.emptyDetail)}</p>
      </div>`;
  }
  return html`<p class="api-empty" role="status">${i18nString(UIStrings.noMatch)}</p>`;
}

function filterChoice(value: APIFilter, label: string, selected: APIFilter): TemplateResult {
  const errors = value === 'errors' ? ' errors' : '';
  return html`
    <label class="api-choice${errors}">
      <input type="radio" name="shaar-api-filter" value=${value} ?checked=${selected === value}>
      <span>${label}</span>
    </label>`;
}

function rowTemplate(
    row: OperationRow, id: string, selected: boolean, onClick: (event: Event) => void): TemplateResult {
  const operation = row.operation;
  const classes = ['api-row', operation.callType];
  if (selected) {
    classes.push('selected');
  }
  if (operation.hasErrors) {
    classes.push('errors');
  }
  const text = columnText(operation);
  const label = operation.hasErrors ? i18nString(UIStrings.rowWithErrors, {PH1: text}) : text;
  // Red is the JSON errors marker. The HTTP status stays in its own column.
  return html`
    <div class=${classes.join(' ')} id=${id} role="option" aria-selected=${selected} aria-label=${label}
      data-row-id=${id} title=${text} @click=${onClick}>
      <span class="api-operation">
        <span class="api-name">${operation.name}</span>
        ${operation.hasErrors ? html`<span class="api-badge">${i18nString(UIStrings.errors)}</span>` : nothing}
      </span>
      <span class="api-pill ${operation.callType}">${callLabel(operation)}</span>
      <span class="api-status">${statusText(row.request)}</span>
      <span class="api-path" title=${row.request.pathname}>${row.request.pathname}</span>
    </div>`;
}

function detailTemplate(row: OperationRow, open: () => void, copy: () => void): TemplateResult {
  const operation = row.operation;
  return html`
    <div class="api-detail ${operation.hasErrors ? 'errors' : ''}">
      <p class="api-detail-name">${columnText(operation)}</p>
      <p class="api-detail-meta">${row.request.requestMethod} ${statusText(row.request)} ${row.request.pathname}</p>
      ${operation.hasErrors ? html`<p class="api-detail-error">${i18nString(UIStrings.responseHasErrors)}</p>` : nothing}
      <div class="api-detail-actions">
        <button class="api-button primary" type="button" @click=${open}>${i18nString(UIStrings.openInNetwork)}</button>
        <button class="api-button" type="button" @click=${copy}>${i18nString(UIStrings.copyName)}</button>
      </div>
    </div>`;
}

function keyDelta(key: string): number {
  if (key === 'ArrowDown') {
    return 1;
  }
  if (key === 'ArrowUp') {
    return -1;
  }
  if (key === 'PageDown') {
    return PAGE_STEP;
  }
  return -PAGE_STEP;
}

function statusText(request: SDK.NetworkRequest.NetworkRequest): string {
  if (!request.finished && request.statusCode === 0) {
    return i18nString(UIStrings.pending);
  }
  if (request.statusCode === 0) {
    return '—';
  }
  return String(request.statusCode);
}

function panelCSS(): string {
  return `
    .api {
      box-sizing: border-box;
      height: 100%;
      overflow: auto;
      padding: 0 0 16px;
      color: var(--sys-color-on-surface);
      background: var(--sys-color-cdt-base);
      border-top: 3px solid var(--shaar-accent, var(--sys-color-primary));
      font-family: var(--default-font-family);
      font-size: 12px;
      line-height: 1.4;
    }
    .api-header, .api-lede, .api-toolbar, .api-banner, .api-empty, .api-detail {
      padding-left: 14px;
      padding-right: 14px;
    }
    .api-header {
      display: flex;
      gap: 12px;
      align-items: baseline;
      justify-content: space-between;
      padding-top: 12px;
    }
    .api-heading {
      display: flex;
      gap: 8px;
      align-items: center;
      min-width: 0;
    }
    .api-mark {
      width: 8px;
      height: 8px;
      flex: 0 0 auto;
      border-radius: 2px;
      background: var(--shaar-accent, var(--sys-color-primary));
    }
    .api-title {
      margin: 0;
      font-size: 14px;
      font-weight: 680;
      letter-spacing: -0.01em;
    }
    .api-count {
      display: flex;
      gap: 8px;
      margin: 0;
      color: var(--sys-color-on-surface-subtle);
      font-variant-numeric: tabular-nums;
      white-space: nowrap;
    }
    .api-count-errors {
      color: var(--sys-color-error);
      font-weight: 680;
    }
    .api-lede {
      margin: 2px 0 0;
      color: var(--sys-color-on-surface-subtle);
    }
    .api-toolbar {
      display: flex;
      flex-wrap: wrap;
      gap: 8px;
      align-items: center;
      margin-top: 10px;
    }
    .api-search {
      flex: 1 1 12em;
      min-width: 0;
      box-sizing: border-box;
      border: 1px solid var(--sys-color-divider-prominent);
      border-radius: 4px;
      background: var(--sys-color-cdt-base-container);
      color: var(--sys-color-on-surface);
      padding: 4px 8px;
      font: inherit;
    }
    .api-search:focus-visible,
    .api-list:focus-visible,
    .api-button:focus-visible,
    .api-choice input:focus-visible + span {
      outline: 2px solid var(--sys-color-state-focus-ring);
      outline-offset: 2px;
    }
    .api-filters {
      display: flex;
      gap: 4px;
      margin: 0;
      padding: 0;
      border: 0;
    }
    .api-legend {
      position: absolute;
      width: 1px;
      height: 1px;
      overflow: hidden;
      clip: rect(0 0 0 0);
    }
    .api-choice {
      position: relative;
    }
    .api-choice input {
      position: absolute;
      opacity: 0;
      pointer-events: none;
    }
    .api-choice span {
      display: inline-block;
      border: 1px solid transparent;
      border-radius: 999px;
      padding: 2px 8px;
      color: var(--sys-color-on-surface-subtle);
    }
    .api-choice input:checked + span {
      background: var(--sys-color-tonal-container);
      color: var(--sys-color-on-tonal-container);
      font-weight: 680;
    }
    .api-choice.errors input:checked + span {
      background: var(--sys-color-error);
      color: var(--sys-color-cdt-base);
    }
    .api-banner {
      margin: 10px 14px 0;
      padding: 8px 10px;
      border-radius: 6px;
      border-left: 3px solid var(--sys-color-error);
      background: var(--sys-color-surface2);
      color: var(--sys-color-error);
    }
    .api-empty {
      margin: 14px 0 0;
      padding: 16px;
      border: 1px dashed var(--sys-color-divider-prominent);
      border-radius: 8px;
      color: var(--sys-color-on-surface-subtle);
    }
    .api-empty-title {
      margin: 0 0 4px;
      color: var(--sys-color-on-surface);
      font-weight: 680;
    }
    .api-empty p {
      margin: 0;
    }
    .api-head, .api-row {
      display: grid;
      grid-template-columns: minmax(0, 1.7fr) 7.6em 5.2em minmax(0, 1.2fr);
      gap: 8px;
      align-items: center;
    }
    .api-head {
      position: sticky;
      top: 0;
      z-index: 1;
      margin-top: 10px;
      padding: 4px 14px;
      background: var(--sys-color-cdt-base);
      color: var(--sys-color-on-surface-subtle);
      font-size: 10px;
      font-weight: 700;
      letter-spacing: 0.04em;
      text-transform: uppercase;
    }
    .api-list {
      display: flex;
      flex-direction: column;
      padding: 0 8px;
    }
    .api-row {
      margin: 0;
      padding: 4px 6px;
      border-radius: 4px;
      cursor: pointer;
    }
    .api-row:hover {
      background: var(--sys-color-surface2);
    }
    .api-row.selected {
      background: var(--sys-color-state-focus-select);
    }
    .api-row.errors {
      box-shadow: inset 3px 0 0 var(--sys-color-error);
    }
    .api-row.errors .api-name {
      color: var(--sys-color-error);
      font-weight: 680;
    }
    .api-operation {
      display: flex;
      gap: 6px;
      align-items: center;
      min-width: 0;
    }
    .api-name, .api-path {
      overflow: hidden;
      text-overflow: ellipsis;
      white-space: nowrap;
    }
    .api-name {
      font-family: ui-monospace, monospace;
    }
    .api-badge {
      flex: 0 0 auto;
      border-radius: 999px;
      padding: 0 6px;
      background: var(--sys-color-error);
      color: var(--sys-color-cdt-base);
      font-size: 10px;
      font-weight: 700;
      letter-spacing: 0.03em;
      text-transform: uppercase;
    }
    .api-pill {
      justify-self: start;
      border: 1px solid var(--sys-color-divider);
      border-radius: 999px;
      padding: 0 7px;
      background: var(--sys-color-neutral-container);
      color: var(--sys-color-on-surface);
      font-size: 10px;
      font-weight: 700;
      letter-spacing: 0.03em;
      text-transform: lowercase;
    }
    .api-pill.query {
      border-color: transparent;
      background: var(--sys-color-tonal-container);
      color: var(--sys-color-on-tonal-container);
    }
    .api-pill.mutation {
      border-color: var(--shaar-accent, var(--sys-color-primary));
      background: transparent;
      color: var(--sys-color-primary);
    }
    .api-pill.subscription {
      border-color: var(--sys-color-divider-prominent);
    }
    .api-status {
      font-variant-numeric: tabular-nums;
    }
    .api-path {
      color: var(--sys-color-on-surface-subtle);
      font-family: ui-monospace, monospace;
    }
    .api-detail {
      margin: 10px 14px 0;
      padding: 8px 10px;
      border: 1px solid var(--sys-color-divider);
      border-radius: 6px;
      background: var(--sys-color-surface2);
    }
    .api-detail.errors {
      border-left: 3px solid var(--sys-color-error);
    }
    .api-detail-name {
      margin: 0;
      font-family: ui-monospace, monospace;
      font-weight: 680;
    }
    .api-detail-meta, .api-detail-error {
      margin: 2px 0 0;
    }
    .api-detail-meta {
      color: var(--sys-color-on-surface-subtle);
      font-family: ui-monospace, monospace;
    }
    .api-detail-error {
      color: var(--sys-color-error);
      font-weight: 680;
    }
    .api-detail-actions {
      display: flex;
      flex-wrap: wrap;
      gap: 6px;
      margin-top: 8px;
    }
    .api-button {
      appearance: none;
      border: 1px solid var(--sys-color-divider-prominent);
      border-radius: 4px;
      background: var(--sys-color-cdt-base-container);
      color: var(--sys-color-on-surface);
      padding: 4px 10px;
      font: inherit;
    }
    .api-button.primary {
      border-color: transparent;
      background: var(--sys-color-tonal-container);
      color: var(--sys-color-on-tonal-container);
      font-weight: 680;
    }
    @media (prefers-reduced-motion: reduce) {
      .api-row, .api-button, .api-choice span {
        transition: none;
      }
    }
  `;
}
