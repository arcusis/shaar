// Copyright 2026 The Shaar Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// Shared registration. One import per feature directory, and the matching
// "<feature>:meta" dep in BUILD.gn in this directory. Do not add another
// import to devtools_app.ts.
import './build-info/build-info-meta.js';
import './network-rules/network-rules-meta.js';
import './overflow/overflow-meta.js';
import './focus-contrast/focus-contrast-meta.js';
import './stacking-3d/stacking-3d-meta.js';
import './stacking/stacking-meta.js';
import './copy-for-agent/copy-for-agent-meta.js';
import './graphql-trpc/graphql-trpc-meta.js';
import './viewports/viewports-meta.js';
import './hydration-diff/hydration-diff-meta.js';
