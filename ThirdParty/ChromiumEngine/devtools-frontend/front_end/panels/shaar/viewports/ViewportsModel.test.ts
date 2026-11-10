// Copyright 2026 The Shaar Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import {assert} from 'chai';

import * as Viewports from './viewports.js';

const TINY_PNG = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';

class RecordingHost {
  readonly calls: Array<{operation: string, payload: Record<string, unknown>}> = [];
  failOpen = false;
  holdFrames = false;
  readonly #capabilities: {colorScheme?: number, hover?: number, typing?: number};
  #nextId = 1;
  #url = 'https://example.com/';
  #releaseFrame: () => void = () => {};

  constructor(capabilities: {colorScheme?: number, hover?: number, typing?: number} = {
    colorScheme: 1,
    hover: 1,
    typing: 1,
  }) {
    this.#capabilities = capabilities;
  }

  releaseFrames(): void {
    this.holdFrames = false;
    this.#releaseFrame();
  }

  request(operation: string, payload: Record<string, unknown>): Promise<Viewports.ViewportsHost.ViewportReply> {
    this.calls.push({operation, payload: {...payload}});
    if (operation === 'action' && payload.kind === 'navigate' && typeof payload.url === 'string') {
      this.#url = payload.url;
    }
    if (operation === 'open') {
      if (this.failOpen) {
        return Promise.reject(new Error('unavailable'));
      }
      return Promise.resolve({schemaVersion: 1, leaseID: 4, ...this.#capabilities});
    }
    if (operation === 'add') {
      const viewportID = this.#nextId;
      this.#nextId += 1;
      return Promise.resolve({schemaVersion: 1, viewportID});
    }
    if (operation === 'frame') {
      const reply = this.#frameReply(payload);
      if (!this.holdFrames) {
        return Promise.resolve(reply);
      }
      return new Promise(resolve => {
        this.#releaseFrame = () => resolve(reply);
      });
    }
    return Promise.resolve({schemaVersion: 1});
  }

  #frameReply(payload: Record<string, unknown>): Viewports.ViewportsHost.ViewportReply {
    const viewportID = payload.viewportID;
    return {
      schemaVersion: 1,
      viewportID: typeof viewportID === 'number' ? viewportID : 0,
      url: this.#url,
      data: TINY_PNG,
    };
  }
}

function actionPayloads(host: RecordingHost, kind: string): Array<Record<string, unknown>> {
  const payloads: Array<Record<string, unknown>> = [];
  for (const call of host.calls) {
    if (call.operation === 'action' && call.payload.kind === kind) {
      payloads.push(call.payload);
    }
  }
  return payloads;
}

describe('ViewportsModel', () => {
  it('accepts printable text up to 64 bytes', () => {
    assert.isFalse(Viewports.ViewportsModel.typingIsValid(''));
    assert.isFalse(Viewports.ViewportsModel.typingIsValid('a'.repeat(65)));
    assert.isFalse(Viewports.ViewportsModel.typingIsValid('a\n'));
    assert.isTrue(Viewports.ViewportsModel.typingIsValid('a b'));
    assert.isTrue(Viewports.ViewportsModel.typingIsValid('a'.repeat(64)));
  });

  it('accepts only http and https page urls', () => {
    assert.isTrue(Viewports.ViewportsModel.pageUrlIsValid('https://example.com/a'));
    assert.isTrue(Viewports.ViewportsModel.pageUrlIsValid('http://localhost:8080/'));
    assert.isFalse(Viewports.ViewportsModel.pageUrlIsValid('file:///etc/passwd'));
    assert.isFalse(Viewports.ViewportsModel.pageUrlIsValid('javascript:alert(1)'));
    assert.isFalse(Viewports.ViewportsModel.pageUrlIsValid('https://user:pass@example.com/'));
  });

  it('projects a point from the preview into the page', () => {
    assert.strictEqual(Viewports.ViewportsModel.projectPoint(10, 0, 100), 0);
    assert.strictEqual(Viewports.ViewportsModel.projectPoint(1, 2, 5), 2);
  });

  it('fits a phone and a desktop on one contact sheet', () => {
    const sizes = [
      {width: 393, height: 852},
      {width: 1280, height: 800},
    ];
    const scale = Viewports.ViewportsModel.contactSheetScale(sizes);
    const canvas = Viewports.ViewportsModel.contactSheetCanvasSize(sizes);
    assert.isBelow(scale, 1);
    assert.isAtMost(canvas.width, 2400);
    assert.isAtMost(canvas.height, 780);
    assert.isAtMost(Viewports.ViewportsModel.fitScale(sizes, {width: 960, height: 520}), 1);
  });

  it('opens a phone and a desktop and reads the capability bits', async () => {
    const host = new RecordingHost();
    const controller = new Viewports.ViewportsModel.ViewportController(host);
    await controller.open();
    assert.strictEqual(controller.status, 'ready');
    assert.lengthOf(controller.frames, 2);
    assert.strictEqual(controller.frames[0].preset, 'iphone15Pro');
    assert.strictEqual(controller.frames[1].preset, 'desktop');
    assert.isTrue(controller.capabilities.colorScheme);
    assert.isTrue(controller.capabilities.hover);
    assert.isTrue(controller.capabilities.typing);
    await controller.close();
  });

  it('keeps color, hover, and typing off when the open reply omits them', async () => {
    const controller = new Viewports.ViewportsModel.ViewportController(new RecordingHost({}));
    await controller.open();
    assert.isFalse(controller.capabilities.colorScheme);
    assert.isFalse(controller.capabilities.hover);
    assert.isFalse(controller.capabilities.typing);
    await controller.close();
  });

  it('clears a mirrored scheme when one viewport changes on its own', async () => {
    const controller = new Viewports.ViewportsModel.ViewportController(new RecordingHost());
    await controller.open();
    await controller.mirrorColorScheme('dark');
    assert.strictEqual(controller.mirroredScheme, 'dark');
    assert.strictEqual(controller.frames[0].colorScheme, 'dark');
    assert.strictEqual(controller.frames[1].colorScheme, 'dark');

    await controller.setColorScheme(controller.frames[0].id, 'light');
    assert.isNull(controller.mirroredScheme);
    assert.strictEqual(controller.frames[0].colorScheme, 'light');

    await controller.add('pixel8');
    assert.lengthOf(controller.frames, 3);
    assert.strictEqual(controller.frames[2].preset, 'pixel8');
    assert.strictEqual(controller.frames[2].colorScheme, 'noPreference');
    await controller.close();
  });

  it('sends one source click and dedupes a repeated hover', async () => {
    const host = new RecordingHost();
    const controller = new Viewports.ViewportsModel.ViewportController(host);
    await controller.open();
    const phone = controller.frames[0];
    await controller.click(phone.id, 10, 20);
    const clicks = actionPayloads(host, 'click');
    assert.lengthOf(clicks, 1);
    assert.strictEqual(clicks[0].viewportID, phone.nativeId);
    assert.strictEqual(clicks[0].x, 10);
    assert.strictEqual(clicks[0].y, 20);

    await controller.hover(phone.id, 11, 21);
    await controller.hover(phone.id, 11, 21);
    const hovers = actionPayloads(host, 'hover');
    assert.lengthOf(hovers, 1);
    assert.strictEqual(hovers[0].viewportID, phone.nativeId);
    assert.strictEqual(hovers[0].x, 11);
    assert.strictEqual(hovers[0].y, 21);
    await controller.close();
  });

  it('types into every viewport and rejects an empty string', async () => {
    const host = new RecordingHost();
    const controller = new Viewports.ViewportsModel.ViewportController(host);
    await controller.open();
    await controller.typeIntoAll('Hi');
    const typed = actionPayloads(host, 'type');
    assert.lengthOf(typed, 1);
    assert.strictEqual(typed[0].text, 'Hi');
    assert.strictEqual(typed[0].viewportID, controller.frames[0].nativeId);

    const before = host.calls.length;
    await controller.typeIntoAll('');
    assert.strictEqual(host.calls.length, before);
    assert.strictEqual(controller.notice, 'invalid');
    await controller.close();
  });

  it('checks the png signature without decoding the image', () => {
    const original = globalThis.atob;
    const seen: string[] = [];
    globalThis.atob = (value: string) => {
      seen.push(value);
      return original(value);
    };
    try {
      const decoded = Viewports.ViewportsModel.decodeFrameReply({
        schemaVersion: 1,
        viewportID: 3,
        url: 'https://example.com/a',
        data: TINY_PNG,
      },
                                                                3);
      assert.strictEqual(decoded?.pngBase64, TINY_PNG);
      assert.deepEqual(seen.map(value => value.length), [12]);
      seen.length = 0;
      assert.isNull(Viewports.ViewportsModel.decodeFrameReply({
        schemaVersion: 1,
        viewportID: 3,
        url: 'https://example.com/a',
        data: 'A'.repeat(TINY_PNG.length),
      },
                                                              3));
      assert.lengthOf(seen, 0);
    } finally {
      globalThis.atob = original;
    }
  });

  it('skips an overlapping poll and still runs a demanded capture', async () => {
    const host = new RecordingHost();
    const controller = new Viewports.ViewportsModel.ViewportController(host);
    await controller.open();
    host.holdFrames = true;
    const started = host.calls.filter(call => call.operation === 'frame').length;
    const running = controller.refresh(false);
    await Promise.resolve();
    const during = host.calls.filter(call => call.operation === 'frame').length;
    assert.strictEqual(during, started + 1);
    await controller.refresh(false);
    assert.strictEqual(host.calls.filter(call => call.operation === 'frame').length, during);
    const demanded = controller.refresh(true);
    host.releaseFrames();
    await running;
    await demanded;
    assert.strictEqual(host.calls.filter(call => call.operation === 'frame').length, during + 3);
    await controller.close();
  });

  it('polls no faster than twice a second', () => {
    const originalSet = window.setInterval;
    const originalClear = window.clearInterval;
    let delay = 0;
    window.setInterval = ((_handler: TimerHandler, timeout?: number) => {
                           delay = Number(timeout);
                           return 1;
                         }) as typeof window.setInterval;
    window.clearInterval = (() => {}) as typeof window.clearInterval;
    try {
      const controller = new Viewports.ViewportsModel.ViewportController(new RecordingHost());
      controller.startPolling();
      assert.isAtLeast(delay, 500);
      controller.stopPolling();
    } finally {
      window.setInterval = originalSet;
      window.clearInterval = originalClear;
    }
  });

  it('does not notify listeners when a hover leaves the panel unchanged', async () => {
    const host = new RecordingHost();
    const controller = new Viewports.ViewportsModel.ViewportController(host);
    await controller.open();
    const phone = controller.frames[0];
    let updates = 0;
    const stop = controller.listen(() => {
      updates += 1;
    });
    await controller.click(phone.id, 10, 20);
    assert.strictEqual(updates, 1);
    await controller.hover(phone.id, 11, 21);
    await controller.hover(phone.id, 30, 40);
    assert.strictEqual(updates, 1);
    assert.lengthOf(actionPayloads(host, 'hover'), 2);
    stop();
    await controller.close();
  });

  it('adds the next viewport at the current url', async () => {
    const host = new RecordingHost();
    const controller = new Viewports.ViewportsModel.ViewportController(host);
    await controller.open();
    const opened = host.calls.filter(call => call.operation === 'add');
    assert.isUndefined(opened[0].payload.url);
    await controller.navigate('https://example.com/now');
    await controller.add('ipad');
    const added = host.calls.filter(call => call.operation === 'add');
    assert.strictEqual(added[added.length - 1].payload.url, 'https://example.com/now');
    assert.strictEqual(controller.frames[controller.frames.length - 1].url, 'https://example.com/now');
    await controller.close();
  });
});
