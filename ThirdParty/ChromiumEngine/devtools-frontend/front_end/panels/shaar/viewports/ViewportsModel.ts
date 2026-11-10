// Copyright 2026 The Shaar Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import type {ViewportHost, ViewportReply} from './ViewportsHost.js';

export const PRESET_IDS = ['iphone15Pro', 'ipad', 'pixel8', 'desktop', 'desktop1440'] as const;
export type PresetId = typeof PRESET_IDS[number];
export type ColorScheme = 'noPreference'|'light'|'dark';
export type Orientation = 'portrait'|'landscape';
export type ViewportStatus = 'idle'|'connecting'|'ready'|'error';
export type ViewportNotice = 'copied'|'notReady'|'invalid'|'failed'|null;

export interface Insets {
  top: number;
  right: number;
  bottom: number;
  left: number;
}

export interface PresetSpec {
  id: PresetId;
  width: number;
  height: number;
  insets: Insets;
  phone: boolean;
}

export interface Capabilities {
  colorScheme: boolean;
  hover: boolean;
  typing: boolean;
}

export interface ViewportFrame {
  id: string;
  nativeId: number;
  preset: PresetId;
  url: string;
  pngBase64: string;
  safeArea: Insets;
  orientation: Orientation;
  colorScheme: ColorScheme;
}

export interface ImageSize {
  width: number;
  height: number;
}

const FIXED_SCALE = 0.5;
const CARD_CHROME = 76;
const CARD_SPACING = 12;
const OUTER_PADDING = 28;
const MINIMUM_CARD_WIDTH = 200;
const CONTACT_GAP = 12;
const CONTACT_PAD = 16;
const CONTACT_CAPTION = 22;
const CONTACT_MAX_HEIGHT = 720;
const CONTACT_MAX_WIDTH = 2400;
const FRAME_POLL_MS = 500;
const MAX_VIEWPORTS = 4;
const MAX_URL_LENGTH = 8192;
const MAX_PNG_TEXT = 11_184_816;
const MAX_PNG_BYTES = 8 * 1024 * 1024;
const PNG_MAGIC = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];

const EMPTY_CAPABILITIES: Capabilities = {
  colorScheme: false,
  hover: false,
  typing: false,
};

const PRESETS: Record<PresetId, PresetSpec> = {
  iphone15Pro:
      {id: 'iphone15Pro', width: 393, height: 852, insets: {top: 59, right: 0, bottom: 34, left: 0}, phone: true},
  ipad: {id: 'ipad', width: 820, height: 1180, insets: {top: 24, right: 0, bottom: 20, left: 0}, phone: false},
  pixel8: {id: 'pixel8', width: 412, height: 915, insets: {top: 24, right: 0, bottom: 24, left: 0}, phone: true},
  desktop: {id: 'desktop', width: 1280, height: 800, insets: {top: 0, right: 0, bottom: 0, left: 0}, phone: false},
  desktop1440:
      {id: 'desktop1440', width: 1440, height: 900, insets: {top: 0, right: 0, bottom: 0, left: 0}, phone: false},
};

export function presetSpec(id: PresetId): PresetSpec {
  return PRESETS[id];
}

export function projectPoint(value: number, from: number, to: number): number {
  if (from <= 0) {
    return 0;
  }
  return Math.trunc(value * to / from);
}

export function typingIsValid(text: string): boolean {
  const bytes = new TextEncoder().encode(text);
  if (bytes.length < 1 || bytes.length > 64) {
    return false;
  }
  for (const byte of bytes) {
    if (byte < 0x20 || byte === 0x7f) {
      return false;
    }
  }
  return true;
}

export function contentSize(frame: ViewportFrame): ImageSize {
  if (frame.orientation === 'portrait') {
    return {width: presetSpec(frame.preset).width, height: presetSpec(frame.preset).height};
  }
  return {width: presetSpec(frame.preset).height, height: presetSpec(frame.preset).width};
}

