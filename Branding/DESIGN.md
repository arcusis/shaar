# Shaar brand

## Name

**Shaar** (Hebrew שער, "gateway"). A browser is a gateway to the internet. Arcusis is the company that makes it.

- Write it as **Shaar** in English UI and copy. Use **שער** for Hebrew.
- The company appears only as the copyright holder: "© 2026 Arcusis. All rights reserved."
- In code, the name comes from `ProductIdentity.name` (`Sources/BrowserCore/ProductIdentity.swift`). Never type the name directly into UI strings.

## Logo

A circle of swept green ribbons that opens into a doorway, with a path winding out of it: the world, the gateway, and the way through.

| File | Use |
|---|---|
| `shaar-logo.svg` | Master logo. Transparent background; the doorway and path are see-through. |
| `shaar-logo-source.png` | Original 1254 px artwork the master was drawn from. Reference only. |
| `shaar-app-icon.svg` | macOS app icon master: the logo on the full rounded tile. |
| `shaar-app-icon-1024.png` | 1024 px render of the app icon, generated. |

`Resources/Branding/Shaar.icns` is generated from `shaar-app-icon.svg` by `bash scripts/generate-app-icon.sh`. Edit the SVG, never the ICNS.

### How the master was made

The first SVG export was an automatic trace: about 6,300 tiles and 5,000 gradients in 2 MB. It showed hairline seams and stair-stepped edges, so it was not kept. The master is a redraw from the source PNG with nine smooth Bézier ribbons. Each ribbon has its own linear or radial gradient, and all of them sit inside one clipping silhouette. It is about 18 KB and stays sharp at any size.

### Usage

- Keep clear space of at least 10% of the logo diameter on every side.
- Minimum size: 16 px. Below 32 px, prefer the app icon, whose tile keeps the doorway readable.
- On light backgrounds the doorway and path show the background. That is intended; do not fill them in.
- Do not recolor, outline, rotate, stretch, or add effects to the logo.

## App icon

- 1024 × 1024 canvas, following the macOS icon grid: an 824 pt rounded tile inset 100 pt, corner radius 185.
- Tile: vertical gradient `#16382B` → `#071A12`, with a faint white rim at the top.
- The logo fills 70% of the canvas, centered. The dark tile shows through the doorway, so the gateway reads as an opening.

## Color

Sampled from the logo's gradients.

| Role | Hex |
|---|---|
| Deep teal (shadow) | `#013C3C` |
| Forest | `#026748` |
| Emerald | `#45BC52` |
| Leaf | `#71E122` |
| Mint | `#83F0B4` |
| Lime | `#C8F736` |
| Sunlight | `#F6FB2A` |
| Tile dark | `#071A12` |

Shaar uses the system accent color for interactive UI. The brand greens are for the logo, the icon, and marketing surfaces.
