// Copyright 2026 The Shaar Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import * as i18n from '../../../core/i18n/i18n.js';
import * as UI from '../../../ui/legacy/legacy.js';
import {html, nothing, render} from '../../../ui/lit/lit.js';

import {
  byteSize,
  packetAccepts,
  samePage,
  type Packet,
  type PacketScope,
  type PageStamp,
} from './AgentPacket.js';
import {AgentPacketCollectError, collectAgentPacket, readPageStamp} from './AgentPacketCollect.js';

const UIStrings = {
  /**
   * @description Title of the Copy for agent panel.
   */
  title: 'Copy for agent',
  /**
   * @description Short description under the panel title.
   */
  lede: 'A redacted packet for the selected element or the page.',
  /**
   * @description Accessible name for the element-or-page scope control.
   */
  scope: 'Scope',
  /**
   * @description Scope that copies the element selected in Elements.
   */
  element: 'Selected element',
  /**
   * @description Scope that copies the page.
   */
  page: 'Page',
  /**
   * @description Button that builds the agent packet.
   */
  build: 'Build packet',
  /**
   * @description Button that copies the packet to the clipboard.
   */
  copy: 'Copy',
  /**
   * @description Status shown while the packet is being built.
   */
  building: 'Building…',
  /**
   * @description Empty-state heading before a packet exists.
   */
  emptyTitle: 'Nothing copied yet',
  /**
   * @description Empty-state body before a packet exists.
   */
  emptyBody: 'Choose a scope and build a packet. Cookie, Authorization, and Set-Cookie are removed.',
  /**
   * @description Status shown when no page is open.
   */
  noPage: 'Open a page, then build the packet.',
  /**
   * @description Status shown when no element is selected.
   */
  noSelection: 'Select an element in Elements, or copy the page.',
  /**
   * @description Status shown when the packet could not be built.
   */
  unavailable: 'The agent packet is unavailable.',
  /**
   * @description Status shown when the packet is ready to copy.
   */
  ready: 'Packet ready.',
  /**
   * @description Status shown after the packet is copied.
   */
  copied: 'The packet is on the clipboard.',
  /**
   * @description Status shown when a secret would still be copied.
   */
  secret: 'The packet still contained a secret, so it was not copied.',
  /**
   * @description Status shown when the page changed after the packet was built.
   */
  changed: 'The page changed. Build the packet again.',
  /**
   * @description Label for the packet size, shown before copy.
   */
  size: 'Packet size',
  /**
   * @description Label for the winning CSS count.
   */
  rules: 'Winning CSS',
  /**
   * @description Label for the console error count.
   */
  errors: 'Console errors',
  /**
   * @description Label for the failed request count.
   */
  requests: 'Failed requests',
  /**
   * @description Label for the node screenshot.
   */
  screenshot: 'Screenshot',
  /**
   * @description Shown when the screenshot was not captured.
   */
  omitted: 'Omitted',
  /**
   * @description Label for the source location.
   */
  source: 'Source',
  /**
   * @description Accessible name for the packet preview.
   */
  preview: 'Packet preview',
  /**
   * @description Alt text for the node screenshot.
   */
  shotAlt: 'Node screenshot',
} as const;

const str_ = i18n.i18n.registerUIStrings('panels/shaar/copy-for-agent/CopyForAgentPanel.ts', UIStrings);
const i18nString = i18n.i18n.getLocalizedString.bind(undefined, str_);

type StatusTone = 'info'|'ok'|'error';

export class CopyForAgentPanel extends UI.Panel.Panel {
  #scope: PacketScope = 'element';
  #running = false;
  #tone: StatusTone = 'info';
  #status = '';
  #packet: Packet|null = null;
  #stamp: PageStamp|null = null;
  #png = '';
  #focusScope = false;

  constructor() {
    super('shaar-copy-for-agent', /* useShadowDom */ true);
    this.requestUpdate();
  }

