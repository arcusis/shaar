// Copyright 2026 The Shaar Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import * as SDK from '../../../core/sdk/sdk.js';
import * as Protocol from '../../../generated/protocol.js';

export type ViewportOperation = 'open'|'close'|'add'|'remove'|'action'|'frame';

export interface ViewportReply {
  schemaVersion?: number;
  leaseID?: number;
  viewportID?: number;
  url?: string;
  data?: string;
  colorScheme?: number;
  hover?: number;
  typing?: number;
  error?: string;
}

export interface ViewportHost {
  request(operation: ViewportOperation, payload: Record<string, unknown>): Promise<ViewportReply>;
}

const MAX_VIEWS = 4;
const MAX_URL_LENGTH = 8192;
const MAX_PNG_TEXT = 11_184_816;
const TARGET_WAIT_MS = 4000;
const PHONE_PRESETS = new Set(['iphone15Pro', 'pixel8']);

interface ViewState {
  id: number;
  targetId: Protocol.Target.TargetID;
  width: number;
  height: number;
  mobile: boolean;
}

/**
 * One hidden page target per viewport. The inspected page is left alone.
 * `Target.createTarget` with `hidden` keeps the page out of the tab strip
 * and ends it with the DevTools session.
 */
export class SdkViewportHost implements ViewportHost {
  #lease = 0;
  #nextId = 1;
  #views = new Map<number, ViewState>();

  request(operation: ViewportOperation, payload: Record<string, unknown>): Promise<ViewportReply> {
    switch (operation) {
      case 'open':
        return this.#open();
      case 'close':
        return this.#close(payload);
      case 'add':
        return this.#add(payload);
      case 'remove':
        return this.#remove(payload);
      case 'action':
        return this.#action(payload);
      case 'frame':
        return this.#frame(payload);
    }
  }

  async #open(): Promise<ViewportReply> {
    this.#lease += 1;
    await this.#dropTargets();
    if (!SDK.TargetManager.TargetManager.instance().rootTarget()) {
      throw new Error('unavailable');
    }
    return {schemaVersion: 1, leaseID: this.#lease, colorScheme: 1, hover: 1, typing: 1};
  }

