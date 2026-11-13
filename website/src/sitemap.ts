// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import { type SitePage, siteOrigin } from "./content";

export function sitemapXML(pages: SitePage[]): string {
  const paths = [
    "/",
    ...pages.filter((page) => page.path !== "/404.html").map((page) => page.path),
  ];
  return `<?xml version="1.0" encoding="UTF-8"?><urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">${paths.map((path) => `<url><loc>${siteOrigin}${path}</loc></url>`).join("")}</urlset>`;
}
