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
    for (const element of document.querySelectorAll("a[href], link[href], img[src], script[src]")) {
      const value = element.getAttribute("href") ?? element.getAttribute("src") ?? "";
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
    for (const image of document.querySelectorAll("img")) {
      if (!image.hasAttribute("alt")) errors.push(`${path}: image missing alt`);
    }
  }
  for (const file of listFiles(root).filter((path) => path.endsWith(".css"))) {
    for (const match of readFileSync(file, "utf8").matchAll(/url\(["']?([^"')]+)["']?\)/g)) {
      const url = new URL(match[1], siteOrigin);
      if (url.origin !== siteOrigin || !localTarget(root, url))
        errors.push(`${relative(root, file)}: missing/nonlocal CSS asset ${match[1]}`);
    }
  }
  return { errors, external: [...external].sort(), pages: htmlFiles.length };
}
