// Copyright 2026 The Shaar Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import * as i18n from '../../../core/i18n/i18n.js';
import * as UI from '../../../ui/legacy/legacy.js';
import {html, render, type TemplateResult} from '../../../ui/lit/lit.js';

import {collectFromInspectedPage, revealInElements, StackingCaptureError} from './StackingCapture.js';
import stackingStyles from './stacking-3d.css.js';
import {
  fittedCamera,
  hitSlab,
  orbitCamera,
  type Point,
  project,
  quad,
  slabsFrom,
  type StackingCamera,
  type StackingElement,
  type StackingMode,
  type StackingSlab,
  type StackingSnapshot,
} from './StackingModel.js';

const UIStrings = {
  /**
   * @description Button that snapshots the page into the 3D stacking view.
   */
  capture: 'Capture snapshot',
  /**
   * @description Button that frames every slab in the 3D view.
   */
  fit: 'Fit',
  /**
   * @description Button that selects the clicked slab in the Elements panel.
   */
  showInElements: 'Show in Elements',
  /**
   * @description Mode that separates slabs by DOM depth.
   */
  dom: 'DOM',
  /**
   * @description Mode that separates slabs by stacking context and z-index.
   */
  zIndex: 'Z-index',
  /**
   * @description Accessible name for the depth mode control.
   */
  depthMode: 'Depth mode',
  /**
   * @description Keyboard hint under the toolbar.
   */
  keys: 'Drag to rotate. Arrows tilt. Click a slab to select it in Elements.',
  /**
   * @description Empty-state heading before a snapshot.
   */
  emptyTitle: 'See depth and stacking',
  /**
   * @description Empty-state explanation.
   */
  emptyBody: 'Capture a snapshot to place each element on its own plane. A negative z-index sits below the page.',
  /**
   * @description Heading when DevTools is not inspecting a page.
   */
  noPageTitle: 'Open a page',
  /**
   * @description Error shown when there is no inspected page.
   */
  noPage: 'Snapshot needs a page',
  /**
   * @description Explanation under the missing-page heading.
   */
  noPageBody: 'Open a page in Shaar, then capture a snapshot of its stacking contexts.',
  /**
   * @description Heading when the DOM snapshot was empty.
   */
  emptySnapshotTitle: 'Nothing to stack',
  /**
   * @description Error shown when the document had no elements.
   */
  emptySnapshot: 'DOM snapshot was empty',
  /**
   * @description Explanation under the empty-snapshot heading.
   */
  emptySnapshotBody: 'The document had no elements to place on a plane.',
  /**
   * @description Error shown when the clicked element is not in the Elements tree.
   */
  notInElements: 'The element is not in the Elements tree yet.',
  /**
   * @description Note when the snapshot stopped early.
   */
  clipped: 'This snapshot stops at the first 180 elements.',
  /**
   * @description Status after a snapshot.
   * @example {8} PH1
   * @example {5} PH2
   */
  summary: '{PH1} elements, {PH2} stacking contexts',
  /**
   * @description Status while the snapshot is loading.
   */
  capturing: 'Capturing…',
  /**
   * @description Accessible name of the slab canvas.
   */
  canvas: 'Stacking view',
  /**
   * @description Accessible name of the stacking-context list.
   */
  contexts: 'Stacking contexts',
  /**
   * @description Label for a slab that is below its parent context.
   */
  below: 'Below',
  /**
   * @description Reason shown for the document root stacking context.
   */
  root: 'Document root',
} as const;

const str_ = i18n.i18n.registerUIStrings('panels/shaar/stacking-3d/StackingPanel.ts', UIStrings);
const i18nString = i18n.i18n.getLocalizedString.bind(undefined, str_);

const PITCH_MIN = 0.2;
const PITCH_MAX = 1.2;
const DRAG_DISTANCE = 6;

