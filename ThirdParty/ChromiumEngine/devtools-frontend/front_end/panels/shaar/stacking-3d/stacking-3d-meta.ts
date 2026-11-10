// Copyright 2026 The Shaar Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import * as i18n from '../../../core/i18n/i18n.js';
import * as UI from '../../../ui/legacy/legacy.js';

import type * as Stacking from './stacking-3d.js';

const UIStrings = {
  /**
   * @description Title of the Shaar 3D stacking panel.
   */
  stacking: '3D view',
  /**
   * @description Command for showing the Shaar 3D stacking panel.
   */
  showStacking: 'Show 3D view',
} as const;

const str_ = i18n.i18n.registerUIStrings('panels/shaar/stacking-3d/stacking-3d-meta.ts', UIStrings);
const i18nLazyString = i18n.i18n.getLazilyComputedLocalizedString.bind(undefined, str_);

let loadedStackingModule: (typeof Stacking|undefined);

async function loadStackingModule(): Promise<typeof Stacking> {
  if (!loadedStackingModule) {
    loadedStackingModule = await import('./stacking-3d.js');
  }
  return loadedStackingModule;
}

UI.ViewManager.registerViewExtension({
  location: UI.ViewManager.ViewLocationValues.PANEL,
  id: 'shaar-stacking-3d',
  title: i18nLazyString(UIStrings.stacking),
  commandPrompt: i18nLazyString(UIStrings.showStacking),
  order: 206,
  persistence: UI.ViewManager.ViewPersistence.CLOSEABLE,
  async loadView() {
    const Stacking = await loadStackingModule();
    return new Stacking.StackingPanel.StackingPanel();
  },
});