  async #close(payload: Record<string, unknown>): Promise<ViewportReply> {
    if (!this.#sameLease(payload)) {
      throw new Error('failed');
    }
    this.#lease += 1;
    await this.#dropTargets();
    return {schemaVersion: 1};
  }

  async #add(payload: Record<string, unknown>): Promise<ViewportReply> {
    if (!this.#sameLease(payload) || this.#views.size >= MAX_VIEWS) {
      throw new Error('failed');
    }
    const width = finiteNumber(payload.width);
    const height = finiteNumber(payload.height);
    if (width === null || height === null || !sizeIsAllowed(width, height)) {
      throw new Error('failed');
    }
    const root = SDK.TargetManager.TargetManager.instance().rootTarget();
    if (!root) {
      throw new Error('unavailable');
    }
    const lease = this.#lease;
    const created = await root.targetAgent().invoke_createTarget({
      url: '',
      hidden: true,
      background: true,
    });
    if (created.getError() || !created.targetId) {
      throw new Error('unavailable');
    }
    const targetId = created.targetId;
    try {
      const target = await waitForTarget(targetId);
      if (lease !== this.#lease) {
        throw new Error('failed');
      }
      const mobile = PHONE_PRESETS.has(stringField(payload.preset));
      await this.#metrics(target, width, height, mobile, false);
      const url = cloneUrl();
      if (url) {
        const navigated = await target.pageAgent().invoke_navigate({url});
        if (navigated.getError()) {
          throw new Error('failed');
        }
      }
      if (lease !== this.#lease) {
        throw new Error('failed');
      }
      const viewportID = this.#nextId;
      this.#nextId += 1;
      this.#views.set(viewportID, {id: viewportID, targetId, width, height, mobile});
      return {schemaVersion: 1, viewportID};
    } catch (error) {
      await this.#closeTarget(targetId);
      throw error;
    }
  }

  async #remove(payload: Record<string, unknown>): Promise<ViewportReply> {
    if (!this.#sameLease(payload) || this.#views.size <= 1) {
      throw new Error('failed');
    }
    const viewportID = finiteNumber(payload.viewportID);
    const view = viewportID === null ? undefined : this.#views.get(viewportID);
    if (!view) {
      throw new Error('failed');
    }
    await this.#closeTarget(view.targetId);
    this.#views.delete(view.id);
    return {schemaVersion: 1};
  }

  async #action(payload: Record<string, unknown>): Promise<ViewportReply> {
    if (!this.#sameLease(payload)) {
      throw new Error('failed');
    }
    const kind = stringField(payload.kind);
    if (kind === 'navigate') {
      const url = stringField(payload.url);
      if (!httpUrl(url)) {
        throw new Error('failed');
      }
      await Promise.all([...this.#views.values()].map(async view => {
        const target = this.#target(view);
        const navigated = await target.pageAgent().invoke_navigate({url});
        if (navigated.getError()) {
          throw new Error('failed');
        }
      }));
      return {schemaVersion: 1};
    }
    if (kind === 'type') {
      const text = stringField(payload.text);
      if (!typingIsAllowed(text)) {
        throw new Error('failed');
      }
      await Promise.all([...this.#views.values()].map(async view => {
        const typed = await this.#target(view).inputAgent().invoke_insertText({text});
        if (typed.getError()) {
          throw new Error('failed');
        }
      }));
      return {schemaVersion: 1};
    }
    if (kind === 'colorScheme') {
      const value = schemeFeature(payload.scheme);
      if (value === null) {
        throw new Error('failed');
      }
      const targets = this.#selected(payload);
      await Promise.all(targets.map(async view => {
        const applied = await this.#target(view).emulationAgent().invoke_setEmulatedMedia({
          features: [{name: 'prefers-color-scheme', value}],
        });
        if (applied.getError()) {
          throw new Error('failed');
        }
      }));
      return {schemaVersion: 1};
    }
    if (kind === 'rotate') {
      const view = this.#one(payload);
      const width = view.height;
      const height = view.width;
      const landscape = width > height;
      await this.#metrics(this.#target(view), width, height, view.mobile, landscape);
      view.width = width;
      view.height = height;
      return {schemaVersion: 1};
    }
    if (kind === 'scroll' || kind === 'click' || kind === 'hover') {
      await this.#pointer(kind, payload);
      return {schemaVersion: 1};
    }
    throw new Error('failed');
  }

  async #frame(payload: Record<string, unknown>): Promise<ViewportReply> {
    if (!this.#sameLease(payload)) {
      throw new Error('failed');
    }
    const view = this.#one(payload);
    const target = this.#target(view);
    const shot = await target.pageAgent().invoke_captureScreenshot({
      format: Protocol.Page.CaptureScreenshotRequestFormat.Png,
      fromSurface: true,
      captureBeyondViewport: false,
    });
    if (shot.getError() || !shot.data || shot.data.length > MAX_PNG_TEXT) {
      throw new Error('failed');
    }
    const url = String(target.inspectedURL());
    if (!httpUrl(url)) {
      throw new Error('failed');
    }
    return {schemaVersion: 1, viewportID: view.id, url, data: shot.data};
  }

  async #pointer(kind: 'scroll'|'click'|'hover', payload: Record<string, unknown>): Promise<void> {
    const source = this.#one(payload);
    if (kind === 'scroll') {
      const deltaX = finiteNumber(payload.deltaX);
      const deltaY = finiteNumber(payload.deltaY);
      if (deltaX === null || deltaY === null || deltaX < -2000 || deltaX > 2000 || deltaY < -2000 || deltaY > 2000) {
        throw new Error('failed');
      }
      await Promise.all([...this.#views.values()].map(async view => {
        const sent = await this.#target(view).inputAgent().invoke_dispatchMouseEvent({
          type: Protocol.Input.DispatchMouseEventRequestType.MouseWheel,
          x: Math.trunc(view.width / 2),
          y: Math.trunc(view.height / 2),
          deltaX,
          deltaY,
        });
        if (sent.getError()) {
          throw new Error('failed');
        }
      }));
      return;
    }
    const x = finiteNumber(payload.x);
    const y = finiteNumber(payload.y);
    if (x === null || y === null || x < 0 || y < 0 || x >= source.width || y >= source.height) {
      throw new Error('failed');
    }
    const type = kind === 'hover' ? Protocol.Input.DispatchMouseEventRequestType.MouseMoved :
                                    Protocol.Input.DispatchMouseEventRequestType.MousePressed;
    await Promise.all([...this.#views.values()].map(async view => {
      const point = {
        x: project(x, source.width, view.width),
        y: project(y, source.height, view.height),
      };
      const agent = this.#target(view).inputAgent();
      const request: Protocol.Input.DispatchMouseEventRequest = {
        type,
        x: point.x,
        y: point.y,
        button: Protocol.Input.MouseButton.Left,
      };
      if (kind === 'click') {
        request.clickCount = 1;
      }
      const moved = await agent.invoke_dispatchMouseEvent(request);
      if (moved.getError()) {
        throw new Error('failed');
      }
      if (kind === 'click') {
        const released = await agent.invoke_dispatchMouseEvent({
          type: Protocol.Input.DispatchMouseEventRequestType.MouseReleased,
          x: point.x,
          y: point.y,
          button: Protocol.Input.MouseButton.Left,
          clickCount: 1,
        });
        if (released.getError()) {
          throw new Error('failed');
        }
      }
    }));
  }

  async #metrics(target: SDK.Target.Target, width: number, height: number, mobile: boolean,
                 landscape: boolean): Promise<void> {
    const applied = await target.emulationAgent().invoke_setDeviceMetricsOverride({
      width,
      height,
      deviceScaleFactor: 1,
      mobile,
      screenWidth: width,
      screenHeight: height,
      screenOrientation: {
        type: landscape ? Protocol.Emulation.ScreenOrientationType.LandscapePrimary :
                          Protocol.Emulation.ScreenOrientationType.PortraitPrimary,
        angle: landscape ? 90 : 0,
      },
    });
    if (applied.getError()) {
      throw new Error('failed');
    }
  }

  #selected(payload: Record<string, unknown>): ViewState[] {
    const viewportID = finiteNumber(payload.viewportID);
    if (viewportID === null) {
      return [...this.#views.values()];
    }
    const view = this.#views.get(viewportID);
    if (!view) {
      throw new Error('failed');
    }
    return [view];
  }

  #one(payload: Record<string, unknown>): ViewState {
    const selected = this.#selected(payload);
    const view = selected.length === 1 ? selected[0] : undefined;
    if (!view) {
      throw new Error('failed');
    }
    return view;
  }

  #target(view: ViewState): SDK.Target.Target {
    const target = SDK.TargetManager.TargetManager.instance().targetById(view.targetId);
    if (!target) {
      throw new Error('unavailable');
    }
    return target;
  }

  #sameLease(payload: Record<string, unknown>): boolean {
    return this.#lease > 0 && payload.leaseID === this.#lease;
  }

  async #dropTargets(): Promise<void> {
    const views = [...this.#views.values()];
    this.#views.clear();
    await Promise.all(views.map(view => this.#closeTarget(view.targetId)));
  }

  async #closeTarget(targetId: Protocol.Target.TargetID): Promise<void> {
    const root = SDK.TargetManager.TargetManager.instance().rootTarget();
    if (!root) {
      return;
    }
    await root.targetAgent().invoke_closeTarget({targetId});
  }
}