type Collector = () => Promise<StackingSnapshot>;
type Selector = (nodeId: number, backendNodeId: number|null) => Promise<boolean>;

export class StackingPanel extends UI.Panel.Panel {
  #collector: Collector;
  #select: Selector;
  #elements: StackingElement[] = [];
  #mode: StackingMode = 'z-index';
  #camera: StackingCamera = orbitCamera();
  #selectedId: number|null = null;
  #captured = false;
  #clipped = false;
  #loading = false;
  #failure: string|null = null;
  #failureCode: 'no-page'|'empty'|null = null;
  #needsFit = false;
  #drag: {x: number, y: number, yaw: number, pitch: number, moved: boolean}|null = null;

  constructor(collector?: Collector, select?: Selector) {
    super('shaar-stacking-3d', /* useShadowDom */ true);
    this.#collector = collector ?? collectFromInspectedPage;
    this.#select = select ?? revealInElements;
    this.registerRequiredCSS(stackingStyles);
    this.requestUpdate();
  }

  override performUpdate(): void {
    const slabs = this.#slabs();
    const selected = slabs.find(slab => slab.nodeId === this.#selectedId) ?? null;
    const statusClass = this.#failure ? 'stacking-status is-error' : 'stacking-status';
    // clang-format off
    render(html`
      <div class="stacking">
        ${toolbar(this.#mode, this.#loading, this.#captured, selected !== null, {
          capture: this.#onCapture,
          fit: this.#onFit,
          show: this.#onShow,
          mode: this.#onMode,
        })}
        <p class=${statusClass} role=${this.#failure ? 'alert' : 'status'}>${this.#status(slabs)}</p>
        <p class="stacking-note" ?hidden=${!this.#clipped}>${i18nString(UIStrings.clipped)}</p>
        ${this.#body(slabs)}
      </div>
    `, this.contentElement);
    // clang-format on
    this.#paint(slabs);
    this.#scheduleFit();
  }

  async capture(): Promise<void> {
    if (this.#loading) {
      return;
    }
    this.#loading = true;
    this.#failure = null;
    this.#failureCode = null;
    this.requestUpdate();
    try {
      const snapshot = await this.#collector();
      this.#apply(snapshot);
    } catch (error) {
      this.#captured = false;
      this.#elements = [];
      this.#selectedId = null;
      if (error instanceof StackingCaptureError) {
        this.#failureCode = error.code;
        this.#failure = error.code === 'no-page' ? i18nString(UIStrings.noPage) : i18nString(UIStrings.emptySnapshot);
      } else {
        this.#failureCode = null;
        this.#failure = error instanceof Error ? error.message : String(error);
      }
    } finally {
      this.#loading = false;
      this.requestUpdate();
    }
  }

  selectNode(nodeId: number): void {
    const slab = this.#slabs().find(item => item.nodeId === nodeId);
    if (!slab) {
      return;
    }
    this.#selectedId = nodeId;
    this.#failure = null;
    this.requestUpdate();
    const backend = this.#elements.find(element => element.nodeId === nodeId)?.backendNodeId ?? null;
    void this.#select(nodeId, backend).then(selected => {
      if (this.#selectedId !== nodeId) {
        return;
      }
      if (!selected) {
        this.#failure = i18nString(UIStrings.notInElements);
        this.requestUpdate();
      }
    }, () => {
      if (this.#selectedId !== nodeId) {
        return;
      }
      this.#failure = i18nString(UIStrings.notInElements);
      this.requestUpdate();
    });
  }

  #apply(snapshot: StackingSnapshot): void {
    this.#elements = snapshot.elements;
    this.#clipped = snapshot.clipped;
    this.#captured = true;
    this.#selectedId = null;
    this.#failure = null;
    this.#failureCode = null;
    this.#camera = orbitCamera();
    this.#needsFit = true;
  }

  #slabs(): StackingSlab[] {
    return slabsFrom(this.#elements, this.#mode);
  }

  #listed(slabs: StackingSlab[]): StackingSlab[] {
    const contexts = slabs.filter(slab => slab.createsContext);
    const selected = slabs.find(slab => slab.nodeId === this.#selectedId) ?? null;
    if (selected && !selected.createsContext) {
      return [selected, ...contexts];
    }
    return contexts;
  }

  #status(slabs: StackingSlab[]): string {
    if (this.#loading) {
      return i18nString(UIStrings.capturing);
    }
    if (this.#failure) {
      return this.#failure;
    }
    if (!this.#captured) {
      return '';
    }
    const contexts = slabs.filter(slab => slab.createsContext).length;
    return i18nString(UIStrings.summary, {PH1: String(this.#elements.length), PH2: String(contexts)});
  }

  #body(slabs: StackingSlab[]): TemplateResult {
    if (this.#captured) {
      return this.#stage(slabs);
    }
    if (this.#failureCode === 'no-page') {
      return messageBlock(
          'stacking-error', i18nString(UIStrings.noPageTitle), i18nString(UIStrings.noPageBody), this.#onCapture);
    }
    if (this.#failureCode === 'empty') {
      return messageBlock(
          'stacking-error', i18nString(UIStrings.emptySnapshotTitle), i18nString(UIStrings.emptySnapshotBody),
          this.#onCapture);
    }
    if (this.#failure) {
      return messageBlock('stacking-error', this.#failure, '', this.#onCapture);
    }
    return messageBlock(
        'stacking-empty', i18nString(UIStrings.emptyTitle), i18nString(UIStrings.emptyBody), this.#onCapture);
  }

  #stage(slabs: StackingSlab[]): TemplateResult {
    const rows = this.#listed(slabs);
    // clang-format off
    return html`
      <div class="stacking-stage">
        <canvas class="stacking-canvas" tabindex="0" role="application"
          aria-label=${i18nString(UIStrings.canvas)}
          @pointerdown=${this.#onPointerDown} @pointermove=${this.#onPointerMove}
          @pointerup=${this.#onPointerUp} @keydown=${this.#onCanvasKey}></canvas>
        <ul class="stacking-list" role="listbox" aria-label=${i18nString(UIStrings.contexts)}
          @keydown=${this.#onListKey}>
          ${rows.map(slab => rowTemplate(slab, slab.nodeId === this.#selectedId, this.#onRow))}
        </ul>
      </div>
    `;
    // clang-format on
  }

  #paint(slabs: StackingSlab[]): void {
    const canvas = this.contentElement.querySelector('canvas.stacking-canvas');
    if (!(canvas instanceof HTMLCanvasElement)) {
      return;
    }
    const width = canvas.clientWidth;
    const height = canvas.clientHeight;
    if (width < 2 || height < 2) {
      return;
    }
    const ratio = window.devicePixelRatio || 1;
    canvas.width = Math.floor(width * ratio);
    canvas.height = Math.floor(height * ratio);
    const context = canvas.getContext('2d');
    if (!context) {
      return;
    }
    context.setTransform(ratio, 0, 0, ratio, 0, 0);
    context.clearRect(0, 0, width, height);
    const primary = readColor(this.contentElement, '--sys-color-primary', '#026748');
    const ink = readColor(this.contentElement, '--sys-color-on-surface', '#18291f');
    paintFloor(context, slabs, this.#camera, primary);
    const ordered = [...slabs].sort((left, right) => left.level - right.level || left.paintOrder - right.paintOrder);
    for (const slab of ordered) {
      paintSlab(context, slab, this.#camera, slab.nodeId === this.#selectedId, primary, ink);
    }
  }

  #fit(): void {
    const canvas = this.contentElement.querySelector('canvas.stacking-canvas');
    const width = canvas instanceof HTMLCanvasElement ? canvas.clientWidth : 0;
    const height = canvas instanceof HTMLCanvasElement ? canvas.clientHeight : 0;
    this.#camera = fittedCamera(this.#slabs(), width, height, this.#camera);
  }

  #scheduleFit(): void {
    if (!this.#needsFit) {
      return;
    }
    this.#needsFit = false;
    requestAnimationFrame(() => {
      if (!this.#captured) {
        return;
      }
      this.#fit();
      this.requestUpdate();
    });
  }

  #onCapture = (): void => {
    void this.capture();
  };

  #onFit = (): void => {
    this.#fit();
    this.requestUpdate();
  };

  #onShow = (): void => {
    if (this.#selectedId === null) {
      return;
    }
    this.selectNode(this.#selectedId);
  };

  #onMode = (event: Event): void => {
    const button = event.currentTarget;
    if (!(button instanceof HTMLButtonElement)) {
      return;
    }
    const mode = button.dataset.mode === 'dom' ? 'dom' : 'z-index';
    if (mode === this.#mode) {
      return;
    }
    this.#mode = mode;
    this.#fit();
    this.requestUpdate();
  };

  #onRow = (event: Event): void => {
    const button = event.currentTarget;
    if (!(button instanceof HTMLButtonElement)) {
      return;
    }
    const nodeId = Number(button.dataset.nodeId);
    if (!Number.isInteger(nodeId)) {
      return;
    }
    this.selectNode(nodeId);
  };

  #onPointerDown = (event: PointerEvent): void => {
    const canvas = event.currentTarget;
    if (!(canvas instanceof HTMLCanvasElement)) {
      return;
    }
    canvas.setPointerCapture(event.pointerId);
    this.#drag = {x: event.clientX, y: event.clientY, yaw: this.#camera.yaw, pitch: this.#camera.pitch, moved: false};
  };

  #onPointerMove = (event: PointerEvent): void => {
    if (!this.#drag) {
      return;
    }
    const dx = event.clientX - this.#drag.x;
    const dy = event.clientY - this.#drag.y;
    if (Math.hypot(dx, dy) < DRAG_DISTANCE) {
      return;
    }
    this.#drag.moved = true;
    this.#camera.yaw = this.#drag.yaw + dx * 0.008;
    this.#camera.pitch = clamp(this.#drag.pitch + dy * 0.008, PITCH_MIN, PITCH_MAX);
    this.requestUpdate();
  };

  #onPointerUp = (event: PointerEvent): void => {
    const drag = this.#drag;
    this.#drag = null;
    if (!drag || drag.moved) {
      return;
    }
    const canvas = event.currentTarget;
    if (!(canvas instanceof HTMLCanvasElement)) {
      return;
    }
    const rect = canvas.getBoundingClientRect();
    const hit = hitSlab({x: event.clientX - rect.left, y: event.clientY - rect.top}, this.#slabs(), this.#camera);
    if (hit) {
      this.selectNode(hit.nodeId);
    }
  };

  #onCanvasKey = (event: KeyboardEvent): void => {
    if (event.key === 'ArrowLeft') {
      this.#camera.yaw -= 0.08;
    } else if (event.key === 'ArrowRight') {
      this.#camera.yaw += 0.08;
    } else if (event.key === 'ArrowUp') {
      this.#camera.pitch = clamp(this.#camera.pitch - 0.08, PITCH_MIN, PITCH_MAX);
    } else if (event.key === 'ArrowDown') {
      this.#camera.pitch = clamp(this.#camera.pitch + 0.08, PITCH_MIN, PITCH_MAX);
    } else {
      return;
    }
    event.preventDefault();
    this.requestUpdate();
  };

  #onListKey = (event: KeyboardEvent): void => {
    const ids = this.#listed(this.#slabs()).map(slab => slab.nodeId);
    if (ids.length === 0) {
      return;
    }
    const index = ids.indexOf(this.#selectedId ?? -1);
    let next = index;
    if (event.key === 'ArrowDown') {
      next = Math.min(ids.length - 1, Math.max(index, 0) + 1);
    } else if (event.key === 'ArrowUp') {
      next = Math.max(0, (index < 0 ? 0 : index) - 1);
    } else if (event.key === 'Home') {
      next = 0;
    } else if (event.key === 'End') {
      next = ids.length - 1;
    } else {
      return;
    }
    event.preventDefault();
    const nodeId = ids[next];
    if (nodeId !== undefined) {
      this.selectNode(nodeId);
    }
  };
}

