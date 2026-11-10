// Copyright 2026 The Shaar Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import * as Common from '../../../core/common/common.js';
import * as i18n from '../../../core/i18n/i18n.js';
import * as SDK from '../../../core/sdk/sdk.js';
import * as UI from '../../../ui/legacy/legacy.js';
import {html, nothing, render} from '../../../ui/lit/lit.js';

import {
  actionFor,
  clearStagedCommands,
  cloneRule,
  createRule,
  type ExchangeDocument,
  exchangeText,
  type FetchAgentLike,
  type HeaderEntry,
  installFetchRewrite,
  importRules,
  interceptionPatterns,
  type NetworkRule,
  type RuleError,
  type RuleKind,
  headerEntries,
  KINDS,
  MAX_BYTES,
  MAX_ENABLED,
  MAX_HEADERS,
  METHODS,
  normalized,
  parseExchangeValue,
  siteOrigin,
  stageCommand,
  takeCommand,
  validate,
} from './NetworkRules.js';

const UIStrings = {
  /**
   * @description Title of the Shaar network rules drawer.
   */
  networkRules: 'Network rules',
  /**
   * @description Command for showing the Shaar network rules drawer.
   */
  showNetworkRules: 'Show Network rules',
  /**
   * @description Label for how many saved rules are turned on.
   * @example {2} PH1
   */
  rulesOn: '{PH1} on',
  /**
   * @description Button that adds a network rule.
   */
  newRule: 'New',
  /**
   * @description Button that imports a JSON rules file. The file replaces this site\'s saved rules.
   */
  importJson: 'Import',
  /**
   * @description Button that downloads the saved rules as JSON.
   */
  exportJson: 'Export',
  /**
   * @description Help text under the toolbar. Import replaces the rules for the inspected site.
   */
  replacesSite: 'Replaces the saved rules for this site.',
  /**
   * @description Empty-state heading when the inspected site has no rules.
   */
  noRules: 'No rules for this site',
  /**
   * @description Empty-state explanation of the five rule actions.
   */
  noRulesDetail: 'Mock a response, redirect a URL, delay a request, or rewrite headers. The first exact method and URL wins.',
  /**
   * @description Heading when DevTools is not inspecting a web page.
   */
  openPage: 'Open a page',
  /**
   * @description Explanation that rules are stored per site.
   */
  openPageDetail: 'Rules follow the site you are inspecting and stay on while DevTools is open.',
  /**
   * @description Accessible name of the saved-rules list.
   */
  savedRules: 'Saved rules',
  /**
   * @description Keyboard hint under the rule list.
   */
  keys: 'Arrows move, Space toggles, Enter edits, Delete removes',
  /**
   * @description Accessible name for turning a rule on.
   */
  turnOn: 'Turn rule on',
  /**
   * @description Accessible name for turning a rule off.
   */
  turnOff: 'Turn rule off',
  /**
   * @description Kind label for a mocked response.
   */
  mock: 'Mock',
  /**
   * @description Kind label for a redirect.
   */
  redirect: 'Redirect',
  /**
   * @description Kind label for a delay.
   */
  delay: 'Delay',
  /**
   * @description Kind label for request header edits.
   */
  requestHeaders: 'Request headers',
  /**
   * @description Kind label for response header edits.
   */
  responseHeaders: 'Response headers',
  /**
   * @description Delay amount in milliseconds.
   * @example {400} PH1
   */
  milliseconds: '{PH1} ms',
  /**
   * @description How many headers a rule sets when there is exactly one.
   */
  headerCountOne: '1 header',
  /**
   * @description How many headers a rule sets.
   * @example {2} PH1
   */
  headerCount: '{PH1} headers',
  /**
   * @description Heading of the editor for a rule that is not saved yet.
   */
  newRuleTitle: 'New rule',
  /**
   * @description Heading of the editor for a saved rule.
   */
  editRuleTitle: 'Edit rule',
  /**
   * @description Label for the HTTP method field.
   */
  method: 'Method',
  /**
   * @description Label for the request URL field.
   */
  url: 'URL',
  /**
   * @description Label for the rule action field.
   */
  action: 'Action',
  /**
   * @description Label for the mock status code.
   */
  status: 'Status',
  /**
   * @description Label for the mock response body.
   */
  body: 'Body',
  /**
   * @description Label for the redirect destination.
   */
  redirectTo: 'Redirect to',
  /**
   * @description Label for the delay in milliseconds.
   */
  delayMs: 'Delay (ms)',
  /**
   * @description Label for the header list.
   */
  headers: 'Headers',
  /**
   * @description Label for a header name field.
   */
  headerName: 'Name',
  /**
   * @description Label for a header value field.
   */
  headerValue: 'Value',
  /**
   * @description Button that adds a header row.
   */
  addHeader: 'Add header',
  /**
   * @description Button that removes a header row.
   */
  removeHeader: 'Remove header',
  /**
   * @description Button that saves the rule being edited.
   */
  save: 'Save',
  /**
   * @description Button that closes the editor without saving.
   */
  cancel: 'Cancel',
  /**
   * @description Button that deletes the rule being edited.
   */
  remove: 'Remove',
  /**
   * @description Error when the URL or method is not an exact HTTP request.
   */
  invalidMatch: 'Use an exact HTTP or HTTPS request URL and method.',
  /**
   * @description Error when a rule action has a value outside its range.
   */
  invalidAction: 'Check the rule action and its values.',
  /**
   * @description Error when header names or values are rejected.
   */
  invalidHeaders: 'Header names and values must be valid and bounded.',
  /**
   * @description Error when the JSON file is not a saved rules document.
   */
  invalidDocument: 'The rules file must contain saved network rules.',
  /**
   * @description Error when more than 32 rules would be turned on.
   */
  tooMany: 'At most 32 rules can be on for a site.',
  /**
   * @description Shown when DevTools cannot store the rules.
   */
  couldNotSave: 'Could not store these rules.',
} as const;

