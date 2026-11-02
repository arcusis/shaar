// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import { fileURLToPath } from "node:url";
import { checkLinks } from "./links";

const result = checkLinks(fileURLToPath(new URL("../dist", import.meta.url)));
for (const error of result.errors) console.error(error);
if (result.errors.length) process.exitCode = 1;
else
  console.log(
    `Checked internal links, fragments, image descriptions and CSS assets across ${result.pages} pages. ${result.external.length} external destinations have valid HTTPS URLs; remote availability is checked separately.`,
  );
