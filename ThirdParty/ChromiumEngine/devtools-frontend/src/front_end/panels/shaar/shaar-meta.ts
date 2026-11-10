// Copyright 2026 The Shaar Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import * as i18n from '../../core/i18n/i18n.js';
import * as UI from '../../ui/legacy/legacy.js';

import type * as Shaar from './shaar.js';

const UIStrings = {
  /**
   * @description Title of the Shaar panel in DevTools.
   */
  shaar: 'Shaar',
  /**
   * @description Command for showing the Shaar panel.
   */
  showShaar: 'Show Shaar',
} as const;

const str_ = i18n.i18n.registerUIStrings('panels/shaar/shaar-meta.ts', UIStrings);
const i18nLazyString = i18n.i18n.getLazilyComputedLocalizedString.bind(undefined, str_);

let loadedShaarModule: (typeof Shaar|undefined);

async function loadShaarModule(): Promise<typeof Shaar> {
  if (!loadedShaarModule) {
    loadedShaarModule = await import('./shaar.js');
  }
  return loadedShaarModule;
}

UI.ViewManager.registerViewExtension({
  location: UI.ViewManager.ViewLocationValues.PANEL,
  id: 'shaar',
  title: i18nLazyString(UIStrings.shaar),
  commandPrompt: i18nLazyString(UIStrings.showShaar),
  order: 200,
  persistence: UI.ViewManager.ViewPersistence.CLOSEABLE,
  async loadView() {
    const Shaar = await loadShaarModule();
    return new Shaar.ShaarPanel.ShaarPanel();
  },
});