  override performUpdate(): void {
    const packet = this.#packet;
    const built = packet !== null;
    const canCopy = built && !this.#running && packetAccepts(packet.markdown);
    // clang-format off
    render(html`
      <style>
        .agent {
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
        .agent-title {
          margin: 0;
          font-size: 15px;
          font-weight: 650;
          letter-spacing: -0.01em;
        }
        .agent-mark {
          width: 28px;
          height: 3px;
          margin: 6px 0 0;
          border-radius: 2px;
          background: var(--sys-color-primary);
        }
        .agent-lede {
          margin: 8px 0 0;
          color: var(--sys-color-on-surface-subtle);
        }
        .agent-toolbar {
          display: flex;
          flex-wrap: wrap;
          gap: 6px;
          align-items: center;
          margin-top: 12px;
        }
        .agent-scope {
          display: inline-flex;
          border: 1px solid var(--sys-color-divider-prominent);
          border-radius: 6px;
          overflow: hidden;
        }
        .agent-button {
          appearance: none;
          box-sizing: border-box;
          border: 1px solid var(--sys-color-divider-prominent);
          border-radius: 6px;
          background: var(--sys-color-cdt-base-container);
          color: var(--sys-color-on-surface);
          padding: 4px 10px;
          font: inherit;
        }
        .agent-scope .agent-button {
          border: 0;
          border-radius: 0;
          background: transparent;
        }
        .agent-scope .agent-button[aria-checked="true"] {
          background: var(--sys-color-tonal-container);
          color: var(--sys-color-on-tonal-container);
          font-weight: 650;
        }
        .agent-button.primary {
          background: var(--sys-color-primary);
          color: var(--sys-color-on-primary);
          border-color: transparent;
          font-weight: 650;
        }
        .agent-button:disabled {
          opacity: 0.55;
        }
        .agent-button:focus-visible {
          outline: 2px solid var(--sys-color-state-focus-ring);
          outline-offset: 2px;
        }
        .agent-size {
          margin-left: auto;
          color: var(--sys-color-primary);
          font-weight: 650;
          font-variant-numeric: tabular-nums;
        }
        .agent-size span,
        .agent-stat dd {
          font-variant-numeric: tabular-nums;
        }
        .agent-size-label {
          margin-right: 6px;
          color: var(--sys-color-on-surface-subtle);
          font-weight: 450;
        }
        .agent-status {
          margin: 10px 0 0;
        }
        .agent-status.ok {
          color: var(--sys-color-primary);
          font-weight: 650;
        }
        .agent-status.error {
          padding: 8px 10px;
          border-radius: 6px;
          border-left: 3px solid var(--sys-color-error);
          background: var(--sys-color-surface2);
          color: var(--sys-color-error);
        }
        .agent-stats {
          display: grid;
          grid-template-columns: repeat(4, minmax(0, 1fr));
          gap: 6px;
          margin: 10px 0 0;
        }
        .agent-stat {
          margin: 0;
          padding: 6px 8px;
          border-radius: 6px;
          background: var(--sys-color-surface2);
          border: 1px solid var(--sys-color-divider);
        }
        .agent-stat dt {
          color: var(--sys-color-on-surface-subtle);
          font-size: 10px;
          letter-spacing: 0.02em;
          text-transform: uppercase;
        }
        .agent-stat dd {
          margin: 2px 0 0;
          font-weight: 650;
        }
        .agent-source {
          margin: 8px 0 0;
          color: var(--sys-color-on-surface-subtle);
        }
        .agent-source code {
          color: var(--sys-color-on-surface);
          font-family: ui-monospace, monospace;
        }
        .agent-empty {
          margin-top: 14px;
          padding: 16px 14px;
          border: 1px dashed var(--sys-color-divider-prominent);
          border-radius: 8px;
          background: var(--sys-color-surface1);
        }
        .agent-empty h2 {
          margin: 0;
          font-size: 13px;
          font-weight: 650;
        }
        .agent-empty p {
          margin: 4px 0 0;
          color: var(--sys-color-on-surface-subtle);
        }
        .agent-preview {
          margin: 10px 0 0;
          padding: 10px 12px;
          max-height: 320px;
          overflow: auto;
          border-radius: 8px;
          border: 1px solid var(--sys-color-divider);
          background: var(--sys-color-surface2);
          color: var(--sys-color-on-surface);
          font-family: ui-monospace, monospace;
          font-size: 11px;
          line-height: 1.45;
          white-space: pre-wrap;
        }
        .agent-shot {
          display: block;
          margin-top: 10px;
          max-width: min(100%, 360px);
          max-height: 180px;
          border-radius: 8px;
          border: 1px solid var(--sys-color-divider);
          background: var(--sys-color-surface1);
        }
        @media (max-width: 560px) {
          .agent-stats {
            grid-template-columns: repeat(2, minmax(0, 1fr));
          }
        }
      </style>
      <section class="agent" aria-busy=${this.#running ? 'true' : 'false'}>
        <h1 class="agent-title">${i18nString(UIStrings.title)}</h1>
        <div class="agent-mark"></div>
        <p class="agent-lede">${i18nString(UIStrings.lede)}</p>
        <div class="agent-toolbar">
          <div class="agent-scope" role="radiogroup" aria-label=${i18nString(UIStrings.scope)}
               @keydown=${this.#onScopeKey}>
            ${this.#scopeButton('element', UIStrings.element)}
            ${this.#scopeButton('page', UIStrings.page)}
          </div>
          <button class="agent-button ${built ? '' : 'primary'}" type="button" ?disabled=${this.#running}
                  @click=${this.#build}>
            ${i18nString(UIStrings.build)}
          </button>
          <button class="agent-button ${built ? 'primary' : ''}" type="button" ?disabled=${!canCopy}
                  @click=${this.#copy}>
            ${i18nString(UIStrings.copy)}
          </button>
          <div class="agent-size">
            <span class="agent-size-label">${i18nString(UIStrings.size)}</span>
            ${built ? byteSize(packet.bytes) : '—'}
          </div>
        </div>
        ${this.#status ? html`<p class="agent-status ${this.#tone}" role="status">${this.#status}</p>` : nothing}
        ${built ? html`
          <dl class="agent-stats">
            <div class="agent-stat">
              <dt>${i18nString(UIStrings.rules)}</dt>
              <dd>${packet.stylesOmitted ? i18nString(UIStrings.omitted) : String(packet.rules.length)}</dd>
            </div>
            <div class="agent-stat">
              <dt>${i18nString(UIStrings.errors)}</dt>
              <dd>${packet.consoleRecording ? String(packet.errors.length) : i18nString(UIStrings.omitted)}</dd>
            </div>
            <div class="agent-stat">
              <dt>${i18nString(UIStrings.requests)}</dt>
              <dd>${String(packet.requests.length)}</dd>
            </div>
            <div class="agent-stat">
              <dt>${i18nString(UIStrings.screenshot)}</dt>
              <dd>${packet.screenshotBytes > 0 ? byteSize(packet.screenshotBytes) : i18nString(UIStrings.omitted)}</dd>
            </div>
          </dl>
          ${packet.source ? html`
            <p class="agent-source">${i18nString(UIStrings.source)} <code>${packet.source}</code></p>
          ` : nothing}
          <pre class="agent-preview" aria-label=${i18nString(UIStrings.preview)}>${packet.markdown}</pre>
          ${this.#png ? html`
            <img class="agent-shot" alt=${i18nString(UIStrings.shotAlt)} src=${`data:image/png;base64,${this.#png}`} />
          ` : nothing}
        ` : nothing}
        ${built || this.#tone === 'error' ? nothing : html`
          <div class="agent-empty">
            <h2>${i18nString(UIStrings.emptyTitle)}</h2>
            <p>${i18nString(UIStrings.emptyBody)}</p>
          </div>
        `}
      </section>
    `, this.contentElement);
    // clang-format on
    if (this.#focusScope) {
      this.#focusScope = false;
      this.contentElement.querySelector<HTMLElement>('[role="radio"][aria-checked="true"]')?.focus();
    }
  }

  #scopeButton(scope: PacketScope, label: typeof UIStrings.element|typeof UIStrings.page) {
    const selected = this.#scope === scope;
    return html`
      <button
        class="agent-button"
        role="radio"
        type="button"
        aria-checked=${selected ? 'true' : 'false'}
        tabindex=${selected ? '0' : '-1'}
        @click=${() => this.#chooseScope(scope)}>
        ${i18nString(label)}
      </button>
    `;
  }

  #chooseScope = (scope: PacketScope): void => {
    if (this.#scope === scope) {
      return;
    }
    this.#scope = scope;
    this.requestUpdate();
  };