function toolbar(
    mode: StackingMode, loading: boolean, captured: boolean, selected: boolean,
    handlers: {capture: () => void, fit: () => void, show: () => void, mode: (event: Event) => void},
    ): TemplateResult {
  // clang-format off
  return html`
    <div class="stacking-toolbar">
      <button class="stacking-capture" @click=${handlers.capture} ?disabled=${loading}>
        ${i18nString(UIStrings.capture)}
      </button>
      <div class="stacking-modes" role="group" aria-label=${i18nString(UIStrings.depthMode)}>
        <button data-mode="z-index" aria-pressed=${mode === 'z-index'} ?disabled=${!captured}
          @click=${handlers.mode}>${i18nString(UIStrings.zIndex)}</button>
        <button data-mode="dom" aria-pressed=${mode === 'dom'} ?disabled=${!captured}
          @click=${handlers.mode}>${i18nString(UIStrings.dom)}</button>
      </div>
      <button @click=${handlers.fit} ?disabled=${!captured}>${i18nString(UIStrings.fit)}</button>
      <button @click=${handlers.show} ?disabled=${!selected}>${i18nString(UIStrings.showInElements)}</button>
      <span class="stacking-hint">${i18nString(UIStrings.keys)}</span>
    </div>
  `;
  // clang-format on
}

