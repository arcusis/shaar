// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import { existsSync, readdirSync, readFileSync, statSync } from "node:fs";
import { relative, resolve, sep } from "node:path";
import { parseHTML } from "linkedom";
import { siteOrigin } from "../src/content";

export function listFiles(root: string): string[] {
  return readdirSync(root, { withFileTypes: true }).flatMap((entry) => {
    const path = resolve(root, entry.name);
    return entry.isDirectory() ? listFiles(path) : [path];
  });
}

export function localTarget(root: string, url: URL): string | undefined {
  const path = resolve(root, `.${decodeURIComponent(url.pathname)}`);
  if (path !== root && !path.startsWith(`${root}${sep}`)) return undefined;
  const options = url.pathname.endsWith("/")
    ? [resolve(path, "index.html")]
    : [path, `${path}.html`, resolve(path, "index.html")];
  return options.find((option) => existsSync(option) && statSync(option).isFile());
}

function cssImportURLs(css: string): string[] {
  const urls: string[] = [];
  let position = 0;
  while (position < css.length) {
    if (css.startsWith("/*", position)) {
      const end = css.indexOf("*/", position + 2);
      position = end === -1 ? css.length : end + 2;
      continue;
    }
    if (css[position] === "'" || css[position] === '"') {
      const quote = css[position++];
      while (position < css.length && css[position] !== quote) {
        if (css[position] === "\\") position++;
        position++;
      }
      position++;
      continue;
    }
    if (css.slice(position, position + 7).toLowerCase() === "@import") {
      let argument = position + 7;
      while (/\s/.test(css[argument] ?? "")) argument++;
      const quote = css[argument];
      if (quote === "'" || quote === '"') {
        const start = ++argument;
        while (argument < css.length && css[argument] !== quote) {
          if (css[argument] === "\\") argument++;
          argument++;
        }
        urls.push(css.slice(start, argument));
        position = argument + 1;
        continue;
      }
    }
    position++;
  }
  return urls;
}

export function checkLinks(root: string): { errors: string[]; external: string[]; pages: number } {
  const errors: string[] = [];
  const external = new Set<string>();
  const htmlFiles = listFiles(root).filter((path) => path.endsWith(".html"));
  for (const file of htmlFiles) {
    const path = relative(root, file);
    const document = parseHTML(readFileSync(file, "utf8")).document;
    const ids = new Set<string>();
    for (const element of document.querySelectorAll("[id]")) {
      if (ids.has(element.id)) errors.push(`${path}: duplicate id ${element.id}`);
      ids.add(element.id);
    }
    if (document.querySelectorAll("h1").length !== 1) errors.push(`${path}: expected one h1`);
    for (const element of document.querySelectorAll(
      'a[href], area[href], link[href], img[src], input[type="image"][src], script[src], img[srcset], source[srcset], video[poster], video[src], audio[src], source[src], meta[property="og:image"], meta[name="twitter:image"]',
    )) {
      const references = [
        ...(element.hasAttribute("srcset")
          ? [
              ...(element.localName === "img" && element.hasAttribute("src")
                ? [element.getAttribute("src") ?? ""]
                : []),
              ...(element.getAttribute("srcset") ?? "")
                .split(",")
                .map((candidate) => candidate.trim().split(/\s+/, 1)[0]),
            ]
          : [
              element.getAttribute("href") ??
                element.getAttribute("src") ??
                element.getAttribute("content") ??
                "",
            ]),
        ...(element.hasAttribute("poster") ? [element.getAttribute("poster") ?? ""] : []),
      ];
      for (const value of references) {
        if (!value || value.startsWith("javascript:")) {
          errors.push(`${path}: empty or unsafe link`);
          continue;
        }
        let url: URL;
        try {
          url = new URL(value, `${siteOrigin}/${path}`);
        } catch {
          errors.push(`${path}: invalid URL ${value}`);
          continue;
        }
        if (url.protocol !== "https:") {
          errors.push(`${path}: unsupported protocol ${value}`);
          continue;
        }
        if (url.origin !== siteOrigin) {
          external.add(url.href);
          continue;
        }
        const target = localTarget(root, url);
        if (!target) {
          errors.push(`${path}: missing target ${value}`);
          continue;
        }
        if (url.hash && target.endsWith(".html")) {
          const targetDocument =
            target === file ? document : parseHTML(readFileSync(target, "utf8")).document;
          if (!targetDocument.getElementById(decodeURIComponent(url.hash.slice(1))))
            errors.push(`${path}: missing fragment ${value}`);
        }
      }
    }
    for (const image of document.querySelectorAll("img")) {
      const alt = image.getAttribute("alt");
      if (alt === null || (alt.trim() === "" && alt !== ""))
        errors.push(`${path}: image missing or whitespace-only alt`);
    }
    const imageMapNames = new Set(
      [...document.querySelectorAll("map[name]")]
        .map((map) => map.getAttribute("name"))
        .filter((name): name is string => Boolean(name)),
    );
    for (const image of document.querySelectorAll("img[usemap]")) {
      const usemap = image.getAttribute("usemap") ?? "";
      let associated = false;
      if (usemap.startsWith("#")) {
        try {
          associated = imageMapNames.has(decodeURIComponent(usemap.slice(1)));
        } catch {
          // A malformed fragment cannot identify a map.
        }
      }
      if (!associated) errors.push(`${path}: image references missing map ${usemap}`);
    }
    for (const area of document.querySelectorAll("area[href]")) {
      if (!area.getAttribute("alt")?.trim()) errors.push(`${path}: image map area missing alt`);
    }
    for (const image of document.querySelectorAll('input[type="image"]')) {
      if (!image.getAttribute("alt")?.trim())
        errors.push(`${path}: image submit control missing alt`);
    }
  }
  for (const file of listFiles(root).filter((path) => path.endsWith(".css"))) {
    const css = readFileSync(file, "utf8");
    for (const match of css.matchAll(/url\(["']?([^"')]+)["']?\)/g)) {
      const url = new URL(match[1], siteOrigin);
      if (url.origin !== siteOrigin || !localTarget(root, url))
        errors.push(`${relative(root, file)}: missing/nonlocal CSS asset ${match[1]}`);
    }
    for (const value of cssImportURLs(css)) {
      const url = new URL(value, siteOrigin);
      if (url.origin !== siteOrigin || !localTarget(root, url))
        errors.push(`${relative(root, file)}: missing/nonlocal CSS asset ${value}`);
    }
  }
  return { errors, external: [...external].sort(), pages: htmlFiles.length };
}
