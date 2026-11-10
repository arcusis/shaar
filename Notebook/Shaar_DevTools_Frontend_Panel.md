# Adding a Shaar DevTools panel

A Shaar DevTools panel is TypeScript and Lit in the Chromium DevTools frontend. The overlay root is `ThirdParty/ChromiumEngine/devtools-frontend`. The proof panel is `src/front_end/panels/shaar/`: `ShaarPanel.ts`, `shaar.ts`, `shaar-meta.ts`, and `BUILD.gn`.

`scripts/stage-shaar-devtools-frontend.py` hardlinks that directory to `third_party/devtools-frontend/src/front_end/panels/shaar` before `gn`. `devtools_entrypoint` generates the GRD. The registration patch adds one side-effect import, `panels/shaar/shaar-meta.js`, to `devtools_app.ts`, and `../../panels/shaar:meta` to `devtools_app/BUILD.gn`.

Add another panel beside the proof panel like this:

1. Add a `UI.Panel.Panel` subclass under `panels/shaar`. Call `super(id, true)`, then `requestUpdate()`. Render with `html` and `render` from `ui/lit/lit.js` in `performUpdate`.
2. Register UI strings with `i18n.i18n.registerUIStrings` and the path from `front_end`, for example `panels/shaar/NamePanel.ts`.
3. Export the class from `shaar.ts` and list the file in the `devtools_ui_module` `sources`.
4. Call `UI.ViewManager.registerViewExtension` from `shaar-meta.ts` at import time. Location is `ViewLocationValues.PANEL`. Give it a stable id, title, command prompt, `ViewPersistence.CLOSEABLE`, and an order other than the proof panel's 200. `loadView` constructs the panel.

That meta file is already the imported entrypoint, so a new view needs no second import. A panel that should be its own frontend module, the way Sensors is, needs its own directory under `src/front_end/panels/`, a stage-script destination (the script currently accepts only a folder named `shaar` under `panels`), and a new import plus `:meta` dependency in the registration patch. Record that patch on `devtoolsFrontend157` in `source-build.json`. The Chromium 155 `patches` array stays the 155 apply set. `0014-shaar-devtools-theme.patch` stays on that pin. Chromium 157 uses `0061-shaar-devtools-theme-157.patch` for the palette and the host-config hides. Panel CSS belongs to the panel, not to that theme patch.

Check new 157 patch bytes with `git apply --check` on the checkout named on #290. An app change does not start the engine build.

[[Engine_Module_devtools]] is the older Ardia-era module plan. New panels follow this overlay. Retirement order is [[Shaar_DevTools_SwiftUI_Retirement]]. [[Shaar_Inspector]] stays.