export function fitScale(content: ImageSize[], available: ImageSize): number {
  const tallest = content.reduce((max, size) => Math.max(max, size.height), 0);
  if (tallest <= 0) {
    return FIXED_SCALE;
  }
  const widthSum = content.reduce((sum, size) => sum + size.width, 0);
  const gaps = CARD_SPACING * Math.max(content.length - 1, 0);
  const usableWidth = available.width - OUTER_PADDING;
  const usableHeight = available.height - OUTER_PADDING - CARD_CHROME;
  if (usableWidth <= 1 || usableHeight <= 1 || widthSum + gaps <= 0) {
    return FIXED_SCALE;
  }
  return Math.min(1, usableWidth / (widthSum + gaps), usableHeight / tallest);
}

export function previewSize(content: ImageSize, scale: number): ImageSize {
  return {
    width: Math.max(1, Math.round(content.width * scale)),
    height: Math.max(1, Math.round(content.height * scale)),
  };
}

export function cardWidth(previewWidth: number): number {
  return Math.max(previewWidth, MINIMUM_CARD_WIDTH);
}

export function contactSheetScale(sizes: ImageSize[]): number {
  const tallest = sizes.reduce((max, size) => Math.max(max, size.height), 0);
  if (tallest <= 0) {
    return 1;
  }
  const widthSum = sizes.reduce((sum, size) => sum + size.width, 0);
  const gaps = CONTACT_GAP * Math.max(sizes.length - 1, 0);
  const rawWidth = CONTACT_PAD * 2 + widthSum + gaps;
  const heightScale = Math.min(1, CONTACT_MAX_HEIGHT / tallest);
  const widthScale = Math.min(1, CONTACT_MAX_WIDTH / Math.max(rawWidth, 1));
  return Math.min(heightScale, widthScale);
}

export function contactSheetCanvasSize(sizes: ImageSize[]): ImageSize {
  const scale = contactSheetScale(sizes);
  const scaled = sizes.map(size => ({
                             width: Math.max(1, Math.round(size.width * scale)),
                             height: Math.max(1, Math.round(size.height * scale)),
                           }));
  const width = CONTACT_PAD * 2 + scaled.reduce((sum, size) => sum + size.width, 0) +
      CONTACT_GAP * Math.max(scaled.length - 1, 0);
  const tallest = scaled.reduce((max, size) => Math.max(max, size.height), 0);
  return {width: Math.ceil(width), height: Math.ceil(CONTACT_PAD * 2 + CONTACT_CAPTION + tallest)};
}

export function nextScheme(scheme: ColorScheme): ColorScheme {
  if (scheme === 'noPreference') {
    return 'light';
  }
  if (scheme === 'light') {
    return 'dark';
  }
  return 'noPreference';
}

export function pageUrlIsValid(value: string): boolean {
  if (value.length < 1 || value.length > MAX_URL_LENGTH) {
    return false;
  }
  let url: URL;
  try {
    url = new URL(value);
  } catch {
    return false;
  }
  if (url.username || url.password) {
    return false;
  }
  return url.protocol === 'http:' || url.protocol === 'https:' || url.protocol === 'file:';
}

function rotateInsets(insets: Insets, orientation: Orientation): Insets {
  if (orientation === 'portrait') {
    return {top: insets.left, right: insets.top, bottom: insets.right, left: insets.bottom};
  }
  return {top: insets.right, right: insets.bottom, bottom: insets.left, left: insets.top};
}

function pngBytes(encoded: string): Uint8Array|null {
  if (encoded.length < 1 || encoded.length > MAX_PNG_TEXT) {
    return null;
  }
  let binary: string;
  try {
    binary = atob(encoded);
  } catch {
    return null;
  }
  if (binary.length > MAX_PNG_BYTES || binary.length < PNG_MAGIC.length) {
    return null;
  }
  const bytes = new Uint8Array(binary.length);
  for (let index = 0; index < binary.length; index++) {
    bytes[index] = binary.charCodeAt(index);
  }
  for (let index = 0; index < PNG_MAGIC.length; index++) {
    if (bytes[index] !== PNG_MAGIC[index]) {
      return null;
    }
  }
  return bytes;
}

