# Shaar crash sweep, 2026-11-12

Scope: local `~/Library/Logs/DiagnosticReports`, recursively including `Retired`, for Nov 11–12, 2026 (New York), plus artifacts from the ten latest CI runs. The local set contains 28 `.ips` reports: 23 `ShaarVerification`, two `Shaar Helper`, and three `Chromium Helper`. There were no matching `.crash`, `.hang`, or `.spin` files.

| Faulting frame / signature | Count | First seen (local) | Last seen (local) | Engine | Disposition |
| --- | ---: | --- | --- | --- | --- |
| Helper `main+18,216` (provided helper dSYM maps this address best-effort to `FatalError+112`) | 5 | Nov 11 02:58:38 | Nov 11 03:31:47 | 157.0.8103.51 | Fixed by merged [PR #1601](https://github.com/arcusis/shaar/pull/1601): helper-relative framework path. The report UUID differs from the available dSYM. |
| Framework `shaar_extension_popup_view+995,008`, `ChromeMain` startup stack | 7 | Nov 11 02:14:43 | Nov 11 02:27:29 | 157.0.8103.51 | Hebrew restart fix, layer patch 0084; source only, engine build pending. |
| Framework `shaar_extension_popup_view+229,308`, `CrBrowserMain` | 2 | Nov 11 02:49:58 | Nov 11 02:57:17 | 157.0.8103.51 | Popup fix, layer patch 0083; source only, engine build pending. |
| Framework `shaar_extension_popup_view+70,729,368`, `ShaarBrowsingQA` | 1 | Nov 11 06:21:01 | Nov 11 06:21:01 | 155.0.8059.84 | Old `ci-test-pin` build, outside the 157 source target. No matching 155 dSYM was available; source fault is unclassified, not confirmed new against the current target. |
| Framework `shaar_extension_popup_view+263,756…264,472`, same `CrBrowserMain` stack family | 8 | Nov 11 08:11:03 | Nov 11 08:44:20 | 157.0.8103.51 | Popup fix, layer patch 0083; source only, engine build pending. Offsets vary across framework UUIDs. |
| Framework `shaar_extension_popup_view+1,032,976`, `ChromeMain` startup stack | 1 | Nov 11 19:25:30 | Nov 11 19:25:30 | 157.0.8103.51 | Hebrew restart fix, layer patch 0084; source only, engine build pending. |
| Framework `shaar_abi_minor+67,648` through `shaarSubmit` / `RefreshDownloads` | 1 | Nov 11 15:26:01 | Nov 11 15:26:01 | 157.0.8103.51 | RefreshDownloads guard, [PR #1619](https://github.com/arcusis/shaar/pull/1619). |
| Uncaught `NSJSONSerialization.dataWithJSONObject` in `ProfileDeletionProbe.seed` | 1 | Nov 12 04:38:09 | Nov 12 04:38:09 | 157.0.8103.51 | Verification-harness-only. The QA branch commit `00ce30f0` uses `JSONEncoder` for this cookie literal; tracked by open [PR #1620](https://github.com/arcusis/shaar/pull/1620). This probe is absent from production. |
| Framework `shaar_profile_delete+496` (`0xefef…` invalid read) | 1 | Nov 12 04:39:59 | Nov 12 04:39:59 | 157.0.8103.51 | Profile lifetime fix `bcab9c17`; source only, engine build pending. |
| Framework `shaar_profile_set_https_only+480` (`0xefef…` invalid read) | 1 | Nov 12 04:50:14 | Nov 12 04:50:14 | 157.0.8103.51 | Profile lifetime fix `bcab9c17`; source only, engine build pending. |

Symbol evidence: the provided 157 framework dSYM UUID is `4C4C44F8-5555-3144-A1CD-A71C79A656F5`; the 157 reports use other framework UUIDs (including `4C4C44B5`, `4C4C449E`, and `4C4C44F0`). The provided helper dSYM UUID `4C4C4483-5555-3144-A199-0A03DAC807E8` does not match the helper reports' `4C4C4462`. Therefore the `shaar_extension_popup_view` labels and engine offsets cannot be promoted to exact source lines. The app dSYM matched only the Nov 12 04:50 app UUID (`40613C38-1442-3665-8EA5-425F2AC9EA14`); other app builds had no local matching dSYM. No cluster is confirmed new at the current 157 source boundary. No speculative patch 0089 was added; the 155 report needs its exact symbols/source to identify a safe fix.

CI artifact check: downloaded and searched all artifacts for the ten latest runs: `43200586346`, `43199744386`, `43199744134`, `43195298179`, `43191912055`, `43191638437`, `43191287336`, `43191254219`, `43190848458`, and `43190751203`. No `.ips`, `.crash`, `.hang`, or `.spin` files, nor raw crash signatures, were present. Run `43199744386` contained the full engine-shard, shipping, unit, localization, and capture artifacts; its saved probe reports contain no crash/hang evidence.

No engine build or test was run. `/Users/david/shaar-engine` was read-only throughout.

Related: [[Verification_Harness]], [[Source_And_Native_Verification]], [[Engine_Module_profiles]].
Release tracking: [issue #1060](https://github.com/arcusis/shaar/issues/1060); this sweep does not resolve its outstanding security decisions.
