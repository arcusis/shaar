# Native vault session boundary

Native Bitwarden SDK experiments use a pinned, unsupported internal SDK in isolated fixtures. The browser does not bundle this SDK. Results below describe component boundaries, not a supported vendor integration.

The native proof path covers password authentication and MFA against an owned loopback mock, user-crypto initialization, synthetic cipher encryption/decryption, scoped Keychain credential storage, fetched-cipher synchronization, and lock/unlock/disconnect lifecycle. Authentication publication is bound to Profile, vault, account, and authority; stale or disabled attempts must not publish credentials. Credential records are versioned and bounded, use an app-owned Keychain service, and disable iCloud synchronization.

Sync proof fetched and decrypted a synthetic cipher through SDK HTTP/token interfaces and registered handlers. It preserved the prior client-scoped snapshot for unauthorized and malformed responses. This is not full-vault or organization sync, and does not establish real-service compatibility, TLS deployment behavior, or atomic rollback of all SDK state.

SDK key clearing does not establish erasure of caller-owned plaintext, token logout, Keychain record deletion, or complete product lock. Successful authentication alone is not an installed product session. Provider UI, integrated session management, origin-bound form fill/save/update, release signing, and vendor acceptance require separate evidence.

The internal Bitwarden SDK describes third-party use as unsupported and its interface as unstable. Preserve its notices and review distribution terms before shipping. See [[Native_Password_Manager_Options]], [[Bitwarden_Compatibility]], and [[Profile_Space_Isolation]].
