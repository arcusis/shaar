// Copyright 2026 The Shaar Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import * as i18n from '../../../core/i18n/i18n.js';
import * as UI from '../../../ui/legacy/legacy.js';

import type * as GraphQLTRPC from './graphql-trpc.js';

const UIStrings = {
  /**
   * @description Title of the API operations panel in DevTools. The panel names GraphQL and tRPC calls.
   */
  api: 'API',
  /**
   * @description Command for showing the API operations panel.
   */
  showAPI: 'Show API operations',
} as const;

const str_ = i18n.i18n.registerUIStrings('panels/shaar/graphql-trpc/graphql-trpc-meta.ts', UIStrings);
const i18nLazyString = i18n.i18n.getLazilyComputedLocalizedString.bind(undefined, str_);

let loadedModule: (typeof GraphQLTRPC|undefined);

async function loadModule(): Promise<typeof GraphQLTRPC> {
  if (!loadedModule) {
    loadedModule = await import('./graphql-trpc.js');
  }
  return loadedModule;
}

UI.ViewManager.registerViewExtension({
  location: UI.ViewManager.ViewLocationValues.PANEL,
  id: 'shaar-graphql-trpc',
  title: i18nLazyString(UIStrings.api),
  commandPrompt: i18nLazyString(UIStrings.showAPI),
  order: 205,
  persistence: UI.ViewManager.ViewPersistence.CLOSEABLE,
  async loadView() {
    const GraphQLTRPC = await loadModule();
    return new GraphQLTRPC.APIOperationsPanel.APIOperationsPanel();
  },
});
