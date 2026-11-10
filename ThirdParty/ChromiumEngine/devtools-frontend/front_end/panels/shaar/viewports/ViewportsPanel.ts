// Copyright 2026 The Shaar Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import * as i18n from '../../../core/i18n/i18n.js';
import * as UI from '../../../ui/legacy/legacy.js';
import {Directives, html, nothing, render, type TemplateResult} from '../../../ui/lit/lit.js';

import viewportsStyles from './viewports.css.js';
import {EmbedderViewportHost, type ViewportHost} from './ViewportsHost.js';
import {
  cardWidth,
  type ColorScheme,
  contentSize,
  nextScheme,
  PRESET_IDS,
  type PresetId,
  presetSpec,
  previewSize,
  projectPoint,
  ViewportController,
  type ViewportFrame,
} from './ViewportsModel.js';

const UIStrings = {
  /**
   * @description Accessible name of the address field.
   */
  address: 'Address',
  /**
   * @description Button that loads the address in every viewport.
   */
  go: 'Go',
  /**
   * @description Button that toggles fitting every viewport into the panel.
   */
  fit: 'Fit',
  /**
   * @description Menu that adds another device viewport. The maximum is four.
   */
  addViewport: 'Add viewport',
  /**
   * @description Button that copies one image of every viewport.
   */
  screenshotAll: 'Screenshot all',
  /**
   * @description Menu that sets prefers-color-scheme on every viewport.
   */
  matchColorScheme: 'Match color scheme',
  /**
   * @description Placeholder for text typed into every viewport.
   */
  typeInAllViews: 'Type in all views',
  /**
   * @description Short explanation under the toolbar.
   */
  syncNote: 'Navigation, scroll, and clicks stay mirrored. Light and dark can sit side by side.',
  /**
   * @description Heading shown before any viewport is open.
   */
  emptyTitle: 'See this page at several sizes',
  /**
   * @description Empty state body.
   */
  emptyBody: 'Add a phone and a desktop, then scroll or click once. Each size is a real page.',
  /**
   * @description Heading shown while the viewport lease is opening.
   */
  connectingTitle: 'Opening viewports',
  /**
   * @description Status shown while the viewport lease is opening.
   */
  connectingBody: 'Starting a phone and a desktop for this page',
  /**
   * @description Heading shown when the viewport host is unavailable.
   */
  errorTitle: 'Viewports aren’t connected',
  /**
   * @description Error state body.
   */
  errorBody: 'This DevTools window couldn’t open a viewport session for the page',
  /**
   * @description Button that tries to open the viewport session again.
   */
  retry: 'Try again',
  /**
   * @description Confirmation after the contact sheet is copied.
   */
  copied: 'Copied viewport screenshots',
  /**
   * @description Status when no viewport has a screenshot yet.
   */
  notReady: 'Viewport screenshots aren’t ready',
  /**
   * @description Status when a viewport action was rejected.
   */
  invalid: 'That viewport action isn’t available',
  /**
   * @description Status when a viewport action failed on the host.
   */
  failed: 'The viewport action failed',
  /**
   * @description Button that rotates one viewport.
   */
  rotate: 'Rotate',
  /**
   * @description Button that removes one viewport.
   */
  remove: 'Remove',
  /**
   * @description Color scheme that follows the device.
   */
  device: 'Device',
  /**
   * @description Light color scheme.
   */
  light: 'Light',
  /**
   * @description Dark color scheme.
   */
  dark: 'Dark',
  /**
   * @description iPhone 15 Pro preset name.
   */
  iphone15Pro: 'iPhone 15 Pro',
  /**
   * @description iPad preset name.
   */
  ipad: 'iPad',
  /**
   * @description Pixel 8 preset name.
   */
  pixel8: 'Pixel 8',
  /**
   * @description Desktop preset at 1280 CSS pixels wide.
   */
  desktop: 'Desktop 1280',
  /**
   * @description Desktop preset at 1440 CSS pixels wide.
   */
  desktop1440: 'Desktop 1440',
  /**
   * @description Viewport size in CSS pixels.
   * @example {393} PH1
   * @example {852} PH2
   */
  size: '{PH1} × {PH2}',
  /**
   * @description Accessible name for a viewport's color scheme control.
   * @example {iPhone 15 Pro} PH1
   */
  colorSchemeOf: '{PH1} color scheme',
  /**
   * @description Accessible name for one device card.
   * @example {iPhone 15 Pro} PH1
   * @example {393 × 852} PH2
   */
  cardLabel: '{PH1}, {PH2}',
} as const;