function waitForTarget(id: Protocol.Target.TargetID): Promise<SDK.Target.Target> {
  const manager = SDK.TargetManager.TargetManager.instance();
  const existing = manager.targetById(id);
  if (existing) {
    return Promise.resolve(existing);
  }
  return new Promise((resolve, reject) => {
    let settled = false;
    const observer = new SDK.TargetManager.Observer();
    const finish = (target: SDK.Target.Target|null): void => {
      if (settled) {
        return;
      }
      settled = true;
      clearTimeout(timer);
      manager.unobserveTargets(observer);
      if (target) {
        resolve(target);
      } else {
        reject(new Error('unavailable'));
      }
    };
    const timer = setTimeout(() => finish(null), TARGET_WAIT_MS);
    observer.targetAdded = (target): void => {
      if (target.id() === id) {
        finish(target);
      }
    };
    manager.observeTargets(observer);
  });
}

function cloneUrl(): string {
  const page = SDK.TargetManager.TargetManager.instance().primaryPageTarget();
  const url = page ? String(page.inspectedURL()) : '';
  return httpUrl(url) ? url : '';
}

function httpUrl(value: string): boolean {
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
  return url.protocol === 'http:' || url.protocol === 'https:';
}

function typingIsAllowed(text: string): boolean {
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

function sizeIsAllowed(width: number, height: number): boolean {
  return Number.isInteger(width) && Number.isInteger(height) && width >= 200 && width <= 1600 && height >= 200 &&
      height <= 1600;
}

function finiteNumber(value: unknown): number|null {
  return typeof value === 'number' && Number.isFinite(value) ? value : null;
}

function stringField(value: unknown): string {
  return typeof value === 'string' ? value : '';
}

function schemeFeature(value: unknown): string|null {
  if (value === 'light' || value === 'dark') {
    return value;
  }
  if (value === 'noPreference') {
    return '';
  }
  return null;
}

function project(value: number, from: number, to: number): number {
  if (from <= 0) {
    return 0;
  }
  return Math.trunc(value * to / from);
}
