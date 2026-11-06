// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

(async (source, scope) => {
  const hadAxe = Object.prototype.hasOwnProperty.call(globalThis, 'axe');
  const previousAxe = Object.getOwnPropertyDescriptor(globalThis, 'axe');
  try {
    window.eval(source);
    const axe = globalThis.axe;
    if (!axe || axe.version !== '4.14.0') throw new Error('The pinned axe-core runtime is unavailable.');
    const context = scope === 'selected'
      ? globalThis.__shaarInspectorV2?.element()
      : document;
    if (!context) throw new Error('Lock an element before auditing this selection.');
    const result = await axe.run(context);
    const findings = [];
    let findingIndex = 0;
    for (const violation of result.violations) {
      for (const node of violation.nodes) {
        const target = Array.isArray(node.target)
          ? node.target.find(value => typeof value === 'string')
          : null;
        findings.push({
          id: String(violation.id).slice(0, 128) + ':' + findingIndex++,
          ruleId: String(violation.id).slice(0, 128),
          impact: String(violation.impact || 'unknown').slice(0, 32),
          title: String(violation.help || violation.id).slice(0, 256),
          help: String(violation.help || '').slice(0, 512),
          helpUrl: String(violation.helpUrl || '').slice(0, 2048),
          target: String(target || '').slice(0, 2048),
          summary: String(node.failureSummary || '').slice(0, 2048),
        });
        if (findings.length >= 300) break;
      }
      if (findings.length >= 300) break;
    }
    return {
      scope,
      violations: result.violations.length,
      incomplete: result.incomplete.length,
      findings,
      truncated: result.violations.reduce((count, row) => count + row.nodes.length, 0) > findings.length,
    };
  } finally {
    if (hadAxe && previousAxe) Object.defineProperty(globalThis, 'axe', previousAxe);
    else Reflect.deleteProperty(globalThis, 'axe');
  }
})
