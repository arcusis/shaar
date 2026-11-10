// Copyright 2026 The Shaar Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import * as i18n from '../../../core/i18n/i18n.js';
import * as UI from '../../../ui/legacy/legacy.js';

import type * as BuildInfo from './build-info.js';

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

const str_ = i18n.i18n.registerUIStrings('panels/shaar/build-info/build-info-meta.ts', UIStrings);
const i18nLazyString = i18n.i18n.getLazilyComputedLocalizedString.bind(undefined, str_);

let loadedBuildInfoModule: (typeof BuildInfo|undefined);

async function loadBuildInfoModule(): Promise<typeof BuildInfo> {
  if (!loadedBuildInfoModule) {
    loadedBuildInfoModule = await import('./build-info.js');
  }
  return loadedBuildInfoModule;
}

UI.ViewManager.registerViewExtension({
  location: UI.ViewManager.ViewLocationValues.PANEL,
  id: 'shaar-build-info',
  title: i18nLazyString(UIStrings.shaar),
  commandPrompt: i18nLazyString(UIStrings.showShaar),
  order: 200,
  persistence: UI.ViewManager.ViewPersistence.CLOSEABLE,
  async loadView() {
    const BuildInfo = await loadBuildInfoModule();
    return new BuildInfo.BuildInfoPanel.BuildInfoPanel();
  },
});
