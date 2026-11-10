// Copyright 2026 The Shaar Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import * as i18n from '../../../core/i18n/i18n.js';
import * as UI from '../../../ui/legacy/legacy.js';

import type * as CopyForAgent from './copy-for-agent.js';

const UIStrings = {
  /**
   * @description Title of the Copy for agent panel in DevTools.
   */
  copyForAgent: 'Copy for agent',
  /**
   * @description Command for showing the Copy for agent panel.
   */
  showCopyForAgent: 'Show Copy for agent',
} as const;

const str_ = i18n.i18n.registerUIStrings('panels/shaar/copy-for-agent/copy-for-agent-meta.ts', UIStrings);
const i18nLazyString = i18n.i18n.getLazilyComputedLocalizedString.bind(undefined, str_);

let loadedCopyForAgentModule: (typeof CopyForAgent|undefined);

async function loadCopyForAgentModule(): Promise<typeof CopyForAgent> {
  if (!loadedCopyForAgentModule) {
    loadedCopyForAgentModule = await import('./copy-for-agent.js');
  }
  return loadedCopyForAgentModule;
}

UI.ViewManager.registerViewExtension({
  location: UI.ViewManager.ViewLocationValues.PANEL,
  id: 'shaar-copy-for-agent',
  title: i18nLazyString(UIStrings.copyForAgent),
  commandPrompt: i18nLazyString(UIStrings.showCopyForAgent),
  order: 202,
  persistence: UI.ViewManager.ViewPersistence.CLOSEABLE,
  async loadView() {
    const CopyForAgent = await loadCopyForAgentModule();
    return new CopyForAgent.CopyForAgentPanel.CopyForAgentPanel();
  },
});
