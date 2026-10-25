# Optional native password managers

Target experience: native Settings enables/disables password-manager integration for the selected browser Profile. Bitwarden is first provider; additional managers need their own verified integration. Browser startup and ordinary browsing must work while integration is off. Native UI, vendor vault transport and Chromium form handling are separate responsibilities.

Website account isolation does not require a different Bitwarden account for every Space. A user may deliberately use the same password vault across multiple browser Profiles; their website cookies and storage still remain separate. Do not silently change vault/account binding when switching a Space or merge website sessions when enabling a provider.

Bitwarden distinguishes its [public Secrets Manager SDK](https://contributing.bitwarden.com/getting-started/sdk/) from its [internal Password Manager SDK](https://github.com/bitwarden/sdk-internal/blob/5cf919837e83b71c2508bf99344ea57cf5f84e88/README.md). The latter says third-party use is unsupported and its interface unstable. This affects maintenance and support; it does not prove a native integration technically impossible.

Source inspection at `5cf919837e83b71c2508bf99344ea57cf5f84e88` found Swift UniFFI exports for password login, crypto initialization, cipher encryption/decryption and item operations, TOTP and FIDO2. The host supplies storage/state and interactive callbacks. The current wrapper does not export a complete vault-sync trigger or MFA response flow. Its checked-in [Swift package](https://github.com/bitwarden/sdk-internal/blob/5cf919837e83b71c2508bf99344ea57cf5f84e88/crates/bitwarden-uniffi/swift/Package.swift) declares iOS; macOS compile, linking and runtime behavior require separate proof.

The [UniFFI crate](https://github.com/bitwarden/sdk-internal/blob/5cf919837e83b71c2508bf99344ea57cf5f84e88/crates/bitwarden-uniffi/Cargo.toml) declares `GPL-3.0-only OR LicenseRef-Bitwarden-SDK`. These alternatives and component licenses need distribution review before shipping. The local proof uses the GPL option with the upstream non-commercial-component guard, preserves notices and changes no project license. It does not accept SDK-specific terms on the company's behalf.

A concrete native precedent is [Bitwarden's DuckDuckGo macOS partnership](https://bitwarden.com/help/duckduckgo-macos-browser-integration/): users select Bitwarden in browser settings, connect an installed/unlocked Bitwarden desktop app and approve pairing. This supports autofill and save/update. The documentation establishes DuckDuckGo support, not an unrestricted custom-browser pairing contract. Our browser's trust/transport compatibility remains unverified. Do not imitate another browser's identity to obtain access.

A vault SDK does not itself supply Chromium form discovery, frame/origin checks, password suggestions, fill or save/update UX. The [official extension](https://bitwarden.com/help/auto-fill-browser/) already implements those flows. Its verified login/lock/restart results remain useful compatibility evidence, but extension transport is under review against the requested native experience.

Apple's [Credential Provider APIs](https://developer.apple.com/documentation/authenticationservices/ascredentialproviderviewcontroller) describe a system-mediated provider extension. They do not establish that arbitrary embedded Chromium page fields invoke a compatible provider. A target-engine spike is required before promising generic manager support.

Next implementation step: prove the requested bundled native SDK route in isolation under [#73](https://github.com/arcusis/browser/issues/73): macOS arm64 Rust library, generated Swift import, public synthetic key vector and cipher round trip. No browser dependency, account login or real vault enters this experiment. A passing crypto proof still leaves authentication/MFA, sync, secure persistence, origin-bound form handling and provider Settings UX to implement. Keep Bitwarden behind a small provider boundary; additional managers require their own verified contracts. The desktop route remains an alternative if it meets the intended product experience.

Tracking: [native provider feasibility #52](https://github.com/arcusis/browser/issues/52), [Settings #51](https://github.com/arcusis/browser/issues/51), [full password workflow acceptance #9](https://github.com/arcusis/browser/issues/9).

Related: [[Arc_Settings_Design]], [[Bitwarden_Compatibility]], [[Engine_Interop_Boundary]], [[Profile_Space_Isolation]].