function messageBlock(className: string, title: string, body: string, capture: () => void): TemplateResult {
  // clang-format off
  return html`
    <section class=${className}>
      <h2>${title}</h2>
      <p>${body}</p>
      <button @click=${capture}>${i18nString(UIStrings.capture)}</button>
    </section>
  `;
  // clang-format on
}

function rowTemplate(slab: StackingSlab, selected: boolean, choose: (event: Event) => void): TemplateResult {
  const below = slab.zIndex !== null && slab.zIndex < 0;
  let className = '';
  if (selected) {
    className = 'is-selected';
  } else if (below) {
    className = 'is-below';
  }
  const visible = slab.reasons.filter(item => item !== 'root');
  let reason = slab.reasons.includes('root') ? i18nString(UIStrings.root) : visible.join(', ');
  if (below) {
    reason = reason.length > 0 ? `${i18nString(UIStrings.below)} · ${reason}` : i18nString(UIStrings.below);
  }
  // clang-format off
  return html`
    <li>
      <button role="option" aria-selected=${selected} class=${className} data-node-id=${slab.nodeId}
        @click=${choose}>
        <span class="stacking-row-name">${slab.name}</span>
        <span class="stacking-row-reason">${reason}</span>
      </button>
    </li>
  `;
  // clang-format on
}

