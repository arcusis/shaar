// Copyright 2026 The Shaar Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import {assert} from 'chai';

import {renderElementIntoDOM} from '../../../testing/DOMHelpers.js';
import {describeWithEnvironment} from '../../../testing/EnvironmentHelpers.js';

import * as Viewports from './viewports.js';

const TINY_PNG = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';

class RecordingHost {
  failOpen = false;
  readonly #capabilities: {colorScheme?: number, hover?: number, typing?: number};
  #nextId = 1;

  constructor(capabilities: {colorScheme?: number, hover?: number, typing?: number} = {}) {
    this.#capabilities = capabilities;
  }

  request(operation: string, payload: Record<string, unknown>): Promise<Viewports.ViewportsHost.ViewportReply> {
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
      const viewportID = payload.viewportID;
      return Promise.resolve({
        schemaVersion: 1,
        viewportID: typeof viewportID === 'number' ? viewportID : 0,
        url: 'https://example.com/',
        data: TINY_PNG,
      });
    }
    return Promise.resolve({schemaVersion: 1});
  }
}

describeWithEnvironment('ViewportsPanel', () => {
  const openPanels: Viewports.ViewportsPanel.ViewportsPanel[] = [];

  afterEach(async () => {
    const panel = openPanels.pop();
    if (!panel) {
      return;
    }
    panel.controller.stopPolling();
    await panel.controller.close();
    panel.detach(true);
  });

  function panelFor(host: RecordingHost): Viewports.ViewportsPanel.ViewportsPanel {
    const panel = new Viewports.ViewportsPanel.ViewportsPanel(host);
    openPanels.push(panel);
    return panel;
  }

  it('shows the empty state before a session opens', () => {
    const panel = panelFor(new RecordingHost());
    panel.performUpdate();
    const empty = panel.contentElement.querySelector('.viewports-empty');
    assert.instanceOf(empty, HTMLElement);
    assert.include(empty.textContent ?? '', 'See this page at several sizes');
  });

  it('shows an error when the host rejects the session', async () => {
    const host = new RecordingHost();
    host.failOpen = true;
    const panel = panelFor(host);
    await panel.controller.open();
    panel.performUpdate();
    const error = panel.contentElement.querySelector('.viewports-error');
    assert.instanceOf(error, HTMLElement);
    assert.include(error.textContent ?? '', 'Viewports aren’t connected');
    const retry = error.querySelector('.viewports-retry');
    assert.instanceOf(retry, HTMLButtonElement);
  });

  it('hides color and typing controls when the engine does not advertise them', async () => {
    const panel = panelFor(new RecordingHost());
    renderElementIntoDOM(panel);
    await panel.controller.open();
    await Promise.resolve();
    panel.controller.stopPolling();
    panel.performUpdate();
    assert.lengthOf(panel.contentElement.querySelectorAll('.viewports-card'), 2);
    const shot = panel.contentElement.querySelector('.viewports-shot');
    assert.instanceOf(shot, HTMLButtonElement);
    assert.strictEqual(shot.textContent.trim(), 'Screenshot all');
    assert.isNull(panel.contentElement.querySelector('.viewports-match'));
    assert.isNull(panel.contentElement.querySelector('.viewports-type'));
  });

  it('shows the shared scheme menu and the type field when the engine allows them', async () => {
    const panel = panelFor(new RecordingHost({colorScheme: 1, hover: 1, typing: 1}));
    await panel.controller.open();
    panel.performUpdate();
    assert.instanceOf(panel.contentElement.querySelector('.viewports-match'), HTMLSelectElement);
    assert.instanceOf(panel.contentElement.querySelector('.viewports-type'), HTMLInputElement);
    assert.lengthOf(panel.contentElement.querySelectorAll('.viewports-scheme'), 2);
  });
});
