# Shaar DevTools frontend overlay

Shaar-owned DevTools panels live here and compile into the Chromium DevTools
frontend. New panels are TypeScript and Lit, the same UI framework the upstream
panels use. The engine build copies this overlay into the frontend tree, then
applies a small registration patch. The frontend's `devtools_entrypoint` target
generates the GRD, so there is no hand-written resource list.

Brave keeps overlay files outside the frontend tree and patches
`typescript.gni` so `tsc` can see them. Shaar copies the files into
`third_party/devtools-frontend/src/front_end/panels/shaar` before `gn`, which
keeps the registration patch to the app entrypoint and its `BUILD.gn`.

## Chromium 157.0.8103.51

`devtools_frontend_revision` is `12ada949de6a27116dea47c600da5322f44c64f4`.

Leave `patches/0014-shaar-devtools-theme.patch` on the Chromium 155 pin. On
this checkout apply the retargeted theme patch instead. From the Chromium
`src` directory, after sync:

```
python3 /path/to/shaar/scripts/stage-shaar-devtools-frontend.py \
  --destination third_party/devtools-frontend/src/front_end/panels/shaar
git apply /path/to/shaar/ThirdParty/ChromiumEngine/patches/0061-shaar-devtools-theme-157.patch
git apply /path/to/shaar/ThirdParty/ChromiumEngine/patches/0062-shaar-devtools-frontend-registration.patch
```

`0061` is the 155 theme (Shaar palette, hide What's New / feedback / the MCP
menu, turn on APCA) rewritten against this frontend. `0062` imports the Shaar
panel. The proof panel is titled Shaar and lists the overlay id, the Chromium
version, and the frontend revision.

Feature agents add further panels by following
`Notebook/Shaar_DevTools_Frontend_Panel.md`.
