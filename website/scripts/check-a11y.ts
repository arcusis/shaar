// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { createRequire } from "node:module";

const page = process.argv[2];
if (!page || !/^[a-f0-9-]{36}$/.test(page)) {
  throw new Error("Pass the browserPageId of your own local Orca tab: pnpm check:a11y <page-id>");
}

function evaluate(expression: string): string {
  const output = execFileSync(
    "orca",
    ["eval", "--page", page, "--expression", expression, "--json"],
    { encoding: "utf8", maxBuffer: 2 * 1024 * 1024 },
  );
  const result = JSON.parse(output);
  if (!result.ok) throw new Error(result.error?.message ?? output);
  return result.result.result;
}

const origin = evaluate("location.origin");
if (!/^http:\/\/(localhost|127\.0\.0\.1):\d+$/.test(origin))
  throw new Error("Accessibility checks require your local preview tab.");

// Chunked DevTools evaluation avoids OS argument limits. Nothing is added to the shipped assets.
const require = createRequire(import.meta.url);
const axe = readFileSync(require.resolve("axe-core/axe.min.js"), "utf8");
evaluate("globalThis.__shaarAxeSource = ''; 'ready'");
for (let offset = 0; offset < axe.length; offset += 50000) {
  evaluate(
    `globalThis.__shaarAxeSource += ${JSON.stringify(axe.slice(offset, offset + 50000))}; 'loaded chunk'`,
  );
}
evaluate("(0, eval)(globalThis.__shaarAxeSource); delete globalThis.__shaarAxeSource; 'axe ready'");
const report = JSON.parse(
  evaluate(`axe.run(document, {runOnly: {type: 'tag', values: ['wcag2a', 'wcag2aa', 'wcag21aa']}}).then(result => JSON.stringify({
  url: location.href, passes: result.passes.length,
  violations: result.violations.map(violation => ({id: violation.id, impact: violation.impact, nodes: violation.nodes.map(node => ({target: node.target, summary: node.failureSummary}))})),
  incomplete: result.incomplete.map(check => check.id)
}))`),
);
console.log(JSON.stringify(report, null, 2));
if (report.violations.length) process.exitCode = 1;
