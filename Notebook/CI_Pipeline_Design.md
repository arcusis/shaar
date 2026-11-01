# Staged CI pipeline design

Issue: [#334](https://github.com/arcusis/shaar/issues/334). This design precedes implementation. Related local hooks are a separate change for [#335](https://github.com/arcusis/shaar/issues/335).

## Baseline and invariants

The implementation baseline is production commit `3c1745e`, refreshed after #332, #327 and #338 merged. `source-checks.yml` currently has five independent jobs: source checks (including the private-window fixture), hosted sidebar visuals, engine probes (including Quit exit and session recovery), release-bundle checks, and workflow lint. The release workflow validates assets built by `scripts/release.sh` on a developer machine and deploys only their appcast to Pages. The only published version is `v0.1.0`.

Production integration now uses `3840c1f`, including prerequisite [#363](https://github.com/arcusis/shaar/pull/363) for #310 and the merged DevTools, media, launcher, indicator and tooltip work. Keep their source and probes intact. Private-window and Quit modes retain #363's minimum of three independent repetitions in every full pipeline; baseline/recovery follow the requested count. Nightly requests three for every mode. Manual counts remain 1–10, with the private/Quit minimum clearly reported. Every repetition remains fatal on failure; no retry is restored. See [[Private_Fixture_Readiness]] for the prerequisite evidence.

Keep every existing check, every hosted visual filter, the distinct shipping and verification scratch directories, the shipping verification-code guard, and deep signature verification. Preserve #332's merged `bash scripts/test-engine.sh --quit-exit` step and its failure-evidence conditions, the merged #327 site-controls flow, and further engine work in #333 when rebasing on production. Do not change the engine fixture's ownership or privacy assertions to obtain green CI.

Notebook-link enforcement merged in [PR #338](https://github.com/arcusis/shaar/pull/338), production commit `3c1745e`, for #336. Its standalone stdlib checker runs with the configured Python, and its six CLI tests under `Tests/NotebookTests` are discovered by `scripts/test-python.py`. The fast stage calls the existing checker with `sys.executable`, which is the configured `.venv/bin/python`; no duplicate checker or extra dependency is introduced. The workflow conflict during rebasing was resolved by moving the incoming check into that fast stage while retaining merged Quit and site-control flows.

All external actions use full commit SHAs. Local composite actions and reusable workflows use relative paths, selecting the caller's commit. Checkouts do not persist credentials. Default token permission is `contents: read`; grant additional permissions only to specific security/reporting or trusted attestation jobs. PR code never receives signing material or a write-capable publication token.

Local verification remains headless/offscreen. Hosted-only visual captures and native fixtures remain on GitHub-hosted macOS 26. Before any heavy local build, check Orca's one-minute load and proceed only below 12; use two build jobs. No local release, updater, visible-window, or focus-changing launch is part of implementation verification.

## Pipeline graph

1. **Fast gates:** Swift formatting; license headers; notebook links (#336); actionlint; shellcheck; Gitleaks with redaction; external-action SHA and SwiftPM resolution checks; fast Python tests. Shared commands must be callable by CI and the later hooks. Do not silently skip a missing tool or expected checker. Run these before expensive work.
2. **Build and unit tests:** explicit Swift build followed by tests on macOS 26. Export Swift test results as JUnit and collect Python results in the same format. Enable coverage and compare the candidate against a baseline built from the immutable PR base or merge-group base using the same toolchain. A missing or malformed report fails the comparison. Keep source, bridge, app and verification coverage visible separately so an aggregate cannot conceal a parser regression.

   Preserve native Swift Testing XML and convert serial XCTest console events into their own JUnit report. macOS SwiftPM can emit only the Swift Testing XML despite `--xunit-output`. Check XCTest start/end pairs and outer-suite totals, retain failures/skips, and reject truncated or inconsistent logs. Do not change test execution or spawn a process per XCTest case merely to generate reports.
3. **Engine simulations:** build the verification bundle once, then run the existing baseline initial/restart flow, private-window flow, Quit exit flow and interrupted-save recovery. Add dedicated entry points from concurrent PRs without replacing them with weaker generic tests. Each run gets its own evidence namespace. Run independent modes even when another mode fails and aggregate their status afterward.
4. **Shipping bundle:** after successful simulations, build without verification code, verify signatures, validate the pinned payload and produce an inventory/SBOM for the actual bundle. Shipping and testing objects never share a product cache.
5. **Final gate:** an always-running, stable `CI required` check reads every prerequisite result. Failed, cancelled, unexpectedly skipped or missing required stages fail this check. A documented, positively classified documentation-only change may skip expensive stages; fast gates and this final gate still run. Unknown paths, missing comparison refs, workflow changes and scripts always select the full pipeline.

Use reusable workflows for stages/jobs and composite actions for repeated setup/cache/report steps. Keep orchestration and `needs` in the caller. Reusable workflows do not share the caller's workflow-level environment automatically, so pass declared inputs explicitly. Do not reuse the caller's concurrency key inside a callee.

## Triggers, concurrency and rules

Run on PRs targeting production and the existing `feat/native-*` targets, production/native pushes, `merge_group: checks_requested`, manual dispatch, and nightly schedule. Merge-group runs test the synthetic merge SHA, not the source branch head. Include event/ref identity in concurrency groups; cancel superseded PR runs only, never an unrelated merge group or release run.

Production currently inherits PR/signature/no-force-push rules but has no required status checks or merge queue. Prepare exact required check names and a repository ruleset definition alongside the pipeline. Activate only after the workflows exist on production and their real emitted check names have been verified; enabling a required new check before its workflow lands would block all merges. The task does not authorize merging these PRs. Record this activation dependency explicitly rather than claiming the queue is enabled by adding its event alone.

## Caches, reports and evidence

Separate Swift dependency caches, debug test products, verification products, shipping products, sanitizer products and engine archives. Keys include runner OS/architecture, Xcode/Swift identity, lockfile/manifest hashes and build mode. Product caches also include source identity; source changes must never reuse stale coverage or skip compilation. Engine archives use their pin/digest independently of source changes and remain validated on extraction. Treat cache data as untrusted input; never cache credentials or user profiles.

Each stage writes a short job summary containing commit/toolchain identity, commands, durations, test totals, coverage and evidence links. Upload JUnit, logs and authored fixture reports with `always()` or failure conditions even when commands fail. Include run/attempt/mode in artifact names, bound retention, and collect only owned synthetic probe roots. Never upload arbitrary profiles or the entire runner temporary directory. An artifact digest warning is not a substitute for explicit validation where artifacts cross trust boundaries.

Remove the current private-window retry. Nightly soak repeats all configured probes with new disposable roots, records every iteration, and fails when any iteration fails. Repetition measures flakiness; it never turns an earlier failure into success. Keep the first failure's logs and reports.

[Run 41309513025](https://github.com/arcusis/shaar/actions/runs/41309513025) supplies a concrete regression case for evidence retention: the first private-window attempt failed initial rendering with `Owned private renderer screenshot missing or invalid; CDP outcome: private-owner-rejected.` and restart with `Private window fixture failed required checks: productWeakStoreReleasedAfterConfirmedClose.` Its retry passed 642 checks in each phase. #336 changed no fixture code. The new pipeline must fail that overall run while preserving both attempts if a diagnostic repetition is requested. Soak reporting must distinguish these renderer-ownership and store-release failures; changing their assertions or excluding the checks would weaken existing coverage.

## Additional coverage

- Seeded randomized/property checks exercise clean-link parsing, session decoding, preference decoding and release-feed parsing. Assert semantic invariants and round trips, bound generated sizes, and print reproducible seeds on failure. Keep fixed regressions alongside generated cases.
- Upgrade fixtures are authored, version-labelled session/preference files representing prior schemas. The current decoders must load them and preserve stable identifiers, selection and settings. These are compatibility tests, not proof that an old installed release upgraded successfully.
- Address and Thread Sanitizer jobs use separate scratch paths, run meaningful tests and fail on findings. Nightly runs the full suite and repeated engine probes. Unsupported sanitizer/toolchain combinations must be reported, not silently accepted.
- Dead-code analysis starts as a report with explicit exclusions for public API, Objective-C selectors, SwiftUI/runtime entry points and verification targets. Turning its existing findings into a blocking gate requires an agreed baseline; do not delete code solely because a static scanner cannot see its runtime use.
- Map tabs, Spaces, profiles, private windows, downloads, extensions, media, picture-in-picture and crash recovery to the existing full fixture. Preserve the separate merged Quit exit flow; retain #327 site-controls coverage in the full fixture. Report absent scenarios as absent rather than inventing success.

## Security and supply chain

CodeQL analyzes Swift with an explicit fresh traced build on macOS; Python and Actions analysis can run without a compiled build. Dependency review runs on PR diffs and uses explicit base/head refs for merge-group events. Check every external `uses` value (including composite actions), require committed SwiftPM pins, and verify resolution does not rewrite the lockfile.

Run OpenSSF Scorecard in its own restricted workflow on production and schedule, with read-only default permissions and its required reporting permissions scoped to the analysis job. It provides an assessment, not permission to change repository security settings. Gitleaks supplies the requested secret scan. No GitHub secret scanning or push-protection feature is part of this design.

Generate an SBOM from resolved dependencies, the pinned engine and the bundled files; identify its scope and include artifact digests. Use SHA-pinned `actions/attest-build-provenance` only in the trusted workflow that actually builds the named artifact. A workflow downloading a developer-built ZIP cannot truthfully attest that it built that ZIP.

## Approved delivery decisions

1. Keep local Developer ID signing, notarization and Sparkle signing. CI attests unsigned candidates only. Signing credentials are outside this work. An ad-hoc bundle signature remains useful for integrity verification but is not a Developer ID distribution signature.
2. Deliver infrastructure as its own PR, then the real Sparkle update simulation as the next PR, then #335 hooks. The simulation needs an isolated updater driver, fixture feed/key, disposable app/data roots and completion evidence. A download/signature check or direct file replacement must not be labelled a Sparkle update.

These decisions were explicitly approved before implementation. Keep #334 open while its staged requirements remain incomplete. Repository rule activation still requires the new workflows to reach production; this task never merges PRs. This note records design intent; the implementation note distinguishes delivered coverage from follow-up work.

## Official references reviewed

- [Reusable workflows](https://docs.github.com/en/actions/how-tos/reuse-automations/reuse-workflows) and [composite actions](https://docs.github.com/en/actions/tutorials/creating-a-composite-action).
- [Merge-group events](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows#merge_group), [merge queue configuration](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/configuring-pull-request-merges/managing-a-merge-queue) and [concurrency](https://docs.github.com/en/actions/how-tos/write-workflows/choose-when-workflows-run/control-workflow-concurrency).
- [Caching](https://docs.github.com/en/actions/reference/workflows-and-actions/dependency-caching), [artifacts](https://docs.github.com/en/actions/tutorials/store-and-share-data) and [job summaries](https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-commands#adding-a-job-summary).
- [Build provenance action](https://github.com/actions/attest-build-provenance), [artifact attestations](https://docs.github.com/en/actions/how-tos/secure-your-work/use-artifact-attestations/use-artifact-attestations), [CodeQL configuration](https://docs.github.com/en/code-security/reference/code-scanning/workflow-configuration-options), [compiled-language tracing](https://docs.github.com/en/code-security/how-tos/find-and-fix-code-vulnerabilities/manage-your-configuration/codeql-for-compiled-languages), [dependency review](https://github.com/actions/dependency-review-action) and [OpenSSF Scorecard](https://github.com/ossf/scorecard-action).

Related: [[_INDEX_Verification]], [[Verification_Harness]], [[Source_And_Native_Verification]], [[Test_Coverage]], [[Releasing]].
