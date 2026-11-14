# Notebook maintenance

Every pull request updates the Notebook for its changes, including tooling, tests, CI and documentation. Keep one concept per note; update existing notes before creating duplicates. Each Markdown note must have a direct wiki link from at least one `_INDEX_*.md`. Related-note links supplement indexes and do not replace them. Renames and removals must update links. The contribution rule lives in [CONTRIBUTING](../CONTRIBUTING.md).

Run `.venv/bin/python scripts/check-notebook-links.py` from any working directory; its default vault is this repository's `Notebook/`. The standalone standard-library script accepts `--notebook <path>` for fixture checks. It rejects a symlinked root or entries beneath it, checks all Markdown notes recursively, excludes indexes from orphan checks, and fails with each orphan or broken index target, or when no index exists. Index wiki links accept aliases, headings, `.md` extensions and an optional `Notebook/` prefix, which resolves from the vault root. Targets are case-sensitive. Comments, inline code, escaped wiki markup and fenced examples do not count as navigation links. `Tests/NotebookTests/test_notebook_links.py` covers positive and negative CLI behavior and is discovered by `scripts/test-python.py`.

The Source checks workflow runs the script after Python setup, before the Swift build. It is a single step so the staged CI work in [issue #334](https://github.com/arcusis/shaar/issues/334) can move it into its fast gates. This check proves index membership and index-target existence, not prose accuracy, broken links outside index wiki links or whether every feature has a note.

Reconcile claims against source and current PR state. Open-PR designs must carry a pending status and source link; reported fixture results are not new local verification. Historical measurements must keep their revision and scope.

Related: [[Project_State]], [[Source_And_Native_Verification]].
