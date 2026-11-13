// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import { parseHTML } from "linkedom";
import { HomePage } from "../src/components/home";

export function websiteScreenAssets(): string[] {
  const document = parseHTML(HomePage()).document;
  const prefix = "/assets/screens/";
  return [
    ...new Set(
      [...document.querySelectorAll<HTMLImageElement>(`img[src^="${prefix}"]`)].map(
        (image) => image.getAttribute("src")?.slice(prefix.length) ?? "",
      ),
    ),
  ];
}