function paintFloor(
    context: CanvasRenderingContext2D, slabs: StackingSlab[], camera: StackingCamera, primary: string): void {
  if (slabs.length === 0) {
    return;
  }
  let minX = Number.POSITIVE_INFINITY;
  let minY = Number.POSITIVE_INFINITY;
  let maxX = Number.NEGATIVE_INFINITY;
  let maxY = Number.NEGATIVE_INFINITY;
  for (const slab of slabs) {
    minX = Math.min(minX, slab.bounds.x);
    minY = Math.min(minY, slab.bounds.y);
    maxX = Math.max(maxX, slab.bounds.x + slab.bounds.width);
    maxY = Math.max(maxY, slab.bounds.y + slab.bounds.height);
  }
  const pad = 48;
  minX -= pad;
  minY -= pad;
  maxX += pad;
  maxY += pad;
  const step = 80;
  context.save();
  context.strokeStyle = primary;
  context.globalAlpha = 0.16;
  context.lineWidth = 1;
  for (let x = minX; x <= maxX; x += step) {
    strokeSegment(context, {x, y: minY}, {x, y: maxY}, camera);
  }
  for (let y = minY; y <= maxY; y += step) {
    strokeSegment(context, {x: minX, y}, {x: maxX, y}, camera);
  }
  context.restore();
}

