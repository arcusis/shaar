# Bitwarden native sync proof

Experimental GPL-guarded patch against pinned SDK source. Product integration remains disabled (`integration_ready=false`).

Scoped source/API experiment accepted after independent source, artifact and native proof. Runner uses the accepted pin by default; an unaccepted proposal requires explicit `--candidate`. Every run requires accepted auth proof artifacts, pristine pinned source, and fresh private output; cached builds are not reused. It applies auth then sync patch in a private copy, runs focused offline Rust tests, builds UniFFI and generated Swift, and runs actual Swift sync against owned loopback HTTP only. No external URL or server accepted.

The returned typed snapshot contains encrypted personal ciphers converted through SDK types. Swift decrypts fetched cipher with SDK crypto. Atomic snapshot only: publication is atomic for this client-scoped cipher snapshot; earlier SDK handlers may mutate their own stores or key state before a later handler fails. This one-item mock proof does not establish organization or full-vault behavior.

Receipts retain fixed stage labels and source, patch, bindings, dylib, probe, and executable hashes. Private fixture crypto values stay in memory or private cleaned work. Child/listener cleanup is bounded; raw SDK output, requests, secrets, token, and key material are never persisted or printed.

HTTP mock/source proof only. TLS, real vendor/server, organization and full-vault behavior, persistence/lock, autofill/save/update, browser integration, and distribution remain unproven. SDK interface remains unstable; license/terms and distribution decisions remain open. `LICENSE_GPL.txt` is notice for this experiment only and does not change app licensing.