export function decodeFrameReply(reply: ViewportReply, nativeId: number): {url: string, pngBase64: string}|null {
  if (reply.schemaVersion !== 1 || reply.viewportID !== nativeId || typeof reply.url !== 'string' ||
      typeof reply.data !== 'string') {
    return null;
  }
  if (!pageUrlIsValid(reply.url) || !pngBytes(reply.data)) {
    return null;
  }
  return {url: reply.url, pngBase64: reply.data};
}

function loadImage(bytes: Uint8Array): Promise<HTMLImageElement> {
  return new Promise((resolve, reject) => {
    const buffer = new ArrayBuffer(bytes.byteLength);
    new Uint8Array(buffer).set(bytes);
    const blob = new Blob([buffer], {type: 'image/png'});
    const url = URL.createObjectURL(blob);
    const image = new Image();
    image.onload = () => {
      URL.revokeObjectURL(url);
      resolve(image);
    };
    image.onerror = () => {
      URL.revokeObjectURL(url);
      reject(new Error('image'));
    };
    image.src = url;
  });
}

export async function contactSheetBlob(frames: ViewportFrame[],
                                       labelFor: (frame: ViewportFrame) => string): Promise<Blob|null> {
  const loaded: Array<{frame: ViewportFrame, image: HTMLImageElement}> = [];
  for (const frame of frames) {
    const bytes = pngBytes(frame.pngBase64);
    if (!bytes) {
      continue;
    }
    try {
      const image = await loadImage(bytes);
      if (image.naturalWidth > 0 && image.naturalHeight > 0) {
        loaded.push({frame, image});
      }
    } catch {
      // Skip a frame whose PNG does not decode.
    }
  }
  if (loaded.length === 0) {
    return null;
  }
  const sizes = loaded.map(item => ({width: item.image.naturalWidth, height: item.image.naturalHeight}));
  const scale = contactSheetScale(sizes);
  const canvasSize = contactSheetCanvasSize(sizes);
  const canvas = new OffscreenCanvas(canvasSize.width, canvasSize.height);
  const context = canvas.getContext('2d');
  if (!context) {
    return null;
  }
  context.fillStyle = '#ffffff';
  context.fillRect(0, 0, canvas.width, canvas.height);
  context.fillStyle = '#18291f';
  context.font = '11px sans-serif';
  context.textBaseline = 'top';
  let x = CONTACT_PAD;
  const scaledHeights = loaded.map(item => Math.max(1, Math.round(item.image.naturalHeight * scale)));
  const tallest = scaledHeights.reduce((max, height) => Math.max(max, height), 1);
  loaded.forEach((item, index) => {
    const width = Math.max(1, Math.round(item.image.naturalWidth * scale));
    const height = scaledHeights[index];
    const y = CONTACT_PAD + (tallest - height);
    context.drawImage(item.image, x, y, width, height);
    context.fillText(labelFor(item.frame), x, CONTACT_PAD + tallest + 6);
    x += width + CONTACT_GAP;
  });
  return await canvas.convertToBlob({type: 'image/png'});
}

export class ViewportController {
  #host: ViewportHost;
  #listeners = new Set<() => void>();
  #session = 0;
  #leaseID: number|null = null;
  #timer: number|null = null;
  #openPromise: Promise<void>|null = null;
  #urlDirty = false;
  #lastHover = '';

  status: ViewportStatus = 'idle';
  frames: ViewportFrame[] = [];
  capabilities: Capabilities = {...EMPTY_CAPABILITIES};
  notice: ViewportNotice = null;
  fitting = true;
  url = '';
  mirroredScheme: ColorScheme|null = null;

  constructor(host: ViewportHost) {
    this.#host = host;
  }

  listen(listener: () => void): () => void {
    this.#listeners.add(listener);
    return () => {
      this.#listeners.delete(listener);
    };
  }

  setFitting(fitting: boolean): void {
    this.fitting = fitting;
    this.#emit();
  }

