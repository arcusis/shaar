// Copyright 2026 The Shaar Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import {assert} from 'chai';

import * as BuildInfo from './build-info.js';

describe('BuildInfoPanel', () => {
  it('lists the pinned DevTools frontend revision', () => {
    assert.strictEqual(BuildInfo.BuildInfoPanel.OVERLAY_ID, 'shaar-devtools-frontend');
    assert.strictEqual(BuildInfo.BuildInfoPanel.CHROMIUM_VERSION, '157.0.8103.51');
    assert.strictEqual(
        BuildInfo.BuildInfoPanel.DEVTOOLS_FRONTEND_REVISION,
        '12ada949de6a27116dea47c600da5322f44c64f4');
  });
});
