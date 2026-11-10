# Third-party notices

Shaar's app bundle includes a SHA-256-pinned Shaar Chromium engine distribution
and Public Suffix List data. License and component credits for the exact bundled
Chromium framework remain available at `chrome://credits`.

## Chromium and bundled dependencies

- **Component:** Chromium 155.0.8059.84 in Chromium Framework.
- **Source:** [Shaar engine pin](ThirdParty/ChromiumEngine/pin.json).
- **License:** Chromium uses BSD-style terms and includes components under
  additional licenses. Preserve the framework's component credits with any
  redistributed build.

## Public Suffix List

- **Component:** `effective_tld_names.dat`, included as a BrowserCore resource.
- **Source:** Chromium source repository, commit and source path recorded in
  [Public Suffix pin](ThirdParty/PublicSuffix/pin.json).
- **License:** MPL-2.0.
- **License text:** [ThirdParty/PublicSuffix/LICENSE](ThirdParty/PublicSuffix/LICENSE).

## Built-in framework DevTools

Shaar bundles the official Chrome Web Store CRX packages for local development pages. Those CRX bytes are not stored in git. [scripts/fetch-framework-devtools.py](scripts/fetch-framework-devtools.py) downloads each pinned archive, checks its SHA-256, and stages it. The app keeps the original code and assets, removes the upstream update URL, narrows host and content-script matches to loopback, and adds a Shaar DevTools bootstrap.

- **React Developer Tools 8.0.0:** [React source](https://github.com/facebook/react/tree/1d34f91dfde6bba84d08b683aaba164c7194dacb/packages/react-devtools-extensions), MIT; [license text](ThirdParty/FrameworkDevTools/licenses/react-LICENSE).
- **Vue.js DevTools 7.7.7:** [Vue DevTools source](https://github.com/vuejs/devtools/tree/v7.7.7), MIT; [license text](ThirdParty/FrameworkDevTools/licenses/vue-LICENSE). Vue DevTools v7 supports Vue 3.
- **Angular DevTools 1.22.1:** [Angular DevTools source](https://github.com/angular/angular/tree/5ac4cf7b546df2d26c7fe33ac70934c2f26ede84/devtools), MIT; [license text](ThirdParty/FrameworkDevTools/licenses/angular-LICENSE). The bundled Material Symbols font retains its own license at `FrameworkDevTools/angular/third_party/fonts.google.com/material-symbols-outlined/LICENSE`.

## axe-core

- **Component:** axe-core 4.14.0, bundled for on-demand Inspector audits.
- **Source:** [dequelabs/axe-core v4.14.0](https://github.com/dequelabs/axe-core/releases/tag/v4.14.0); package integrity and the bundled file hash are recorded in [the pin](ThirdParty/axe-core/pin.json).
- **License:** MPL-2.0.
- **License text:** [ThirdParty/axe-core/LICENSE](ThirdParty/axe-core/LICENSE).
- **Third-party notices:** [ThirdParty/axe-core/LICENSE-3RD-PARTY.txt](ThirdParty/axe-core/LICENSE-3RD-PARTY.txt).
- **Use:** injected into the inspected page only for the duration of a user-started audit; its `window.axe` global is restored or removed afterward.
