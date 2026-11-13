// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import { demoSpaces } from "../src/components/demo";
import { screens } from "../src/content";

export function websiteScreenAssets(): string[] {
  const storyFiles = [
    screens.spaces.file,
    screens.profiles.file,
    screens.launcher.file,
    screens.siteControls.file,
    screens.extensions.file,
  ];
  const demoFiles = demoSpaces.flatMap((space) =>
    space.tabs.flatMap((tab) => [`fav-${tab.page}.png`, `page-${tab.page}.webp`]),
  );
  return [...new Set([...storyFiles, ...demoFiles])];
}