  markUrlDraft(): void {
    this.#urlDirty = true;
  }

  async open(): Promise<void> {
    if (this.status === 'ready') {
      return;
    }
    if (this.#openPromise) {
      return await this.#openPromise;
    }
    this.#openPromise = this.#open();
    try {
      await this.#openPromise;
    } finally {
      this.#openPromise = null;
    }
  }

  async #open(): Promise<void> {
    const session = ++this.#session;
    this.status = 'connecting';
    this.notice = null;
    this.#emit();
    try {
      const reply = await this.#host.request('open', {schemaVersion: 1});
      this.#assertSession(session);
      const leaseID = reply.leaseID;
      if (reply.schemaVersion !== 1 || typeof leaseID !== 'number' || leaseID <= 0) {
        throw new Error('unavailable');
      }
      this.#leaseID = leaseID;
      this.capabilities = {
        colorScheme: reply.colorScheme === 1,
        hover: reply.hover === 1,
        typing: reply.typing === 1,
      };
      await this.#addPreset('iphone15Pro', session);
      await this.#addPreset('desktop', session);
      await this.refresh();
      this.#assertSession(session);
      this.status = this.frames.length > 0 ? 'ready' : 'error';
      this.#emit();
    } catch {
      if (this.#session === session) {
        await this.#dropLease();
        this.status = 'error';
        this.#emit();
      }
    }
  }

  async close(): Promise<void> {
    this.stopPolling();
    await this.#dropLease();
    this.status = 'idle';
    this.#emit();
  }

  startPolling(): void {
    this.stopPolling();
    this.#timer = window.setInterval(() => {
      void this.refresh();
    }, FRAME_POLL_MS);
  }

  stopPolling(): void {
    if (this.#timer !== null) {
      window.clearInterval(this.#timer);
      this.#timer = null;
    }
  }

  async refresh(): Promise<void> {
    const session = this.#session;
    const leaseID = this.#leaseID;
    if (leaseID === null) {
      return;
    }
    for (const frame of [...this.frames]) {
      if (session !== this.#session) {
        return;
      }
      try {
        const reply = await this.#host.request('frame', {
          schemaVersion: 1,
          leaseID,
          viewportID: frame.nativeId,
        });
        if (session !== this.#session) {
          return;
        }
        const decoded = decodeFrameReply(reply, frame.nativeId);
        if (!decoded) {
          continue;
        }
        const index = this.frames.findIndex(item => item.nativeId === frame.nativeId);
        if (index < 0) {
          continue;
        }
        this.frames[index] = {...this.frames[index], url: decoded.url, pngBase64: decoded.pngBase64};
      } catch {
        // Keep the last decoded frame.
      }
    }
    if (session !== this.#session) {
      return;
    }
    this.#adoptSharedUrl();
    this.#emit();
  }

  async navigate(rawUrl: string): Promise<void> {
    const url = rawUrl.trim();
    if (!pageUrlIsValid(url)) {
      this.notice = 'invalid';
      this.#emit();
      return;
    }
    const sent = await this.#action({kind: 'navigate', url});
    if (!sent) {
      return;
    }
    this.url = url;
    this.#urlDirty = false;
    this.frames = this.frames.map(frame => ({...frame, url, pngBase64: ''}));
    this.#emit();
    await this.refresh();
  }

  async add(preset: PresetId): Promise<void> {
    if (this.status !== 'ready' || this.frames.length >= MAX_VIEWPORTS) {
      this.notice = 'invalid';
      this.#emit();
      return;
    }
    try {
      await this.#addPreset(preset, this.#session);
      this.notice = null;
      await this.refresh();
    } catch {
      if (this.status === 'ready') {
        this.notice = 'failed';
        this.#emit();
      }
    }
  }

  async remove(id: string): Promise<void> {
    const frame = this.#frame(id);
    const leaseID = this.#leaseID;
    if (!frame || this.frames.length <= 1 || this.status !== 'ready' || leaseID === null) {
      this.notice = 'invalid';
      this.#emit();
      return;
    }
    const session = this.#session;
    try {
      await this.#host.request('remove', {schemaVersion: 1, leaseID, viewportID: frame.nativeId});
      if (session !== this.#session) {
        return;
      }
      this.frames = this.frames.filter(item => item.id !== id);
      this.notice = null;
      this.#emit();
    } catch {
      if (session === this.#session) {
        this.notice = 'failed';
        this.#emit();
      }
    }
  }

  async rotate(id: string): Promise<void> {
    const frame = this.#frame(id);
    if (!frame) {
      this.notice = 'invalid';
      this.#emit();
      return;
    }
    const sent = await this.#action({kind: 'rotate', viewportID: frame.nativeId});
    if (!sent) {
      return;
    }
    const index = this.frames.findIndex(item => item.id === id);
    if (index < 0) {
      return;
    }
    const current = this.frames[index];
    const orientation: Orientation = current.orientation === 'portrait' ? 'landscape' : 'portrait';
    this.frames[index] = {
      ...current,
      orientation,
      safeArea: rotateInsets(current.safeArea, current.orientation),
      pngBase64: '',
    };
    this.#emit();
  }

  async scroll(id: string, deltaX: number, deltaY: number): Promise<void> {
    const frame = this.#frame(id);
    const dx = Math.trunc(deltaX);
    const dy = Math.trunc(deltaY);
    if (!frame || dx < -2000 || dx > 2000 || dy < -2000 || dy > 2000) {
      this.notice = 'invalid';
      this.#emit();
      return;
    }
    await this.#action({kind: 'scroll', viewportID: frame.nativeId, deltaX: dx, deltaY: dy});
  }

  async click(id: string, x: number, y: number): Promise<void> {
    const frame = this.#frame(id);
    const point = this.#point(frame, x, y);
    if (!frame || !point) {
      this.notice = 'invalid';
      this.#emit();
      return;
    }
    await this.#action({kind: 'click', viewportID: frame.nativeId, x: point.x, y: point.y});
  }

  async hover(id: string, x: number, y: number): Promise<void> {
    const frame = this.#frame(id);
    const point = this.#point(frame, x, y);
    if (!this.capabilities.hover || !frame || !point) {
      return;
    }
    const key = `${id}:${point.x}:${point.y}`;
    if (key === this.#lastHover) {
      return;
    }
    this.#lastHover = key;
    await this.#action({kind: 'hover', viewportID: frame.nativeId, x: point.x, y: point.y});
  }

  async typeIntoAll(text: string): Promise<void> {
    const frame = this.frames[0];
    if (!this.capabilities.typing || !frame || !typingIsValid(text)) {
      this.notice = 'invalid';
      this.#emit();
      return;
    }
    await this.#action({kind: 'type', viewportID: frame.nativeId, text});
  }

  async setColorScheme(id: string, scheme: ColorScheme): Promise<void> {
    const frame = this.#frame(id);
    if (!this.capabilities.colorScheme || !frame) {
      this.notice = 'invalid';
      this.#emit();
      return;
    }
    const sent = await this.#action({kind: 'colorScheme', viewportID: frame.nativeId, scheme});
    if (!sent) {
      return;
    }
    this.mirroredScheme = null;
    const index = this.frames.findIndex(item => item.id === id);
    if (index >= 0) {
      this.frames[index] = {...this.frames[index], colorScheme: scheme};
    }
    this.#emit();
  }

  async mirrorColorScheme(scheme: ColorScheme): Promise<void> {
    if (!this.capabilities.colorScheme || this.frames.length === 0) {
      this.notice = 'invalid';
      this.#emit();
      return;
    }
    const sent = await this.#action({kind: 'colorScheme', scheme});
    if (!sent) {
      return;
    }
    this.mirroredScheme = scheme;
    this.frames = this.frames.map(frame => ({...frame, colorScheme: scheme}));
    this.#emit();
  }

  async copyScreenshots(labelFor: (frame: ViewportFrame) => string,
                        write: (blob: Blob) => Promise<void>): Promise<void> {
    const blob = await contactSheetBlob(this.frames, labelFor);
    if (!blob) {
      this.notice = 'notReady';
      this.#emit();
      return;
    }
    try {
      await write(blob);
      this.notice = 'copied';
    } catch {
      this.notice = 'failed';
    }
    this.#emit();
  }

  layoutScale(available: ImageSize): number {
    if (!this.fitting) {
      return FIXED_SCALE;
    }
    return fitScale(this.frames.map(contentSize), available);
  }

  #frame(id: string): ViewportFrame|null {
    return this.frames.find(frame => frame.id === id) ?? null;
  }

  #point(frame: ViewportFrame|null, x: number, y: number): {x: number, y: number}|null {
    if (!frame) {
      return null;
    }
    const size = contentSize(frame);
    const px = Math.trunc(x);
    const py = Math.trunc(y);
    if (px < 0 || py < 0 || px >= size.width || py >= size.height) {
      return null;
    }
    return {x: px, y: py};
  }

  async #addPreset(preset: PresetId, session: number): Promise<void> {
    const spec = presetSpec(preset);
    const leaseID = this.#leaseID;
    if (leaseID === null) {
      throw new Error('unavailable');
    }
    const reply = await this.#host.request('add', {
      schemaVersion: 1,
      leaseID,
      preset,
      width: spec.width,
      height: spec.height,
    });
    this.#assertSession(session);
    const nativeId = reply.viewportID;
    if (reply.schemaVersion !== 1 || typeof nativeId !== 'number' || nativeId <= 0 ||
        this.frames.some(frame => frame.nativeId === nativeId)) {
      throw new Error('failed');
    }
    let scheme: ColorScheme = 'noPreference';
    if (this.mirroredScheme && this.mirroredScheme !== 'noPreference') {
      await this.#host.request('action', {
        schemaVersion: 1,
        leaseID,
        kind: 'colorScheme',
        viewportID: nativeId,
        scheme: this.mirroredScheme,
      });
      this.#assertSession(session);
      scheme = this.mirroredScheme;
    }
    this.frames.push({
      id: `viewport-${nativeId}`,
      nativeId,
      preset,
      url: this.frames[0]?.url ?? '',
      pngBase64: '',
      safeArea: spec.insets,
      orientation: 'portrait',
      colorScheme: scheme,
    });
    this.#emit();
  }

  async #action(fields: Record<string, unknown>): Promise<boolean> {
    const leaseID = this.#leaseID;
    if (this.status !== 'ready' || leaseID === null) {
      this.notice = 'invalid';
      this.#emit();
      return false;
    }
    const session = this.#session;
    try {
      await this.#host.request('action', {schemaVersion: 1, leaseID, ...fields});
      if (session !== this.#session) {
        return false;
      }
      this.notice = null;
      this.#emit();
      return true;
    } catch {
      if (session === this.#session) {
        this.notice = 'failed';
        this.#emit();
      }
      return false;
    }
  }

  #adoptSharedUrl(): void {
    if (this.#urlDirty) {
      return;
    }
    const urls = new Set(this.frames.map(frame => frame.url).filter(url => url.length > 0));
    if (urls.size === 1) {
      this.url = this.frames[0].url;
    }
  }

  async #dropLease(): Promise<void> {
    const leaseID = this.#leaseID;
    this.#session += 1;
    this.#leaseID = null;
    this.frames = [];
    this.capabilities = {...EMPTY_CAPABILITIES};
    this.mirroredScheme = null;
    this.notice = null;
    this.#urlDirty = false;
    this.#lastHover = '';
    if (leaseID === null) {
      return;
    }
    try {
      await this.#host.request('close', {schemaVersion: 1, leaseID});
    } catch {
      // Closing a lease that already ended is fine.
    }
  }

  #assertSession(session: number): void {
    if (session !== this.#session) {
      throw new Error('stale');
    }
  }

  #emit(): void {
    for (const listener of this.#listeners) {
      listener();
    }
  }
}
