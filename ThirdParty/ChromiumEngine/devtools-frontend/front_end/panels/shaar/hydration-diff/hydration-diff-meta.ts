// Copyright 2026 The Shaar Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import * as i18n from '../../../core/i18n/i18n.js';
import * as UI from '../../../ui/legacy/legacy.js';

import type * as Hydration from './hydration-diff.js';

const UIStrings = {
  /**
   * @description Title of the Hydration panel, which diffs server HTML against the hydrated DOM.
   */
  hydration: 'Hydration',
  /**
   * @description Command for showing the Hydration panel.
   */
  showHydration: 'Show Hydration',
} as const;

const str_ = i18n.i18n.registerUIStrings('panels/shaar/hydration-diff/hydration-diff-meta.ts', UIStrings);
const i18nLazyString = i18n.i18n.getLazilyComputedLocalizedString.bind(undefined, str_);

let loadedHydrationModule: (typeof Hydration|undefined);

async function loadHydrationModule(): Promise<typeof Hydration> {
  if (!loadedHydrationModule) {
    loadedHydrationModule = await import('./hydration-diff.js');
  }
  return loadedHydrationModule;
}

UI.ViewManager.registerViewExtension({
  location: UI.ViewManager.ViewLocationValues.PANEL,
  id: 'shaar-hydration',
  title: i18nLazyString(UIStrings.hydration),
  commandPrompt: i18nLazyString(UIStrings.showHydration),
  order: 204,
  persistence: UI.ViewManager.ViewPersistence.CLOSEABLE,
  async loadView() {
    const Hydration = await loadHydrationModule();
    return new Hydration.HydrationPanel.HydrationPanel();
  },
});
