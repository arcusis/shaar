# Optional native password managers

Password-manager integration is optional and Profile-scoped. Browser startup and ordinary browsing must work when integration is disabled. Provider UI, credential transport, vault state, and Chromium form handling are separate components; expose only workflows backed by an implemented and verified provider.

Website cookies and storage remain isolated by browser Profile. A vault may intentionally be shared across Profiles, but changing Spaces must not silently change vault identity or merge website sessions. Password-manager access is unavailable in private windows until a separate isolated lifecycle is implemented.

Bitwarden is the initial integration target. Its public Secrets Manager SDK and internal Password Manager SDK are distinct projects. The internal SDK documents third-party use as unsupported and its interface as unstable; preserve upstream notices and review applicable license terms before distribution. See [SDK documentation](https://contributing.bitwarden.com/getting-started/sdk/) and [internal SDK source](https://github.com/bitwarden/sdk-internal).

Keychain credentials should be bound to Profile, vault, account, and canonical HTTPS authority. Use a fixed app-owned generic-password service, exact account matching, bounded versioned records, and disable iCloud synchronization when credentials are intended to remain local. Authentication publication must reject stale attempts after Profile, vault, account, or enabled-state changes.

A native SDK experiment has covered authentication, crypto initialization, scoped token persistence, one fetched-cipher sync path, lock/unlock, and disconnect against owned loopback fixtures. These component results do not establish integrated product sessions, full-vault or organization sync, vendor service compatibility, TLS behavior, or Chromium autofill/save/update workflows. See [[Native_Vault_Session_Boundary]] and [[Bitwarden_Compatibility]].

Apple [Credential Provider APIs](https://developer.apple.com/documentation/authenticationservices/ascredentialproviderviewcontroller) do not establish compatibility with embedded Chromium fields. Bitwarden's [DuckDuckGo integration](https://bitwarden.com/help/duckduckgo-macos-browser-integration/) documents that product pairing only; it does not establish support for Shaar.

Related: [[Arc_Settings_Design]], [[Profile_Space_Isolation]], [[Engine_Interop_Boundary]].