const str_ = i18n.i18n.registerUIStrings('panels/shaar/viewports/ViewportsPanel.ts', UIStrings);
const i18nString = i18n.i18n.getLocalizedString.bind(undefined, str_);

const PRESET_TITLES: Record<PresetId, () => string> = {
  iphone15Pro: () => i18nString(UIStrings.iphone15Pro),
  ipad: () => i18nString(UIStrings.ipad),
  pixel8: () => i18nString(UIStrings.pixel8),
  desktop: () => i18nString(UIStrings.desktop),
  desktop1440: () => i18nString(UIStrings.desktop1440),
};

function schemeTitle(scheme: ColorScheme): string {
  if (scheme === 'light') {
    return i18nString(UIStrings.light);
  }
  if (scheme === 'dark') {
    return i18nString(UIStrings.dark);
  }
  return i18nString(UIStrings.device);
}

function isPreset(value: string): value is PresetId {
  return (PRESET_IDS as readonly string[]).includes(value);
}

function isFocused(element: HTMLElement): boolean {
  const root = element.getRootNode();
  if (root instanceof ShadowRoot) {
    return root.activeElement === element;
  }
  return document.activeElement === element;
}

export class ViewportsPanel extends UI.Panel.Panel {
  readonly controller: ViewportController;
  #stageWidth = 960;
  #stageHeight = 520;
  #resizeObserver: ResizeObserver|null = null;
  #stopListening: () => void;

  constructor(host: ViewportHost = new EmbedderViewportHost()) {
    super('shaar-viewports', /* useShadowDom */ true);
    this.controller = new ViewportController(host);
    this.#stopListening = this.controller.listen(() => this.requestUpdate());
    this.registerRequiredCSS(viewportsStyles);
    this.requestUpdate();
  }

  override wasShown(): void {
    super.wasShown();
    void this.controller.open().then(() => {
      if (this.controller.status === 'ready') {
        this.controller.startPolling();
      }
    });
  }

  override willHide(): void {
    this.controller.stopPolling();
    void this.controller.close();
    super.willHide();
  }

  override onDetach(): void {
    this.#resizeObserver?.disconnect();
    this.#stopListening();
    super.onDetach();
  }

  override performUpdate(): void {
    this.#renderView(this.controller, {onWheel: this.#onWheel}, this.contentElement);
  }

  #renderView(input: ViewportController, output: {onWheel: (event: WheelEvent) => void}, target: HTMLElement): void {
    const scale = input.layoutScale({width: this.#stageWidth, height: this.#stageHeight});
    // clang-format off
    render(html`
      <section class="viewports" @wheel=${output.onWheel}>
        ${this.#toolbar()}
        <p class="viewports-note">${i18nString(UIStrings.syncNote)}</p>
        ${this.#banner()}
        ${this.#body(scale)}
      </section>
    `, target);
    // clang-format on
  }

  screenshotLabel(frame: ViewportFrame): string {
    const size = contentSize(frame);
    return `${PRESET_TITLES[frame.preset]()} ${size.width}x${size.height} ${schemeTitle(frame.colorScheme)}`;
  }

  #toolbar(): TemplateResult {
    const controller = this.controller;
    const ready = controller.status === 'ready';
    return html`
      <form class="viewports-toolbar" @submit=${this.#onNavigate}>
        <input class="viewports-url" name="address" type="url" spellcheck="false" aria-label=${
        i18nString(UIStrings.address)}
          placeholder="https://" @input=${this.#onUrlInput} ${Directives.ref(this.#syncUrl)}>
        <button class="viewports-go" type="submit" ?disabled=${!ready}>${i18nString(UIStrings.go)}</button>
        ${this.#schemeMenu()}
        ${this.#typeField()}
        <button class="viewports-shot" type="button" ?disabled=${!ready} @click=${this.#onScreenshot}>
          ${i18nString(UIStrings.screenshotAll)}
        </button>
        <button class="viewports-fit" type="button" aria-pressed=${controller.fitting ? 'true' : 'false'}
          @click=${this.#onFit}>${i18nString(UIStrings.fit)}</button>
        <select class="viewports-add" aria-label=${i18nString(UIStrings.addViewport)} ?disabled=${
    !ready || controller.frames.length >= 4}
          @change=${this.#onAdd}>
          <option value="">${i18nString(UIStrings.addViewport)}</option>
          ${PRESET_IDS.map(id => html`<option value=${id}>${PRESET_TITLES[id]()}</option>`)}
        </select>
      </form>
    `;
  }

