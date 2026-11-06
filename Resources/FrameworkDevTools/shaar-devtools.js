// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

function isLocalDevelopmentURL(value) {
  try {
    const url = new URL(value);
    return (url.protocol === "http:" || url.protocol === "https:") &&
      (url.hostname === "localhost" || url.hostname === "127.0.0.1");
  } catch {
    return false;
  }
}

let started = false;

function startFrameworkDevTools() {
  if (started) return;
  chrome.devtools.inspectedWindow.eval("window.location.href", (value, error) => {
    if (started || error || !isLocalDevelopmentURL(value)) return;
    started = true;
    const script = document.createElement("script");
    script.src = "__UPSTREAM_SCRIPT__";
    document.head.appendChild(script);
  });
}

startFrameworkDevTools();
chrome.devtools.network.onNavigated.addListener(startFrameworkDevTools);
