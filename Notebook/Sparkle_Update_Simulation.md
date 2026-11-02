# Sparkle update simulation

Design for the second #334 PR, following [[CI_Pipeline]]. This design precedes implementation. Developer ID signing, notarization, release publishing and production Sparkle credentials remain under the approved local process.

## Installation proof

The hosted shipping stage first validates its unsigned candidate, including the existing verification-code guard, deep signature check, SBOM and SHA256 manifest. The simulator verifies that exact archive before deriving fixture copies. The previous published release, initially `v0.1.0`, has a committed URL, size and SHA256 pin, checked before extraction.

Compile Sparkle's official CLI from the exact SwiftPM checkout and link the matching framework. Give its background-only driver bundle and target unique fixture identifiers. Install the old release into an owned temporary directory without launching it. Use `--check-immediately`, an IPv4 loopback feed and an explicit user agent; never interactive authorization or deferred installation. The old and new browser executables are never launched.

Only disposable bundle copies receive fixture identifiers, a fixture public key and increasing fixture build numbers, followed by ad-hoc sealing. An ephemeral Ed25519 seed is mode 0600 and supplied explicitly to `sign_update --ed-key-file`; no Keychain default is used. Record original candidate and derived archive digests separately. The original candidate remains the attestation subject.

Run three independent cases once each: valid update, wrong-key signature and corruption after signing. Success requires Sparkle's actual installation-completion callback, zero updater status, expected installed version, complete payload/symlink fingerprint, changed main executable and unchanged seeded data. Negative cases must reach the archive, report signature rejection, fail installation and preserve the old payload and data. Download-only checks and manual replacement cannot satisfy installation proof.

The server exposes only authored feed/archive paths on loopback. No HTML release notes or external URLs appear in the feed. Native execution refuses non-hosted macOS environments. Print every owned child PID before any exact-PID cleanup. Account for SDK helpers before stopping a timed-out driver: Sparkle can show installer progress if its updater disappears mid-install. Disposable payloads and private keys stay outside artifact roots and are removed. Upload only authored JSON/logs, never fixture keys or complete profiles.

## Data and parser proof

Authored, version-labelled session/preferences fixtures represent the published schema and earlier supported versions. Current production decoders must preserve stable identifiers, selection, URLs and settings while applying migration defaults. The updater preserves the same fixture bytes outside the bundle. This combines real installer preservation with decoder compatibility; it does not claim browser startup or signed/notarized distribution acceptance.

Bounded randomized tests use reproducible seeds for clean links, sessions, preferences and release-feed parsing. Cover round trips, migrations, invalid-input rejection, preservation of malformed originals and non-tracking URL content. Report seed and case index on failure. Synthetic inputs require no network or visible windows.

## Integration and verification

Simulation failure fails shipping and `CI required`; production attestation follows the complete shipping job. Preserve every existing engine probe, private/Quit repetition, hosted visual and release guard. Focused Python tests cover preparation and assertions; hosted macOS proves actual installation. Locally verify build, focused Swift/Python tests and shared fast gates with native CI flags absent. Record final hosted head and each installer result before declaring success.

Sources: [Sparkle CLI](https://sparkle-project.org/documentation/sparkle-cli/), [publishing updates](https://sparkle-project.org/documentation/publishing/), and the exact pinned checkout's CLI/signing sources. Related: [[CI_Pipeline_Design]], [[Releasing]], [[Test_Coverage]].

## Implementation and proof boundary

`scripts/ci-sparkle.py` calls the hosted-only `sparkle_fixture.py` runner after successful shipping checks. It verifies both candidate/SBOM manifest entries, the previous-release pin, the CLI checkout revision and the bundled framework version. ZIP paths and symlinks are checked before extraction. Each case receives fresh bundle identifiers, key files and data, and cleans its owned SDK helpers and payload before the next case. The existing candidate remains unchanged and retains its original checksum. Results and updater logs join shipping evidence; fixture payloads/keys stay in disposable runner storage.

The pinned SDK wraps pre-extraction signature failures in `SUInstallationError` (4005); rejection checks require both an allowed SDK error code and signature-validation text. An unrelated installation/network failure cannot pass a negative case.

Six authored JSON fixtures cover session schemas 1–4 and preference schemas 1–2. Schema 4 and preferences 2 match the published release's document shape; these are synthetic fixtures, not captured user profiles. The same files feed current Swift decoder tests and the real updater's preservation checks. Shared `BrowserTestSupport` supplies fixture paths and deterministic seeds without adding app behavior. Three seeds exercise 384 clean links, 192 sessions, 96 preference documents and 192 release feeds, with seed/case context on failures.

Local test-target build passed in 63.83 seconds with two jobs. Focused Swift tests passed all five parameterized tests (15 seed/schema cases); all schema/data assertions passed with hosted UI flags absent. All eight fast gates passed, including 200 Python tests, nine focused fixture checks and the archive-symlink regression. Native updater execution remains hosted-only and is not established by those local results.
