// Copyright 2026 The Shaar Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import {assert} from 'chai';

import * as Viewports from './viewports.js';

class FakeTargets {
  inspected = 'https://inspected.example/start';
  failNavigate = false;
  beforeNavigate: (() => Promise<unknown>)|null = null;
  readonly created: Array<{url?: string, hidden?: boolean, background?: boolean, width?: number}> = [];
  readonly closed: string[] = [];
  readonly navigated: string[] = [];
  readonly mice = new Map<string, Array<{type: string, x: number, y: number}>>();
  readonly ids: string[] = [];
  #pages = new Map<string, Viewports.ViewportsHost.ViewportPage>();

  rootTarget(): Viewports.ViewportsHost.ViewportRoot|null {
    return {
      createTarget: request => {
        const created: {url?: string, hidden?: boolean, background?: boolean, width?: number} = {
          url: request.url,
          hidden: request.hidden,
          background: request.background,
        };
        if (request.width !== undefined) {
          created.width = request.width;
        }
        this.created.push(created);
        const id = `target-${this.ids.length + 1}`;
        this.ids.push(id);
        this.#pages.set(id, this.#page(id));
        return Promise.resolve({targetId: id});
      },
      closeTarget: async targetId => {
        this.closed.push(targetId);
      },
    };
  }

  primaryPageTarget(): {inspectedURL(): string} {
    return {inspectedURL: () => this.inspected};
  }

  pageById(id: string): Viewports.ViewportsHost.ViewportPage|null {
    return this.#pages.get(id) ?? null;
  }

  observePages(): void {
  }

  unobservePages(): void {
  }

  #page(id: string): Viewports.ViewportsHost.ViewportPage {
    return {
      id: () => id,
      inspectedURL: () => this.navigated[this.navigated.length - 1] ?? this.inspected,
      navigate: async url => {
        if (this.beforeNavigate) {
          await this.beforeNavigate();
        }
        if (this.failNavigate) {
          return 'failed';
        }
        this.navigated.push(url);
        return undefined;
      },
      captureScreenshot: () => Promise.resolve({data: 'png'}),
      setDeviceMetrics: () => Promise.resolve(undefined),
      setColorScheme: () => Promise.resolve(undefined),
      insertText: () => Promise.resolve(undefined),
      dispatchMouse: request => {
        const events = this.mice.get(id) ?? [];
        events.push({type: String(request.type), x: request.x, y: request.y});
        this.mice.set(id, events);
        return Promise.resolve(undefined);
      },
    };
  }
}

function hostFor(targets: FakeTargets): Viewports.ViewportsHost.SdkViewportHost {
  return new Viewports.ViewportsHost.SdkViewportHost(targets);
}

async function openHost(targets: FakeTargets): Promise<{
  host: Viewports.ViewportsHost.SdkViewportHost,
  leaseID: number,
}> {
  const host = hostFor(targets);
  const opened = await host.request('open', {schemaVersion: 1});
  assert.strictEqual(typeof opened.leaseID, 'number');
  return {host, leaseID: opened.leaseID ?? 0};
}

