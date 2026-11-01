// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Shared hero geometry in 1600 x 900 scene units, used by the SVG fallback (landscape.ts)
// and the canvas painter (scene.ts) so both draw the same hills.

export const SCENE_WIDTH = 1600;
export const SCENE_HEIGHT = 900;

export interface Hill {
  path: string;
  top: string;
  bottom: string;
  depth: number; // parallax strength, 0 = fixed
}

export const hills: Hill[] = [
  {
    path: "M-80 520C120 430 260 380 420 420S640 520 760 500s180-70 300-60 220 90 360 70 180-40 300-30V900H-80Z",
    top: "#a9cf8c",
    bottom: "#7fb26d",
    depth: 6,
  },
  {
    path: "M700 610c120-10 220-60 330-130s220-120 340-120 190 30 310 60V900H700Z",
    top: "#3f8a5a",
    bottom: "#1f5f43",
    depth: 10,
  },
  {
    path: "M-80 610c180-40 400-90 600-60s360 110 560 100 330-60 600-40V900H-80Z",
    top: "#cfe08a",
    bottom: "#93bf5a",
    depth: 16,
  },
  {
    path: "M-80 690c220-30 520-40 800-20s560 50 960 10V900H-80Z",
    top: "#86b04a",
    bottom: "#3f7429",
    depth: 24,
  },
];

export const roadPath =
  "M1010 900c-70-60-170-90-150-130s150-50 160-80-60-40-40-62c40 20 82 42 70 74s-150 50-130 88 140 60 210 110Z";

/** Height of the meadow's top edge at scene x, matching the last hill's curve closely enough for grass. */
export function meadowTop(x: number): number {
  const t = Math.max(0, Math.min(1, (x + 80) / 1760));
  return 690 - 30 * Math.sin(t * Math.PI) * 0.9 + 10 * Math.sin(t * Math.PI * 2);
}
