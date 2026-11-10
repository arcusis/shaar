# Adding a Shaar DevTools panel

A Shaar DevTools panel is one directory of TypeScript and Lit:

`ThirdParty/ChromiumEngine/devtools-frontend/front_end/panels/shaar/<feature>/`

Copy `build-info/` (the proof panel, titled Shaar). The panel subclasses `UI.Panel.Panel`, calls `super(id, true)`, and renders with `html` / `render` from `ui/lit/lit.js` in `performUpdate`. UI strings use `i18n.i18n.registerUIStrings` and the path from `front_end`, for example `panels/shaar/<feature>/<feature>-meta.ts`.

Registration is one import in `front_end/panels/shaar/shaar-meta.ts`:

`import './<feature>/<feature>-meta.js';`

Add the matching `"<feature>:meta"` dep and the matching `"<feature>:unittests"` dep in `front_end/panels/shaar/BUILD.gn`, in the same order. That directory's `BUILD.gn` is the shared file beside the import. Do not add another import to `devtools_app.ts`. Patch `0062` already imports `shaar-meta.js`, depends on `../../panels/shaar:meta`, and lists `panels/shaar:unittests` once. Keep `"..:*"` on the feature meta visibility. The shared entrypoint typechecks through `meta_typescript_checked`, so `../:meta` alone is not visible.

`scripts/stage-shaar-devtools-frontend.py` hardlinks the `shaar` directory into `front_end/panels/shaar`. In a Chromium tree the destination is `third_party/devtools-frontend/src/front_end/panels/shaar`. `devtools_entrypoint` generates the GRD. `0014` stays on the Chromium 155 pin. Chromium 157 uses `0061-shaar-devtools-theme-157.patch` for the palette and the host-config hides. Panel CSS stays in the feature.

Directories: `build-info` (#1469), `viewports` (#1481), `network-rules` (#1482), `copy-for-agent` (#1483), `hydration-diff` (#1484), `graphql-trpc` (#1485), `stacking` (#1486), `overflow` (#1487), `focus-contrast` (#1488).

The shared standalone checkout on this machine is `/Users/david/shaar-engine/devtools-frontend`, pinned to `12ada949de6a27116dea47c600da5322f44c64f4`. Build and unit tests go through `shaar-heavy` with `depot_tools` on `PATH`, `DEPOT_TOOLS_UPDATE=0`, and `NINJA_CORE_LIMIT=4`: `npm run build`, then `npm test -- front_end/<suite>`. Do not set `DEPOT_TOOLS_BOOTSTRAP_PYTHON3=0`. That selects vpython's Python 3.8, and current `autoninja` needs Python 3.11. On this machine the gitignored `depot_tools/python3_bin_reldir.txt` points at uv's Python 3.13. `npm test` without a `front_end/` path also runs end-to-end tests. On that checkout the registration patch applies with `git apply -p4`. `0061` also edits Chromium browser files, so it stays on the Chromium tree. Upstream `SettingRegistration.test.ts` passed 8 tests. After staging, `front_end/panels/shaar/build-info/BuildInfoPanel.test.ts` passed 1 test.

[[Engine_Module_devtools]] is the older module plan. Retirement order is [[Shaar_DevTools_SwiftUI_Retirement]]. [[Shaar_Inspector]] stays.