describe('SdkViewportHost', () => {
  it('creates a hidden background target and loads the current url', async () => {
    const targets = new FakeTargets();
    const {host, leaseID} = await openHost(targets);
    const added = await host.request('add', {
      schemaVersion: 1,
      leaseID,
      preset: 'desktop',
      width: 1280,
      height: 800,
      url: 'https://example.com/now',
    });
    assert.strictEqual(added.viewportID, 1);
    assert.deepEqual(targets.created[0], {url: '', hidden: true, background: true});
    assert.deepEqual(targets.navigated, ['https://example.com/now']);
    await host.request('close', {schemaVersion: 1, leaseID});
  });

  it('falls back to the inspected page when add has no url', async () => {
    const targets = new FakeTargets();
    const {host, leaseID} = await openHost(targets);
    await host.request('add', {schemaVersion: 1, leaseID, preset: 'desktop', width: 1280, height: 800});
    assert.deepEqual(targets.navigated, ['https://inspected.example/start']);
    await host.request('close', {schemaVersion: 1, leaseID});
  });

  it('closes the target when add fails after create', async () => {
    const targets = new FakeTargets();
    targets.failNavigate = true;
    const {host, leaseID} = await openHost(targets);
    try {
      await host.request('add', {schemaVersion: 1, leaseID, preset: 'desktop', width: 1280, height: 800});
      assert.fail('add should close the target when navigation fails');
    } catch (error) {
      assert.instanceOf(error, Error);
      assert.strictEqual(error.message, 'failed');
    }
    assert.deepEqual(targets.closed, ['target-1']);
    targets.failNavigate = false;
    const added = await host.request('add', {schemaVersion: 1, leaseID, preset: 'desktop', width: 1280, height: 800});
    assert.strictEqual(added.viewportID, 1);
    await host.request('close', {schemaVersion: 1, leaseID});
  });

  it('drops every target when the lease changes', async () => {
    const targets = new FakeTargets();
    const {host, leaseID} = await openHost(targets);
    await host.request('add', {schemaVersion: 1, leaseID, preset: 'iphone15Pro', width: 393, height: 852});
    await host.request('add', {schemaVersion: 1, leaseID, preset: 'desktop', width: 1280, height: 800});
    await host.request('close', {schemaVersion: 1, leaseID});
    assert.deepEqual(targets.closed, ['target-1', 'target-2']);
    try {
      await host.request('add', {schemaVersion: 1, leaseID, preset: 'desktop', width: 1280, height: 800});
      assert.fail('the old lease should be dead');
    } catch (error) {
      assert.instanceOf(error, Error);
      assert.strictEqual(error.message, 'failed');
    }
  });

  it('closes a target that is still being added when the lease changes', async () => {
    const targets = new FakeTargets();
    const {host, leaseID} = await openHost(targets);
    targets.beforeNavigate = () => host.request('close', {schemaVersion: 1, leaseID});
    try {
      await host.request('add', {schemaVersion: 1, leaseID, preset: 'desktop', width: 1280, height: 800});
      assert.fail('add should stop when the session closes');
    } catch (error) {
      assert.instanceOf(error, Error);
      assert.strictEqual(error.message, 'failed');
    }
    assert.deepEqual(targets.closed, ['target-1']);
  });

  it('sends a click and a hover to the source viewport only', async () => {
    const targets = new FakeTargets();
    const {host, leaseID} = await openHost(targets);
    const phone = await host.request('add', {
      schemaVersion: 1,
      leaseID,
      preset: 'iphone15Pro',
      width: 393,
      height: 852,
    });
    await host.request('add', {schemaVersion: 1, leaseID, preset: 'desktop', width: 1280, height: 800});
    await host.request('action', {
      schemaVersion: 1,
      leaseID,
      kind: 'click',
      viewportID: phone.viewportID,
      x: 10,
      y: 20,
    });
    await host.request('action', {
      schemaVersion: 1,
      leaseID,
      kind: 'hover',
      viewportID: phone.viewportID,
      x: 12,
      y: 24,
    });
    assert.deepEqual(targets.mice.get('target-1'), [
      {type: 'mousePressed', x: 10, y: 20},
      {type: 'mouseReleased', x: 10, y: 20},
      {type: 'mouseMoved', x: 12, y: 24},
    ]);
    assert.isUndefined(targets.mice.get('target-2'));
    await host.request('action', {
      schemaVersion: 1,
      leaseID,
      kind: 'scroll',
      viewportID: phone.viewportID,
      deltaX: 0,
      deltaY: 40,
    });
    assert.lengthOf(targets.mice.get('target-1') ?? [], 4);
    assert.lengthOf(targets.mice.get('target-2') ?? [], 1);
    await host.request('close', {schemaVersion: 1, leaseID});
  });
});
