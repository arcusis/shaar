// Copyright 2026 The Shaar Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import * as i18n from '../../../core/i18n/i18n.js';
import * as UI from '../../../ui/legacy/legacy.js';

import type * as NetworkRules from './network-rules.js';

const UIStrings = {
  /**
   * @description Title of the Shaar network rules drawer.
   */
  networkRules: 'Network rules',
  /**
   * @description Command for showing the Shaar network rules drawer.
   */
  showNetworkRules: 'Show Network rules',
} as const;

const str_ = i18n.i18n.registerUIStrings('panels/shaar/network-rules/network-rules-meta.ts', UIStrings);
const i18nLazyString = i18n.i18n.getLazilyComputedLocalizedString.bind(undefined, str_);

let loadedNetworkRulesModule: (typeof NetworkRules|undefined);

async function loadNetworkRulesModule(): Promise<typeof NetworkRules> {
  if (!loadedNetworkRulesModule) {
    loadedNetworkRulesModule = await import('./network-rules.js');
  }
  return loadedNetworkRulesModule;
}

UI.ViewManager.registerViewExtension({
  location: UI.ViewManager.ViewLocationValues.DRAWER_VIEW,
  id: 'shaar-network-rules',
  title: i18nLazyString(UIStrings.networkRules),
  commandPrompt: i18nLazyString(UIStrings.showNetworkRules),
  order: 45,
  persistence: UI.ViewManager.ViewPersistence.CLOSEABLE,
  async loadView() {
    const NetworkRules = await loadNetworkRulesModule();
    return new NetworkRules.NetworkRulesView.NetworkRulesView();
  },
});
