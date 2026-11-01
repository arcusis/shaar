// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import React from 'react';
import { createRoot } from 'react-dom/client';
import { ReactCounter } from './ReactCounter.jsx';
import { mountVue } from './vue.js';
import InspectorCounter from './InspectorCounter.svelte';

const accessorProbe = {};
Object.defineProperty(accessorProbe, 'danger', { enumerable: true, get() { globalThis.inspectorGetterCalls = (globalThis.inspectorGetterCalls || 0) + 1; return 'unexpected'; } });
accessorProbe.self = accessorProbe;
createRoot(document.querySelector('#react-root')).render(React.createElement(ReactCounter, { label: 'React counter', accessorProbe }));
mountVue();
globalThis.mountInspectorSvelte = () => {
  if (!globalThis.inspectorSvelte) {
    globalThis.inspectorSvelte = new InspectorCounter({ target: document.querySelector('#svelte-root') });
  }
};
