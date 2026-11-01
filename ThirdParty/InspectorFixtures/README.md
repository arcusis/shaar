# Inspector framework fixture

Test-only development runtimes for React, Vue and Svelte, bundled with the authored source in `Tests/InspectorContractTests/fixtures`. They are served only by the disposable loopback verification fixture and are not included in Shaar's app bundle.

`pin.json` records exact package versions and bundle hashes. Package integrity is pinned in `Tests/InspectorContractTests/pnpm-lock.yaml`. Rebuild with `pnpm --dir Tests/InspectorContractTests exec node build-fixtures.cjs` after installing its dependencies. The fixture server rejects a mismatched JavaScript bundle hash.

React/React DOM (including Scheduler), Vue and Svelte retain their MIT licenses, copied alongside the bundle. `frameworks.js.LEGAL.txt` retains extracted upstream notices. The fixture application's own source uses MPL-2.0. esbuild is a test build tool under MIT, not shipped app code.

Sources: https://github.com/facebook/react, https://github.com/vuejs/core, https://github.com/sveltejs/svelte, https://github.com/evanw/esbuild.
