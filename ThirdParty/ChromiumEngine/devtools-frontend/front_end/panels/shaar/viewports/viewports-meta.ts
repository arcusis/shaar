// Copyright 2026 The Shaar Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import * as i18n from '../../../core/i18n/i18n.js';
import * as UI from '../../../ui/legacy/legacy.js';

import type * as Viewports from './viewports.js';

const UIStrings = {
  /**
   * @description Title of the Viewports panel in DevTools.
   */
  viewports: 'Viewports',
  /**
   * @description Command for showing the Viewports panel.
   */
  showViewports: 'Show Viewports',
} as const;

const str_ = i18n.i18n.registerUIStrings('panels/shaar/viewports/viewports-meta.ts', UIStrings);
const i18nLazyString = i18n.i18n.getLazilyComputedLocalizedString.bind(undefined, str_);

let loadedViewportsModule: (typeof Viewports|undefined);

async function loadViewportsModule(): Promise<typeof Viewports> {
  if (!loadedViewportsModule) {
    loadedViewportsModule = await import('./viewports.js');
  }
  return loadedViewportsModule;
}

UI.ViewManager.registerViewExtension({
  location: UI.ViewManager.ViewLocationValues.PANEL,
  id: 'shaar-viewports',
  title: i18nLazyString(UIStrings.viewports),
  commandPrompt: i18nLazyString(UIStrings.showViewports),
  order: 201,
  persistence: UI.ViewManager.ViewPersistence.CLOSEABLE,
  async loadView() {
    const Viewports = await loadViewportsModule();
    return new Viewports.ViewportsPanel.ViewportsPanel();
  },
});