const str_ = i18n.i18n.registerUIStrings('panels/shaar/network-rules/NetworkRulesView.ts', UIStrings);
const i18nString = i18n.i18n.getLocalizedString.bind(undefined, str_);

const SETTING = 'shaar.network-rules';

export const PANEL_STYLE = `
.rules {
  display: flex;
  flex-direction: column;
  height: 100%;
  min-height: 0;
  color: var(--sys-color-on-surface);
  background: var(--sys-color-cdt-base);
  font-family: var(--default-font-family);
  font-size: 12px;
}
.toolbar, .editor, .hint, .banner {
  flex: none;
}
.toolbar {
  display: flex;
  align-items: center;
  gap: 8px;
  padding: 8px 10px;
  border-bottom: 1px solid var(--sys-color-divider);
  background: var(--sys-color-surface2, var(--sys-color-cdt-base-container));
}
.title {
  display: flex;
  flex-direction: column;
  min-width: 0;
  margin-right: auto;
}
.title strong {
  font-size: 13px;
  font-weight: 650;
  letter-spacing: -0.01em;
}
.origin {
  color: var(--sys-color-on-surface-subtle);
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
  max-width: 28em;
}
.count {
  color: var(--sys-color-on-tonal-container);
  background: var(--sys-color-tonal-container);
  border-radius: 99px;
  padding: 1px 7px;
  font-variant-numeric: tabular-nums;
}
.actions {
  display: flex;
  gap: 4px;
}
button, input, select, textarea {
  font: inherit;
  color: inherit;
}
button {
  border: 1px solid var(--sys-color-outline);
  background: transparent;
  border-radius: 6px;
  padding: 3px 8px;
  cursor: pointer;
}
button:focus-visible, input:focus-visible, select:focus-visible, textarea:focus-visible, .list:focus-visible {
  outline: 2px solid var(--sys-color-state-focus-ring);
  outline-offset: 1px;
}
button.primary {
  background: var(--sys-color-primary);
  border-color: var(--sys-color-primary);
  color: var(--sys-color-on-primary);
  font-weight: 600;
}
button:disabled {
  opacity: 0.45;
  cursor: default;
}
.banner {
  margin: 8px 10px 0;
  padding: 6px 8px;
  border-radius: 6px;
  background: var(--sys-color-error-container);
  color: var(--sys-color-on-error, var(--sys-color-error));
}
.list {
  flex: 1;
  min-height: 72px;
  overflow: auto;
  padding: 4px;
}
.row {
  display: grid;
  grid-template-columns: 28px minmax(0, 1fr);
  gap: 6px;
  align-items: center;
  width: 100%;
  text-align: left;
  border: 1px solid transparent;
  border-radius: 6px;
  padding: 3px 4px;
  background: transparent;
}
.row.on {
  box-shadow: inset 2px 0 0 var(--sys-color-primary);
}
.row.selected {
  background: var(--sys-color-state-focus-select);
}
.row:hover {
  background: var(--sys-color-state-hover-on-subtle);
}
.main {
  display: grid;
  grid-template-columns: 4.2em max-content minmax(0, 1fr) auto;
  gap: 8px;
  align-items: center;
  width: 100%;
  border: 0;
  background: transparent;
  padding: 2px 4px;
  text-align: left;
  cursor: pointer;
}
.method, .kind, .detail {
  font-family: var(--monospace-font-family, ui-monospace, monospace);
  font-size: 11px;
}
.method {
  color: var(--sys-color-on-surface-subtle);
}
.kind {
  color: var(--sys-color-on-tonal-container);
  background: var(--sys-color-tonal-container);
  border-radius: 4px;
  padding: 1px 5px;
  justify-self: start;
  white-space: nowrap;
}
.url, .detail {
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}
.detail {
  color: var(--sys-color-on-surface-subtle);
  max-width: 16em;
}
.row:not(.on) .main {
  opacity: 0.72;
}
.switch {
  width: 28px;
  height: 16px;
  border-radius: 8px;
  padding: 0;
  position: relative;
  border: 1px solid var(--sys-color-outline);
  background: transparent;
}
.switch::after {
  content: "";
  position: absolute;
  width: 12px;
  height: 12px;
  border-radius: 50%;
  top: 1px;
  left: 1px;
  background: var(--sys-color-on-surface-subtle);
}
.switch[aria-checked="true"] {
  background: var(--sys-color-primary);
  border-color: var(--sys-color-primary);
}
.switch[aria-checked="true"]::after {
  left: 13px;
  background: var(--sys-color-on-primary);
}
.empty {
  margin: 28px 16px;
  max-width: 36em;
}
.empty h2 {
  margin: 0 0 4px;
  font-size: 14px;
}
.empty p {
  margin: 0;
  color: var(--sys-color-on-surface-subtle);
  line-height: 1.4;
}
.hint {
  padding: 4px 10px 6px;
  color: var(--sys-color-on-surface-subtle);
  border-top: 1px solid var(--sys-color-divider);
}
.editor {
  border-top: 1px solid var(--sys-color-divider);
  padding: 8px 10px 10px;
  display: grid;
  grid-template-columns: 7em minmax(0, 1fr);
  gap: 6px 8px;
  background: var(--sys-color-surface1, var(--sys-color-cdt-base));
  max-height: 46%;
  overflow: auto;
}
.editor h2 {
  grid-column: 1 / -1;
  margin: 0;
  font-size: 12px;
}
label {
  align-self: center;
  color: var(--sys-color-on-surface-subtle);
}
input, select, textarea {
  border: 1px solid var(--sys-color-divider-prominent, var(--sys-color-outline));
  background: var(--sys-color-cdt-base-container, var(--sys-color-cdt-base));
  border-radius: 4px;
  padding: 3px 6px;
  min-width: 0;
}
textarea {
  min-height: 64px;
  resize: vertical;
  font-family: var(--monospace-font-family, ui-monospace, monospace);
}
.header-row, .editor-actions {
  grid-column: 2;
  display: flex;
  gap: 4px;
}
.header-row input {
  flex: 1;
}
.editor-actions {
  grid-column: 1 / -1;
  position: sticky;
  bottom: 0;
  margin-top: 2px;
  padding-top: 6px;
  background: var(--sys-color-surface1, var(--sys-color-cdt-base));
}
.file {
  display: none;
}
`;

