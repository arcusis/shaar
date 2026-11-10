# Shaar DevTools frontend overlay

Shaar-owned DevTools panels live here and compile into the Chromium DevTools
frontend. Each feature is TypeScript and Lit, in its own directory:

`front_end/panels/shaar/<feature>/`

The shared registration file is `front_end/panels/shaar/shaar-meta.ts`. A
feature adds one import line there, and the matching `"<feature>:meta"` dep in
`front_end/panels/shaar/BUILD.gn`. The Chromium registration patch imports that
one shared file. Do not add another import to `devtools_app.ts`.

`scripts/stage-shaar-devtools-frontend.py` hardlinks this directory to
`front_end/panels/shaar` before `gn`. In a Chromium tree that destination is
`third_party/devtools-frontend/src/front_end/panels/shaar`. The frontend's
`devtools_entrypoint` target generates the GRD.

The shared checkout for unit tests on this machine is
`/Users/david/shaar-engine/devtools-frontend`, pinned to
`12ada949de6a27116dea47c600da5322f44c64f4`. Build and test it through
`shaar-heavy`. Its `front_end/` directory is the standalone layout, so the
registration patch applies there with `git apply -p4`.

## Add a feature

1. Copy `build-info/` to `front_end/panels/shaar/<feature>/`.
2. Add one line to `shaar-meta.ts`: `import './<feature>/<feature>-meta.js';`
3. Add `"<feature>:meta"` to the `ts_deps` list in `BUILD.gn` beside that file.

Reserved directories:

| Directory | Issue |
| --- | --- |
| `build-info` | #1469 proof panel |
| `viewports` | #1481 |
| `network-rules` | #1482 |
| `copy-for-agent` | #1483 |
| `hydration-diff` | #1484 |
| `graphql-trpc` | #1485 |
| `stacking` | #1486 |
| `overflow` | #1487 |
| `focus-contrast` | #1488 |

## Chromium 157.0.8103.51

`devtools_frontend_revision` is `12ada949de6a27116dea47c600da5322f44c64f4`.

Leave `patches/0014-shaar-devtools-theme.patch` on the Chromium 155 pin. On a
Chromium `src` checkout, after sync:

```
python3 /path/to/shaar/scripts/stage-shaar-devtools-frontend.py \
  --destination third_party/devtools-frontend/src/front_end/panels/shaar
git apply /path/to/shaar/ThirdParty/ChromiumEngine/patches/0061-shaar-devtools-theme-157.patch
git apply /path/to/shaar/ThirdParty/ChromiumEngine/patches/0062-shaar-devtools-frontend-registration.patch
```

On the standalone checkout, stage into `front_end/panels/shaar` and apply the
registration patch with `-p4`. `0061` also touches Chromium browser files, so
it stays on the Chromium tree.

`0061` is the 155 theme rewritten against this frontend. `0062` imports
`shaar-meta.js` once. The proof panel is `build-info`, titled Shaar, and lists
the overlay id, the Chromium version, and the frontend revision.

Feature agents follow `Notebook/Shaar_DevTools_Frontend_Panel.md`.