  #onScopeKey = (event: KeyboardEvent): void => {
    if (event.key !== 'ArrowLeft' && event.key !== 'ArrowRight' && event.key !== 'ArrowUp' &&
        event.key !== 'ArrowDown') {
      return;
    }
    event.preventDefault();
    this.#scope = this.#scope === 'element' ? 'page' : 'element';
    this.#focusScope = true;
    this.requestUpdate();
  };

  #build = async (): Promise<void> => {
    if (this.#running) {
      return;
    }
    this.#running = true;
    this.#tone = 'info';
    this.#status = i18nString(UIStrings.building);
    this.requestUpdate();
    try {
      const collected = await collectAgentPacket(this.#scope);
      if (!packetAccepts(collected.packet.markdown)) {
        this.#clearPacket();
        this.#tone = 'error';
        this.#status = i18nString(UIStrings.secret);
        return;
      }
      this.#packet = collected.packet;
      this.#stamp = collected.stamp;
      this.#png = collected.pngBase64;
      this.#tone = 'ok';
      this.#status = i18nString(UIStrings.ready);
    } catch (error) {
      this.#tone = 'error';
      if (error instanceof AgentPacketCollectError && error.code === 'no-selection') {
        this.#status = i18nString(UIStrings.noSelection);
      } else if (error instanceof AgentPacketCollectError && error.code === 'no-page') {
        this.#status = i18nString(UIStrings.noPage);
      } else {
        this.#status = i18nString(UIStrings.unavailable);
      }
    } finally {
      this.#running = false;
      this.requestUpdate();
    }
  };

  #copy = (): void => {
    const packet = this.#packet;
    const stamp = this.#stamp;
    if (!packet || this.#running) {
      return;
    }
    if (!packetAccepts(packet.markdown)) {
      this.#clearPacket();
      this.#tone = 'error';
      this.#status = i18nString(UIStrings.secret);
      this.requestUpdate();
      return;
    }
    const current = readPageStamp();
    if (!stamp || !current || !samePage(stamp, current)) {
      this.#tone = 'error';
      this.#status = i18nString(UIStrings.changed);
      this.requestUpdate();
      return;
    }
    UI.UIUtils.copyTextToClipboard(packet.markdown, i18nString(UIStrings.copied));
    this.#tone = 'ok';
    this.#status = i18nString(UIStrings.copied);
    this.requestUpdate();
  };

  #clearPacket(): void {
    this.#packet = null;
    this.#stamp = null;
    this.#png = '';
  }
}
