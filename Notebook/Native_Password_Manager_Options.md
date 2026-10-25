# Optional native password managers

Target experience: native Settings enables/disables password-manager integration for the selected browser Profile. Bitwarden is first provider; additional managers need their own verified integration. Browser startup and ordinary browsing must work while integration is off. Native UI, vendor vault transport and Chromium form handling are separate responsibilities.

Website account isolation does not require a different Bitwarden account for every Space. A user may deliberately use the same password vault across multiple browser Profiles; their website cookies and storage still remain separate. Do not silently change vault/account binding when switching a Space or merge website sessions when enabling a provider.

Bitwarden distinguishes its [public Secrets Manager SDK](https://contributing.bitwarden.com/getting-started/sdk/) from its [internal Password Manager SDK](https://github.com/bitwarden/sdk-internal/blob/main/README.md). The latter explicitly says third-party use is unsupported and its interface unstable. Swift bindings exist for Bitwarden's internal clients; their existence does not establish a supported drop-in browser integration. Internal SDK builds also distinguish OSS and commercially licensed components.

A concrete native precedent is [Bitwarden's DuckDuckGo macOS partnership](https://bitwarden.com/help/duckduckgo-macos-browser-integration/): users select Bitwarden in browser settings, connect an installed/unlocked Bitwarden desktop app and approve pairing. This supports autofill and save/update. The documentation establishes DuckDuckGo support, not an unrestricted custom-browser pairing contract. Our browser's trust/transport compatibility remains unverified. Do not imitate another browser's identity to obtain access.

A vault SDK does not itself supply Chromium form discovery, frame/origin checks, password suggestions, fill or save/update UX. The [official extension](https://bitwarden.com/help/auto-fill-browser/) already implements those flows. Its verified login/lock/restart results remain useful compatibility evidence, but extension transport is under review against the requested native experience.

Apple's [Credential Provider APIs](https://developer.apple.com/documentation/authenticationservices/ascredentialproviderviewcontroller) describe a system-mediated provider extension. They do not establish that arbitrary embedded Chromium page fields invoke a compatible provider. A target-engine spike is required before promising generic manager support.

Recommendation: build the native profile/settings model first, then validate a supported desktop/provider route for Bitwarden. Keep the vendor behind a small provider boundary. Extension fallback is a decision option; internal SDK embedding remains unapproved pending support/licensing and technical feasibility. Do not build a general plugin framework or promise all managers before proving the first provider.

Tracking: [native provider feasibility #52](https://github.com/arcusis/browser/issues/52), [Settings #51](https://github.com/arcusis/browser/issues/51), [full password workflow acceptance #9](https://github.com/arcusis/browser/issues/9).

Related: [[Arc_Settings_Design]], [[Bitwarden_Compatibility]], [[Engine_Interop_Boundary]], [[Profile_Space_Isolation]].