  #schemeMenu(): TemplateResult|typeof nothing {
    if (!this.controller.capabilities.colorScheme) {
      return nothing;
    }
    const shared = sharedScheme(this.controller.frames);
    return html`
      <select class="viewports-match" aria-label=${i18nString(UIStrings.matchColorScheme)} @change=${this.#onMirror}>
        <option value="" ?selected=${shared === ''}>${i18nString(UIStrings.matchColorScheme)}</option>
        <option value="noPreference" ?selected=${shared === 'noPreference'}>${i18nString(UIStrings.device)}</option>
        <option value="light" ?selected=${shared === 'light'}>${i18nString(UIStrings.light)}</option>
        <option value="dark" ?selected=${shared === 'dark'}>${i18nString(UIStrings.dark)}</option>
      </select>
    `;
  }

  #typeField(): TemplateResult|typeof nothing {
    if (!this.controller.capabilities.typing) {
      return nothing;
    }
    return html`
      <input class="viewports-type" type="text" maxlength="64" aria-label=${i18nString(UIStrings.typeInAllViews)}
        placeholder=${i18nString(UIStrings.typeInAllViews)} @keydown=${this.#onTypeKey}>
    `;
  }

  #banner(): TemplateResult|typeof nothing {
    const notice = this.controller.notice;
    if (!notice) {
      return nothing;
    }
    return html`<p class="viewports-banner" role="status">${noticeText(notice)}</p>`;
  }

  #body(scale: number): TemplateResult {
    const controller = this.controller;
    if (controller.frames.length > 0) {
      return html`
        <div class="viewports-stage" ${Directives.ref(this.#observeStage)}>
          ${controller.frames.map(frame => this.#card(frame, scale))}
        </div>
      `;
    }
    if (controller.status === 'error') {
      return html`
        <div class="viewports-error">
          <h2>${i18nString(UIStrings.errorTitle)}</h2>
          <p>${i18nString(UIStrings.errorBody)}</p>
          <button class="viewports-retry" type="button" @click=${this.#onRetry}>${i18nString(UIStrings.retry)}</button>
        </div>
      `;
    }
    if (controller.status === 'connecting') {
      return html`
        <div class="viewports-connecting">
          <h2>${i18nString(UIStrings.connectingTitle)}</h2>
          <p>${i18nString(UIStrings.connectingBody)}</p>
        </div>
      `;
    }
    return html`
      <div class="viewports-empty">
        <h2>${i18nString(UIStrings.emptyTitle)}</h2>
        <p>${i18nString(UIStrings.emptyBody)}</p>
      </div>
    `;
  }

  #card(frame: ViewportFrame, scale: number): TemplateResult {
    const size = contentSize(frame);
    const preview = previewSize(size, scale);
    const spec = presetSpec(frame.preset);
    const bezelClass = spec.phone ? 'viewports-bezel phone' : 'viewports-bezel desktop';
    const screenClass = frame.pngBase64 ? 'viewports-screen' : 'viewports-screen pending';
    const label = i18nString(UIStrings.cardLabel, {
      PH1: PRESET_TITLES[frame.preset](),
      PH2: i18nString(UIStrings.size, {PH1: size.width, PH2: size.height}),
    });
    return html`
      <article class="viewports-card" data-viewport-id=${frame.id} style="--card-width: ${
        cardWidth(preview.width)}px" aria-label=${label}>
        <div class="viewports-card-head">
          <div class="viewports-title">
            <strong>${PRESET_TITLES[frame.preset]()}</strong>
            <span>${i18nString(UIStrings.size, {PH1: size.width,
                                                PH2: size.height})} · ${schemeTitle(frame.colorScheme)}</span>
          </div>
          ${this.#schemeButton(frame)}
          <button class="viewports-icon" type="button" aria-label=${i18nString(UIStrings.rotate)}
            @click=${() => void this.controller.rotate(frame.id)}>${i18nString(UIStrings.rotate)}</button>
          <button class="viewports-icon" type="button" aria-label=${i18nString(UIStrings.remove)}
            ?disabled=${this.controller.frames.length <= 1}
            @click=${() => void this.controller.remove(frame.id)}>${i18nString(UIStrings.remove)}</button>
        </div>
        <div class=${bezelClass}>
          <div class=${screenClass} style="--screen-width: ${preview.width}px; --screen-height: ${preview.height}px"
            @click=${(event: MouseEvent) => void this.#onClick(frame, event)}
            @mousemove=${(event: MouseEvent) => void this.#onHover(frame, event)}>
            ${spec.phone && frame.orientation === 'portrait' ? html`<div class="viewports-notch"></div>` : nothing}
            ${frame.pngBase64 ? html`<img alt="" src="data:image/png;base64,${frame.pngBase64}">` : nothing}
          </div>
        </div>
      </article>
    `;
  }

  #schemeButton(frame: ViewportFrame): TemplateResult|typeof nothing {
    if (!this.controller.capabilities.colorScheme) {
      return nothing;
    }
    const title = schemeTitle(frame.colorScheme);
    return html`
      <button class="viewports-icon viewports-scheme ${schemeClass(frame.colorScheme)}"
        type="button" aria-label=${i18nString(UIStrings.colorSchemeOf, {
      PH1: PRESET_TITLES[frame.preset](),
    })}
        @click=${() => void this.controller.setColorScheme(frame.id, nextScheme(frame.colorScheme))}>${title}</button>
    `;
  }

  #syncUrl = (element?: Element): void => {
    if (!(element instanceof HTMLInputElement) || isFocused(element) || element.dataset.dirty === '1') {
      return;
    }
    if (element.value !== this.controller.url) {
      element.value = this.controller.url;
    }
  };

  #observeStage = (element?: Element): void => {
    if (!(element instanceof HTMLElement)) {
      return;
    }
    this.#resizeObserver?.disconnect();
    this.#resizeObserver = new ResizeObserver(() => {
      const width = Math.floor(element.clientWidth);
      const height = Math.floor(element.clientHeight);
      if (width > 0 && height > 0 && (width !== this.#stageWidth || height !== this.#stageHeight)) {
        this.#stageWidth = width;
        this.#stageHeight = height;
        this.requestUpdate();
      }
    });
    this.#resizeObserver.observe(element);
  };

  #onUrlInput = (event: Event): void => {
    const field = event.target;
    if (field instanceof HTMLInputElement) {
      field.dataset.dirty = '1';
      this.controller.markUrlDraft();
    }
  };

  #onNavigate = (event: Event): void => {
    event.preventDefault();
    const form = event.target;
    if (!(form instanceof HTMLFormElement)) {
      return;
    }
    const field = form.elements.namedItem('address');
    if (!(field instanceof HTMLInputElement)) {
      return;
    }
    void this.controller.navigate(field.value).then(() => {
      if (this.controller.notice !== 'invalid' && this.controller.notice !== 'failed') {
        field.dataset.dirty = '';
      }
    });
  };

  #onAdd = (event: Event): void => {
    const select = event.target;
    if (!(select instanceof HTMLSelectElement) || !isPreset(select.value)) {
      return;
    }
    const preset = select.value;
    select.value = '';
    void this.controller.add(preset);
  };

  #onMirror = (event: Event): void => {
    const select = event.target;
    if (!(select instanceof HTMLSelectElement)) {
      return;
    }
    const scheme = select.value;
    if (scheme !== 'noPreference' && scheme !== 'light' && scheme !== 'dark') {
      return;
    }
    void this.controller.mirrorColorScheme(scheme);
  };

  #onTypeKey = (event: KeyboardEvent): void => {
    if (event.key !== 'Enter') {
      return;
    }
    const field = event.target;
    if (!(field instanceof HTMLInputElement)) {
      return;
    }
    event.preventDefault();
    const text = field.value;
    void this.controller.typeIntoAll(text).then(() => {
      if (this.controller.notice !== 'invalid' && this.controller.notice !== 'failed') {
        field.value = '';
      }
    });
  };

  #onFit = (): void => {
    this.controller.setFitting(!this.controller.fitting);
  };

  #onRetry = (): void => {
    void this.controller.close().then(() => this.controller.open());
  };

  #onScreenshot = (): void => {
    void this.controller.copyScreenshots(frame => this.screenshotLabel(frame), writePng);
  };

  #onClick(frame: ViewportFrame, event: MouseEvent): void {
    const point = pointInFrame(frame, event);
    if (!point) {
      return;
    }
    void this.controller.click(frame.id, point.x, point.y);
  }

  #onHover(frame: ViewportFrame, event: MouseEvent): void {
    const point = pointInFrame(frame, event);
    if (!point) {
      return;
    }
    void this.controller.hover(frame.id, point.x, point.y);
  }

  #onWheel = (event: WheelEvent): void => {
    const screen = event.target instanceof Element ? event.target.closest('.viewports-screen') : null;
    const card = screen?.closest('.viewports-card');
    if (!screen || !card) {
      return;
    }
    const id = card.getAttribute('data-viewport-id');
    const frame = id ? this.controller.frames.find(item => item.id === id) : undefined;
    if (!frame) {
      return;
    }
    event.preventDefault();
    const delta = event.deltaMode === WheelEvent.DOM_DELTA_LINE ? 16 : 1;
    void this.controller.scroll(frame.id, event.deltaX * delta, event.deltaY * delta);
  };
}

