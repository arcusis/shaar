// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import { createApp, h } from 'vue';
export function mountVue() {
  return createApp({
    name: 'VueCounter', __file: '/inspector-source/vue.js',
    props: { label: { default: 'Vue counter' } },
    data: () => ({ count: 3 }),
    render() {
      return h('button', { id: 'vue-counter', onClick: () => this.count++ }, `${this.label}: ${this.count}`);
    },
  }).mount('#vue-root');
}
