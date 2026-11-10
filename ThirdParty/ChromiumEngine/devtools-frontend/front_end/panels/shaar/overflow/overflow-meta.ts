// Copyright 2026 The Shaar Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import * as i18n from '../../../core/i18n/i18n.js';
import * as UI from '../../../ui/legacy/legacy.js';

import type * as Overflow from './overflow.js';

const UIStrings = {
  /**
   * @description Title of the Overflow panel, which lists elements that make the page scroll.
   */
  overflow: 'Overflow',
  /**
   * @description Command for showing the Overflow panel.
   */
  showOverflow: 'Show Overflow',
} as const;

const str_ = i18n.i18n.registerUIStrings('panels/shaar/overflow/overflow-meta.ts', UIStrings);
const i18nLazyString = i18n.i18n.getLazilyComputedLocalizedString.bind(undefined, str_);

let loadedOverflowModule: (typeof Overflow|undefined);

async function loadOverflowModule(): Promise<typeof Overflow> {
  if (!loadedOverflowModule) {
    loadedOverflowModule = await import('./overflow.js');
  }
  return loadedOverflowModule;
}

UI.ViewManager.registerViewExtension({
  location: UI.ViewManager.ViewLocationValues.PANEL,
  id: 'shaar-overflow',
  title: i18nLazyString(UIStrings.overflow),
  commandPrompt: i18nLazyString(UIStrings.showOverflow),
  order: 207,
  persistence: UI.ViewManager.ViewPersistence.CLOSEABLE,
  async loadView() {
    const Overflow = await loadOverflowModule();
    return new Overflow.OverflowPanel.OverflowPanel();
  },
});
