// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Clash Display and Satoshi are Fontshare fonts under the ITF Free Font License, which allows
// self-hosting on our own site but not redistributing the files, so they are not committed to
// this public repository. The build downloads them into a git-ignored cache and serves them
// from the site's own origin.

import { existsSync } from "node:fs";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { resolve } from "node:path";

// One request per family: the combined endpoint omits some families.
const fontshareCSS = ["clash-display@1", "satoshi@1"].map(
  (family) => `https://api.fontshare.com/v2/css?f[]=${family}&display=swap`,
);

export interface SiteFont {
  family: string;
  file: string;
  weight: string;
}

const families: Record<string, string> = { "Clash Display": "clash-display", Satoshi: "satoshi" };

function parseFaces(css: string): (SiteFont & { url: string })[] {
  const faces: (SiteFont & { url: string })[] = [];
  for (const block of css.split("@font-face").slice(1)) {
    const family = /font-family:\s*'([^']+)'/.exec(block)?.[1];
    const url = /url\('([^']+\.woff2)'\)/.exec(block)?.[1];
    const weight = /font-weight:\s*([^;]+);/.exec(block)?.[1]?.trim();
    const style = /font-style:\s*([^;]+);/.exec(block)?.[1]?.trim();
    if (!family || !url || !weight || style !== "normal" || !families[family]) continue;
    // The API lists the variable face (a weight range) next to static weights; keep the variable one.
    if (!weight.includes(" ")) continue;
    faces.push({
      family,
      weight,
      url: url.startsWith("//") ? `https:${url}` : url,
      file: `${families[family]}.woff2`,
    });
  }
  return faces;
}

/** Copies cached or freshly downloaded font files into `outputDirectory`. Returns the faces it wrote. */
export async function prepareFonts(
  cacheDirectory: string,
  outputDirectory: string,
): Promise<SiteFont[]> {
  const manifestPath = resolve(cacheDirectory, "fonts.json");
  let faces: SiteFont[] = [];
  if (existsSync(manifestPath)) {
    faces = JSON.parse(await readFile(manifestPath, "utf8")) as SiteFont[];
  } else {
    try {
      let css = "";
      for (const url of fontshareCSS) {
        const response = await fetch(url);
        if (!response.ok) throw new Error(`Fontshare CSS returned ${response.status}`);
        css += await response.text();
      }
      const parsed = parseFaces(css);
      await mkdir(cacheDirectory, { recursive: true });
      for (const face of parsed) {
        const font = await fetch(face.url);
        if (!font.ok) throw new Error(`Font download returned ${font.status} for ${face.family}`);
        await writeFile(resolve(cacheDirectory, face.file), Buffer.from(await font.arrayBuffer()));
      }
      faces = parsed.map(({ family, file, weight }) => ({ family, file, weight }));
      await writeFile(manifestPath, JSON.stringify(faces, null, 2));
    } catch (error) {
      console.warn(`Fonts unavailable, the site falls back to system fonts: ${String(error)}`);
      return [];
    }
  }
  await mkdir(outputDirectory, { recursive: true });
  for (const face of faces) {
    await writeFile(
      resolve(outputDirectory, face.file),
      await readFile(resolve(cacheDirectory, face.file)),
    );
  }
  return faces;
}

export function fontFaceCSS(faces: SiteFont[]): string {
  return faces
    .map(
      (face) =>
        `@font-face{font-family:"${face.family}";src:url("/assets/fonts/${face.file}") format("woff2");font-weight:${face.weight};font-style:normal;font-display:swap}`,
    )
    .join("\n");
}
