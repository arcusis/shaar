// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import React from 'react';
export function ReactCounter({ label = 'React counter' }) {
  const [count, setCount] = React.useState(2);
  return React.createElement('button', {
    id: 'react-counter', onClick: () => setCount(count + 1),
    __source: { fileName: '/inspector-source/ReactCounter.jsx', lineNumber: 8, columnNumber: 3 },
  }, `${label}: ${count}`);
}
ReactCounter.displayName = 'ReactCounter';