function schemeClass(scheme: ColorScheme): string {
  if (scheme === 'noPreference') {
    return 'device';
  }
  return scheme;
}

function sharedScheme(frames: ViewportFrame[]): ColorScheme|'' {
  if (frames.length === 0) {
    return '';
  }
  const first = frames[0].colorScheme;
  if (frames.every(frame => frame.colorScheme === first)) {
    return first;
  }
  return '';
}

function pointInFrame(frame: ViewportFrame, event: MouseEvent): {x: number, y: number}|null {
  const screen = event.currentTarget;
  if (!(screen instanceof HTMLElement)) {
    return null;
  }
  const rect = screen.getBoundingClientRect();
  if (rect.width <= 0 || rect.height <= 0) {
    return null;
  }
  const size = contentSize(frame);
  return {
    x: projectPoint(event.clientX - rect.left, rect.width, size.width),
    y: projectPoint(event.clientY - rect.top, rect.height, size.height),
  };
}

async function writePng(blob: Blob): Promise<void> {
  const clipboard = navigator.clipboard;
  if (clipboard && typeof ClipboardItem !== 'undefined') {
    await clipboard.write([new ClipboardItem({'image/png': blob})]);
    return;
  }
  const url = URL.createObjectURL(blob);
  const link = document.createElementNS('http://www.w3.org/1999/xhtml', 'a');
  if (!(link instanceof HTMLAnchorElement)) {
    URL.revokeObjectURL(url);
    throw new Error('unavailable');
  }
  link.href = url;
  link.download = 'shaar-viewports.png';
  link.click();
  URL.revokeObjectURL(url);
}

function noticeText(notice: 'copied'|'notReady'|'invalid'|'failed'): string {
  if (notice === 'copied') {
    return i18nString(UIStrings.copied);
  }
  if (notice === 'notReady') {
    return i18nString(UIStrings.notReady);
  }
  if (notice === 'invalid') {
    return i18nString(UIStrings.invalid);
  }
  return i18nString(UIStrings.failed);
}