function strokeSegment(context: CanvasRenderingContext2D, start: Point, end: Point, camera: StackingCamera): void {
  const from = project(start, 0, camera);
  const to = project(end, 0, camera);
  context.beginPath();
  context.moveTo(from.x, from.y);
  context.lineTo(to.x, to.y);
  context.stroke();
}

function paintSlab(
    context: CanvasRenderingContext2D, slab: StackingSlab, camera: StackingCamera, selected: boolean,
    primary: string, ink: string): void {
  const corners = quad(slab.bounds, slab.level, camera);
  const under = quad(slab.bounds, slab.level - 12, camera);
  const first = corners[0];
  if (!first) {
    return;
  }
  context.save();
  context.fillStyle = fillFor(slab, false);
  context.globalAlpha = 0.28;
  for (let index = 0; index < corners.length; index++) {
    const next = (index + 1) % corners.length;
    const topStart = corners[index];
    const topEnd = corners[next];
    const bottomEnd = under[next];
    const bottomStart = under[index];
    if (!topStart || !topEnd || !bottomEnd || !bottomStart) {
      continue;
    }
    context.beginPath();
    context.moveTo(topStart.x, topStart.y);
    context.lineTo(topEnd.x, topEnd.y);
    context.lineTo(bottomEnd.x, bottomEnd.y);
    context.lineTo(bottomStart.x, bottomStart.y);
    context.closePath();
    context.fill();
  }
  context.globalAlpha = 1;
  context.beginPath();
  context.moveTo(first.x, first.y);
  for (const corner of corners.slice(1)) {
    context.lineTo(corner.x, corner.y);
  }
  context.closePath();
  context.fillStyle = fillFor(slab, selected);
  context.fill();
  context.lineWidth = selected ? 2.5 : 1;
  context.strokeStyle = selected ? primary : ink;
  context.globalAlpha = selected ? 1 : 0.55;
  context.stroke();
  context.globalAlpha = 1;
  if (cornersWidth(corners) > 36 && (slab.createsContext || selected)) {
    context.fillStyle = ink;
    context.font = '600 11px sans-serif';
    context.fillText(slab.name, first.x + 8, first.y + 16);
  }
  context.restore();
}

function fillFor(slab: StackingSlab, selected: boolean): string {
  let hash = 0;
  for (let index = 0; index < slab.name.length; index++) {
    hash = Math.imul(hash, 33) + slab.name.charCodeAt(index);
  }
  const hue = Math.abs(hash) % 360;
  const below = slab.zIndex !== null && slab.zIndex < 0;
  const saturation = below ? 42 : 58;
  const lightness = slab.createsContext ? 48 : 62;
  let alpha = slab.createsContext ? 0.78 : 0.4;
  if (selected) {
    alpha = 0.92;
  }
  return `hsla(${hue} ${saturation}% ${lightness}% / ${alpha})`;
}

function cornersWidth(corners: Point[]): number {
  const xs = corners.map(corner => corner.x);
  return Math.max(...xs) - Math.min(...xs);
}

function readColor(root: HTMLElement, name: string, fallback: string): string {
  const value = getComputedStyle(root).getPropertyValue(name).trim();
  return value.length > 0 ? value : fallback;
}

function clamp(value: number, min: number, max: number): number {
  return Math.min(max, Math.max(min, value));
}