interface StoredRules {
  schemaVersion: 1;
  sites: Record<string, unknown>;
}

export class NetworkRulesView extends UI.Widget.VBox {
  #setting: Common.Settings.Setting<StoredRules>;
  #origin: string|null|undefined = undefined;
  #rules: NetworkRule[] = [];
  #selectedId: string|null = null;
  #draft: NetworkRule|null = null;
  #failure: string|null = null;
  #targetObserver: SDK.TargetManager.Observer = {
    targetAdded: target => {
      this.#bridgeTarget(target);
    },
    targetRemoved: () => {},
  };
  #onURLChanged = (): void => {
    this.#adoptPage();
  };

  constructor() {
    super({useShadowDom: true, delegatesFocus: true});
    this.#setting = Common.Settings.Settings.instance().createSetting(SETTING, {schemaVersion: 1, sites: {}});
    SDK.TargetManager.TargetManager.instance().observeTargets(this.#targetObserver);
    SDK.TargetManager.TargetManager.instance().addEventListener(
        SDK.TargetManager.Events.INSPECTED_URL_CHANGED, this.#onURLChanged, this);
    for (const target of SDK.TargetManager.TargetManager.instance().targets()) {
      this.#bridgeTarget(target);
    }
    this.#adoptPage();
    this.requestUpdate();
  }

  override wasShown(): void {
    super.wasShown();
    this.#adoptPage();
    this.#apply();
  }

  override onDetach(): void {
    super.onDetach();
    this.#install([]);
    clearStagedCommands();
    SDK.TargetManager.TargetManager.instance().unobserveTargets(this.#targetObserver);
    SDK.TargetManager.TargetManager.instance().removeEventListener(
        SDK.TargetManager.Events.INSPECTED_URL_CHANGED, this.#onURLChanged, this);
  }

  override performUpdate(): void {
    const enabled = this.#rules.filter(rule => rule.enabled).length;
    const origin = this.#origin ?? null;
    const draft = this.#draft;
    // clang-format off
    render(html`
      <style>${PANEL_STYLE}</style>
      <section class="rules" @keydown=${this.#onKey}>
        <div class="toolbar">
          <div class="title">
            <strong>${i18nString(UIStrings.networkRules)}</strong>
            <span class="origin">${origin ?? i18nString(UIStrings.openPage)}</span>
          </div>
          <span class="count">${i18nString(UIStrings.rulesOn, {PH1: enabled})}</span>
          <div class="actions">
            <button class="primary" type="button" ?disabled=${!origin} @click=${() => this.#startNew()}>${i18nString(UIStrings.newRule)}</button>
            <button type="button" title=${i18nString(UIStrings.replacesSite)} ?disabled=${!origin} @click=${() => this.#pickFile()}>${i18nString(UIStrings.importJson)}</button>
            <button type="button" ?disabled=${!origin || this.#rules.length === 0} @click=${() => this.#export()}>${i18nString(UIStrings.exportJson)}</button>
            <input class="file" type="file" accept="application/json,.json" @change=${(event: Event) => this.#import(event)} />
          </div>
        </div>
        ${this.#failure ? html`<div class="banner" role="alert">${this.#failure}</div>` : nothing}
        <div class="list" role="listbox" tabindex="0" aria-label=${i18nString(UIStrings.savedRules)}
             aria-activedescendant=${this.#selectedId ? `rule-${this.#selectedId}` : nothing}>
          ${this.#rules.length === 0 ? this.#empty(origin) : this.#rules.map(rule => this.#row(rule))}
        </div>
        <div class="hint">${origin ? i18nString(UIStrings.keys) : i18nString(UIStrings.replacesSite)}</div>
        ${draft ? this.#editor(draft) : nothing}
      </section>
    `, this.contentElement);
    // clang-format on
  }

  #empty(origin: string|null): ReturnType<typeof html> {
    // clang-format off
    return html`
      <div class="empty">
        <h2>${origin ? i18nString(UIStrings.noRules) : i18nString(UIStrings.openPage)}</h2>
        <p>${origin ? i18nString(UIStrings.noRulesDetail) : i18nString(UIStrings.openPageDetail)}</p>
      </div>
    `;
    // clang-format on
  }

  #row(rule: NetworkRule): ReturnType<typeof html> {
    const selected = rule.id === this.#selectedId;
    // clang-format off
    return html`
      <div class="row ${rule.enabled ? 'on' : ''} ${selected ? 'selected' : ''}" role="option"
           id=${`rule-${rule.id}`} aria-selected=${selected ? 'true' : 'false'}>
        <button class="switch" type="button" role="switch" tabindex="-1"
                aria-checked=${rule.enabled ? 'true' : 'false'}
                aria-label=${rule.enabled ? i18nString(UIStrings.turnOff) : i18nString(UIStrings.turnOn)}
                @click=${(event: Event) => this.#toggle(rule, event)}></button>
        <button class="main" type="button" tabindex="-1" @click=${() => this.#edit(rule)}>
          <span class="method">${rule.method}</span>
          <span class="kind">${this.#kindLabel(rule.kind)}</span>
          <span class="url" title=${rule.url}>${rule.url}</span>
          <span class="detail" title=${this.#detail(rule)}>${this.#detail(rule)}</span>
        </button>
      </div>
    `;
    // clang-format on
  }

  #editor(draft: NetworkRule): ReturnType<typeof html> {
    const saved = this.#rules.some(rule => rule.id === draft.id);
    const showHeaders = draft.kind === 'mock' || draft.kind === 'requestHeaders' || draft.kind === 'responseHeaders';
    // clang-format off
    return html`
      <form class="editor" @submit=${(event: Event) => { event.preventDefault(); this.#save(); }}>
        <h2>${saved ? i18nString(UIStrings.editRuleTitle) : i18nString(UIStrings.newRuleTitle)}</h2>
        <label for="shaar-rule-method">${i18nString(UIStrings.method)}</label>
        <select id="shaar-rule-method" @change=${(event: Event) => this.#patch({method: this.#input(event)}, true)}>
          ${METHODS.map(method => html`<option value=${method} ?selected=${method === draft.method}>${method}</option>`)}
        </select>
        <label for="shaar-rule-url">${i18nString(UIStrings.url)}</label>
        <input id="shaar-rule-url" spellcheck="false" .value=${draft.url}
               @input=${(event: Event) => this.#patch({url: this.#input(event)})} />
        <label for="shaar-rule-kind">${i18nString(UIStrings.action)}</label>
        <select id="shaar-rule-kind" @change=${(event: Event) => this.#patch({kind: this.#input(event) as RuleKind}, true)}>
          ${KINDS.map(kind => html`<option value=${kind} ?selected=${kind === draft.kind}>${this.#kindLabel(kind)}</option>`)}
        </select>
        ${draft.kind === 'mock' ? html`
          <label for="shaar-rule-status">${i18nString(UIStrings.status)}</label>
          <input id="shaar-rule-status" type="number" min="100" max="599" .value=${String(draft.status)}
                 @input=${(event: Event) => this.#patch({status: Number(this.#input(event))})} />
          <label for="shaar-rule-body">${i18nString(UIStrings.body)}</label>
          <textarea id="shaar-rule-body" spellcheck="false" .value=${draft.bodyText}
                    @input=${(event: Event) => this.#patch({bodyText: this.#input(event)})}></textarea>
        ` : nothing}
        ${draft.kind === 'redirect' ? html`
          <label for="shaar-rule-redirect">${i18nString(UIStrings.redirectTo)}</label>
          <input id="shaar-rule-redirect" spellcheck="false" .value=${draft.redirectURL}
                 @input=${(event: Event) => this.#patch({redirectURL: this.#input(event)})} />
        ` : nothing}
        ${draft.kind === 'delay' ? html`
          <label for="shaar-rule-delay">${i18nString(UIStrings.delayMs)}</label>
          <input id="shaar-rule-delay" type="number" min="0" max="30000" .value=${String(draft.delayMilliseconds)}
                 @input=${(event: Event) => this.#patch({delayMilliseconds: Number(this.#input(event))})} />
        ` : nothing}
        ${showHeaders ? html`
          <label>${i18nString(UIStrings.headers)}</label>
          <div></div>
          ${draft.headers.map((header, index) => html`
            <div class="header-row">
              <input aria-label=${i18nString(UIStrings.headerName)} spellcheck="false" .value=${header.name}
                     @input=${(event: Event) => this.#patchHeader(index, {name: this.#input(event)})} />
              <input aria-label=${i18nString(UIStrings.headerValue)} spellcheck="false" .value=${header.value}
                     @input=${(event: Event) => this.#patchHeader(index, {value: this.#input(event)})} />
              <button type="button" aria-label=${i18nString(UIStrings.removeHeader)} @click=${() => this.#removeHeader(index)}>−</button>
            </div>
          `)}
          <div class="header-row">
            <button type="button" ?disabled=${draft.headers.length >= MAX_HEADERS} @click=${() => this.#addHeader()}>${i18nString(UIStrings.addHeader)}</button>
          </div>
        ` : nothing}
        <div class="editor-actions">
          <button class="primary" type="submit">${i18nString(UIStrings.save)}</button>
          <button type="button" @click=${() => this.#closeEditor()}>${i18nString(UIStrings.cancel)}</button>
          ${saved ? html`<button type="button" @click=${() => this.#remove(draft.id)}>${i18nString(UIStrings.remove)}</button>` : nothing}
        </div>
      </form>
    `;
    // clang-format on
  }

  #adoptPage(): void {
    const origin = siteOrigin(SDK.TargetManager.TargetManager.instance().inspectedURL() || '');
    if (origin === this.#origin) {
      return;
    }
    this.#origin = origin;
    this.#selectedId = null;
    this.#draft = null;
    this.#failure = null;
    this.#load();
    this.#apply();
    this.requestUpdate();
  }

  #load(): void {
    if (!this.#origin) {
      this.#rules = [];
      return;
    }
    const stored = this.#sites()[this.#origin];
    if (stored === undefined) {
      this.#rules = [];
      return;
    }
    const parsed = parseExchangeValue(stored);
    if (!parsed.ok) {
      this.#rules = [];
      this.#failure = this.#errorText(parsed.error);
      return;
    }
    this.#rules = parsed.rules;
  }

  #apply(): void {
    if (!this.#origin) {
      this.#install([]);
      return;
    }
    const enabled = this.#rules.filter(rule => rule.enabled);
    if (enabled.length > MAX_ENABLED) {
      this.#failure = i18nString(UIStrings.tooMany);
      this.#install([]);
      return;
    }
    this.#install(interceptionPatterns(enabled));
  }

  #install(patterns: ReturnType<typeof interceptionPatterns>): void {
    const manager = SDK.NetworkManager.MultitargetNetworkManager.instance();
    void manager.setInterceptionHandlerForPatterns(
        patterns as SDK.NetworkManager.InterceptionPattern[], this.#onIntercepted);
  }

  #onIntercepted = async (intercepted: SDK.NetworkManager.InterceptedRequest): Promise<void> => {
    if (intercepted.hasResponded()) {
      return;
    }
    const rules = this.#rules.filter(rule => rule.enabled);
    const paused = {
      url: intercepted.request.url,
      method: intercepted.request.method,
      responseStage: intercepted.responseStatusCode !== undefined || intercepted.responseHeaders !== undefined,
      statusCode: intercepted.responseStatusCode,
      requestHeaders: headerEntries(intercepted.request.headers),
      responseHeaders: intercepted.responseHeaders,
    };
    const action = actionFor(String(intercepted.requestId), rules, paused);
    if (action.kind === 'ignore') {
      return;
    }
    if (action.kind === 'delay' && action.milliseconds > 0) {
      await new Promise(resolve => setTimeout(resolve, action.milliseconds));
    }
    if (intercepted.hasResponded()) {
      return;
    }
    if (action.kind === 'rewrite') {
      stageCommand(String(intercepted.requestId), action.command);
    }
    intercepted.continueRequestWithoutChange();
  };

  #bridgeTarget(target: SDK.Target.Target): void {
    try {
      installFetchRewrite(target.fetchAgent() as unknown as FetchAgentLike, takeCommand);
    } catch {
      // A target without Fetch is not a page we can rewrite.
    }
  }

  #sites(): Record<string, unknown> {
    const value = this.#setting.get();
    if (!value || typeof value !== 'object' || !value.sites || typeof value.sites !== 'object') {
      return {};
    }
    return value.sites;
  }

  #persist(rules: NetworkRule[]): boolean {
    if (!this.#origin) {
      return false;
    }
    const exchanged = exchangeText(rules);
    if (!exchanged.ok) {
      this.#failure = this.#errorText(exchanged.error);
      this.requestUpdate();
      return false;
    }
    let document: ExchangeDocument;
    try {
      document = JSON.parse(exchanged.text) as ExchangeDocument;
    } catch {
      this.#failure = i18nString(UIStrings.invalidDocument);
      this.requestUpdate();
      return false;
    }
    const sites = {...this.#sites(), [this.#origin]: document};
    try {
      this.#setting.set({schemaVersion: 1, sites});
    } catch {
      this.#failure = i18nString(UIStrings.couldNotSave);
      this.requestUpdate();
      return false;
    }
    this.#rules = rules;
    this.#failure = null;
    this.#apply();
    this.requestUpdate();
    return true;
  }

  #startNew(): void {
    if (!this.#origin) {
      return;
    }
    const draft = createRule(crypto.randomUUID());
    const inspected = SDK.TargetManager.TargetManager.instance().inspectedURL() || '';
    const page = inspected.split('#')[0];
    if (page && siteOrigin(page) === this.#origin) {
      draft.url = page;
    }
    this.#draft = draft;
    this.#selectedId = draft.id;
    this.#failure = null;
    this.requestUpdate();
  }

  #edit(rule: NetworkRule): void {
    this.#selectedId = rule.id;
    this.#draft = cloneRule(rule);
    this.#failure = null;
    this.requestUpdate();
  }

  #closeEditor(): void {
    this.#draft = null;
    this.requestUpdate();
  }

  #patch(fields: Partial<NetworkRule>, refresh = false): void {
    if (!this.#draft) {
      return;
    }
    this.#draft = {...this.#draft, ...fields};
    if (refresh) {
      this.requestUpdate();
    }
  }

  #patchHeader(index: number, fields: Partial<HeaderEntry>): void {
    if (!this.#draft) {
      return;
    }
    const headers = this.#draft.headers.map((header, item) => item === index ? {...header, ...fields} : header);
    this.#patch({headers});
  }

  #addHeader(): void {
    if (!this.#draft || this.#draft.headers.length >= MAX_HEADERS) {
      return;
    }
    this.#patch({headers: [...this.#draft.headers, {name: '', value: ''}]}, true);
  }

  #removeHeader(index: number): void {
    if (!this.#draft) {
      return;
    }
    this.#patch({headers: this.#draft.headers.filter((_, item) => item !== index)}, true);
  }

  #save(): void {
    if (!this.#draft) {
      return;
    }
    const rule = normalized(this.#draft);
    const error = validate(rule);
    if (error) {
      this.#failure = this.#errorText(error);
      this.requestUpdate();
      return;
    }
    const next = this.#rules.some(item => item.id === rule.id) ?
        this.#rules.map(item => item.id === rule.id ? rule : item) :
        [...this.#rules, rule];
    if (next.filter(item => item.enabled).length > MAX_ENABLED) {
      this.#failure = i18nString(UIStrings.tooMany);
      this.requestUpdate();
      return;
    }
    if (!this.#persist(next)) {
      return;
    }
    this.#draft = null;
    this.#selectedId = rule.id;
    this.requestUpdate();
  }

  #toggle(rule: NetworkRule, event: Event): void {
    event.stopPropagation();
    const enabled = !rule.enabled;
    if (enabled && this.#rules.filter(item => item.enabled).length >= MAX_ENABLED) {
      this.#failure = i18nString(UIStrings.tooMany);
      this.requestUpdate();
      return;
    }
    const next = this.#rules.map(item => item.id === rule.id ? {...item, enabled} : item);
    this.#selectedId = rule.id;
    this.#persist(next);
  }

  #remove(id: string): void {
    const next = this.#rules.filter(rule => rule.id !== id);
    if (this.#persist(next)) {
      this.#draft = null;
      this.#selectedId = null;
    }
  }

  #export(): void {
    const exchanged = exchangeText(this.#rules);
    if (!exchanged.ok) {
      this.#failure = this.#errorText(exchanged.error);
      this.requestUpdate();
      return;
    }
    const blob = new Blob([exchanged.text], {type: 'application/json'});
    const url = URL.createObjectURL(blob);
    const anchor = document.createElement('a');
    anchor.href = url;
    anchor.download = 'network-rules.json';
    anchor.click();
    URL.revokeObjectURL(url);
  }

  #pickFile(): void {
    const input = this.contentElement.querySelector<HTMLInputElement>('.file');
    input?.click();
  }

  #import(event: Event): void {
    const input = event.target;
    if (!(input instanceof HTMLInputElement) || !input.files?.length) {
      return;
    }
    const file = input.files[0];
    input.value = '';
    if (file.size > MAX_BYTES) {
      this.#failure = i18nString(UIStrings.invalidDocument);
      this.requestUpdate();
      return;
    }
    const reader = new FileReader();
    reader.onload = () => {
      const text = typeof reader.result === 'string' ? reader.result : '';
      const parsed = importRules(text);
      if (!parsed.ok) {
        this.#failure = this.#errorText(parsed.error);
        this.requestUpdate();
        return;
      }
      this.#draft = null;
      this.#selectedId = null;
      this.#persist(parsed.rules);
    };
    reader.onerror = () => {
      this.#failure = i18nString(UIStrings.invalidDocument);
      this.requestUpdate();
    };
    reader.readAsText(file);
  }

  #onKey = (event: KeyboardEvent): void => {
    const target = event.target;
    const typing = target instanceof HTMLInputElement || target instanceof HTMLTextAreaElement ||
        target instanceof HTMLSelectElement;
    if (event.key === 'Escape') {
      this.#closeEditor();
      event.preventDefault();
      return;
    }
    if (typing) {
      return;
    }
    const list = this.contentElement.querySelector('.list');
    if (!list || !(target instanceof Node) || !list.contains(target)) {
      if (event.key === 'n' && !event.metaKey && !event.ctrlKey && !event.altKey) {
        this.#startNew();
        event.preventDefault();
      }
      return;
    }
    const index = this.#rules.findIndex(rule => rule.id === this.#selectedId);
    if (event.key === 'ArrowDown' || event.key === 'ArrowUp') {
      const delta = event.key === 'ArrowDown' ? 1 : -1;
      const next = this.#rules[Math.max(0, Math.min(this.#rules.length - 1, index + delta))] ?? this.#rules[0];
      if (next) {
        this.#selectedId = next.id;
        this.requestUpdate();
      }
      event.preventDefault();
      return;
    }
    const selected = this.#rules.find(rule => rule.id === this.#selectedId);
    if (!selected) {
      return;
    }
    if (event.key === ' ') {
      this.#toggle(selected, event);
      event.preventDefault();
    } else if (event.key === 'Enter') {
      this.#edit(selected);
      event.preventDefault();
    } else if (event.key === 'Delete' || event.key === 'Backspace') {
      this.#remove(selected.id);
      event.preventDefault();
    }
  };

  #input(event: Event): string {
    const target = event.target;
    return target instanceof HTMLInputElement || target instanceof HTMLTextAreaElement ||
            target instanceof HTMLSelectElement ?
        target.value :
        '';
  }

  #kindLabel(kind: RuleKind): string {
    switch (kind) {
      case 'mock':
        return i18nString(UIStrings.mock);
      case 'redirect':
        return i18nString(UIStrings.redirect);
      case 'delay':
        return i18nString(UIStrings.delay);
      case 'requestHeaders':
        return i18nString(UIStrings.requestHeaders);
      case 'responseHeaders':
        return i18nString(UIStrings.responseHeaders);
    }
  }

  #detail(rule: NetworkRule): string {
    switch (rule.kind) {
      case 'mock':
        return String(rule.status);
      case 'redirect':
        return rule.redirectURL;
      case 'delay':
        return i18nString(UIStrings.milliseconds, {PH1: rule.delayMilliseconds});
      case 'requestHeaders':
      case 'responseHeaders':
        return rule.headers.length === 1 ? i18nString(UIStrings.headerCountOne) :
                                            i18nString(UIStrings.headerCount, {PH1: rule.headers.length});
    }
  }

  #errorText(error: RuleError): string {
    switch (error) {
      case 'match':
        return i18nString(UIStrings.invalidMatch);
      case 'action':
        return i18nString(UIStrings.invalidAction);
      case 'headers':
        return i18nString(UIStrings.invalidHeaders);
      case 'document':
        return i18nString(UIStrings.invalidDocument);
      case 'limit':
        return i18nString(UIStrings.tooMany);
    }
  }
}
