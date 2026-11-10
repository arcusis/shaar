// Copyright 2026 The Shaar Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import * as i18n from '../../core/i18n/i18n.js';
import * as UI from '../../ui/legacy/legacy.js';
import {html, render} from '../../ui/lit/lit.js';

const UIStrings = {
  /**
   * @description Heading of the Shaar panel. The panel lists the DevTools build that is running.
   */
  build: 'Build',
  /**
   * @description Label for the Shaar DevTools overlay identifier.
   */
  overlay: 'Overlay',
  /**
   * @description Label for the Chromium version this DevTools frontend targets.
   */
  chromium: 'Chromium',
  /**
   * @description Label for the devtools-frontend git revision this panel was built against.
   */
  devtoolsFrontend: 'DevTools frontend',
} as const;

const str_ = i18n.i18n.registerUIStrings('panels/shaar/ShaarPanel.ts', UIStrings);
const i18nString = i18n.i18n.getLocalizedString.bind(undefined, str_);

const OVERLAY_ID = 'shaar-devtools-frontend';
const CHROMIUM_VERSION = '157.0.8103.51';
const DEVTOOLS_FRONTEND_REVISION = '12ada949de6a27116dea47c600da5322f44c64f4';

export class ShaarPanel extends UI.Panel.Panel {
  constructor() {
    super('shaar', /* useShadowDom */ true);
    this.requestUpdate();
  }

  override performUpdate(): void {
    // clang-format off
    render(html`
      <style>
        .shaar-build {
          padding: 16px 20px;
          color: var(--sys-color-on-surface);
          background: var(--sys-color-cdt-base);
          font-family: var(--default-font-family);
        }
        h1 {
          margin: 0 0 12px;
          font-size: 18px;
          font-weight: 600;
        }
        dl {
          display: grid;
          grid-template-columns: 9em 1fr;
          gap: 8px 12px;
          margin: 0;
        }
        dt {
          color: var(--sys-color-on-surface-subtle);
        }
        dd {
          margin: 0;
          font-family: ui-monospace, monospace;
        }
      </style>
      <section class="shaar-build">
        <h1>${i18nString(UIStrings.build)}</h1>
        <dl>
          <dt>${i18nString(UIStrings.overlay)}</dt>
          <dd>${OVERLAY_ID}</dd>
          <dt>${i18nString(UIStrings.chromium)}</dt>
          <dd>${CHROMIUM_VERSION}</dd>
          <dt>${i18nString(UIStrings.devtoolsFrontend)}</dt>
          <dd>${DEVTOOLS_FRONTEND_REVISION}</dd>
        </dl>
      </section>
    `, this.contentElement);
    // clang-format on
  }
}
