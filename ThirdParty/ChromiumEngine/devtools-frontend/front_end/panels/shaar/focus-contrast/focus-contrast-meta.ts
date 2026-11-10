// Copyright 2026 The Shaar Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import * as i18n from '../../../core/i18n/i18n.js';
import * as UI from '../../../ui/legacy/legacy.js';

import type * as Focus from './focus-contrast.js';

const UIStrings = {
  /**
   * @description Title of the Focus panel, which paints tab order and failing contrast on the page.
   */
  focus: 'Focus',
  /**
   * @description Command for showing the Focus panel.
   */
  showFocus: 'Show Focus',
} as const;

const str_ = i18n.i18n.registerUIStrings('panels/shaar/focus-contrast/focus-contrast-meta.ts', UIStrings);
const i18nLazyString = i18n.i18n.getLazilyComputedLocalizedString.bind(undefined, str_);

let loadedFocusModule: (typeof Focus|undefined);

async function loadFocusModule(): Promise<typeof Focus> {
  if (!loadedFocusModule) {
    loadedFocusModule = await import('./focus-contrast.js');
  }
  return loadedFocusModule;
}

UI.ViewManager.registerViewExtension({
  location: UI.ViewManager.ViewLocationValues.PANEL,
  id: 'shaar-focus-contrast',
  title: i18nLazyString(UIStrings.focus),
  commandPrompt: i18nLazyString(UIStrings.showFocus),
  order: 208,
  persistence: UI.ViewManager.ViewPersistence.CLOSEABLE,
  async loadView() {
    const Focus = await loadFocusModule();
    return new Focus.FocusContrastPanel.FocusContrastPanel();
  },
});
