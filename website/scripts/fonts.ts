// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Clash Display and Satoshi are Fontshare fonts under the ITF Free Font License, which allows
// self-hosting on our own site but not redistributing the files, so they are not committed to
// this public repository. The build downloads them into a git-ignored cache and serves them
// from the site's own origin.

import { existsSync } from "node:fs";
import { mkdir, readFile, rm, writeFile } from "node:fs/promises";
import { resolve } from "node:path";

// One request per family: the combined endpoint omits some families.
const fontshareCSS = ["clash-display@1", "satoshi@1"].map(
  (family) => `https://api.fontshare.com/v2/css?f[]=${family}&display=swap`,
);
const fontRequestTimeoutMs = 15_000;

export function fetchFontAsset(url: string, timeoutMs = fontRequestTimeoutMs): Promise<Response> {
  return fetch(url, { signal: AbortSignal.timeout(timeoutMs) });
}

export interface SiteFont {
  family: string;
  file: string;
  weight: string;
}

const families: Record<string, string> = { "Clash Display": "clash-display", Satoshi: "satoshi" };

function isSiteFontManifest(value: unknown): value is SiteFont[] {
  if (!Array.isArray(value) || value.length !== Object.keys(families).length) return false;
  const validFaces = value.every(
    (face) =>
      face !== null &&
      typeof face === "object" &&
      face.family in families &&
      face.file === `${families[face.family]}.woff2` &&
      typeof face.weight === "string" &&
      /^\d{3} \d{3}$/.test(face.weight),
  );
  if (!validFaces) return false;
  const faces = value as SiteFont[];
  return (
    new Set(faces.map((face) => face.family)).size === faces.length &&
    Object.keys(families).every((family) => faces.some((face) => face.family === family))
  );
}

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

function isWoff2(data: Buffer): boolean {
  return (
    data.length >= 48 &&
    data.toString("ascii", 0, 4) === "wOF2" &&
    data.readUInt32BE(8) === data.length &&
    data.readUInt16BE(12) > 0 &&
    data.readUInt16BE(14) === 0 &&
    data.readUInt32BE(16) > 0 &&
    data.readUInt32BE(20) > 0 &&
    data.readUInt32BE(20) <= data.length - 48
  );
}

/** Copies cached or freshly downloaded font files into `outputDirectory`. Returns the faces it wrote. */
export async function prepareFonts(
  cacheDirectory: string,
  outputDirectory: string,
): Promise<SiteFont[]> {
  const manifestPath = resolve(cacheDirectory, "fonts.json");
  let faces: SiteFont[] = [];
  if (existsSync(manifestPath)) {
    try {
      const manifest: unknown = JSON.parse(await readFile(manifestPath, "utf8"));
      if (!isSiteFontManifest(manifest))
        throw new Error("Cached font manifest has an invalid shape");
      faces = manifest;
    } catch (error) {
      console.warn(
        `Cached fonts unavailable, the site falls back to system fonts: ${String(error)}`,
      );
      await rm(manifestPath, { force: true }).catch(() => undefined);
      await rm(manifestPath, { force: true });
      return [];
    }
  } else {
    try {
      let css = "";
      for (const url of fontshareCSS) {
        const response = await fetchFontAsset(url);
        if (!response.ok) throw new Error(`Fontshare CSS returned ${response.status}`);
        css += await response.text();
      }
      const parsed = parseFaces(css);
      if (parsed.length === 0) throw new Error("Fontshare CSS had no supported WOFF2 faces");
      const parsedFamilies = new Set(parsed.map((face) => face.family));
      if (Object.keys(families).some((family) => !parsedFamilies.has(family)))
        throw new Error("Fontshare CSS did not include all site font families");
      await mkdir(cacheDirectory, { recursive: true });
      for (const face of parsed) {
        const font = await fetchFontAsset(face.url);
        if (!font.ok) throw new Error(`Font download returned ${font.status} for ${face.family}`);
        const data = Buffer.from(await font.arrayBuffer());
        if (!isWoff2(data)) throw new Error(`Font download was not WOFF2 for ${face.family}`);
        await writeFile(resolve(cacheDirectory, face.file), data);
      }
      faces = parsed.map(({ family, file, weight }) => ({ family, file, weight }));
      await writeFile(manifestPath, JSON.stringify(faces, null, 2));
    } catch (error) {
      console.warn(`Fonts unavailable, the site falls back to system fonts: ${String(error)}`);
      return [];
    }
  }
  try {
    await mkdir(outputDirectory, { recursive: true });
    for (const face of faces) {
      const data = await readFile(resolve(cacheDirectory, face.file));
      if (!isWoff2(data)) throw new Error(`Cached font is not WOFF2 for ${face.family}`);
      await writeFile(resolve(outputDirectory, face.file), data);
    }
  } catch (error) {
    console.warn(`Cached fonts unavailable, the site falls back to system fonts: ${String(error)}`);
    await rm(manifestPath, { force: true });
    return [];
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
