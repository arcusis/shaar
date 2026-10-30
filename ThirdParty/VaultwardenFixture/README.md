# Disposable vault fixture

Vaultwarden is an optional development-test server for synthetic Bitwarden accounts. It is not embedded in the browser application or deployed as a company service. Its source and binary remain in ignored `build/VaultFixture/`.

`pin.json` identifies release 1.37.4, its source commit, archive SHA-256 and required Rust toolchain. Upstream source is [AGPL-3.0-only](https://github.com/dani-garcia/vaultwarden/blob/7c188967e7a467b19b2757bc3326f9cf3ccae327/LICENSE.txt). The builder verifies the archive and source files, uses the upstream lockfile, and records the resulting binary digest. SQLite and OpenSSL are built from the pinned dependency graph.

With the named Rust toolchain installed, build using the project Python environment:

```sh
.venv/bin/python scripts/build_vault_fixture.py
```

The builder never starts the server. A fixture run must use a marked disposable data directory and loopback binding. Passing this server's workflows cannot establish Bitwarden Cloud, company SSO, native messaging, passkeys or Touch ID acceptance. Tracking: [issue #9](https://github.com/arcusis/shaar/issues/9).

## Synthetic account data

`scripts/vault_crypto.py` generates random accounts in the reserved `.invalid` namespace, wraps their random user keys, and prepares encrypted RSA keys and registration/login payloads. It performs no network requests or secret-file writes and has no command-line interface. Its account representation excludes generated material. Payloads and account attributes are sensitive test data and must not enter reports, command arguments, screenshots, or committed files.

The helper uses the legacy authenticated Bitwarden type-2 format for this fixture, with PBKDF2-SHA256, separate HKDF-expand encryption/MAC keys, AES-256-CBC/PKCS7 and HMAC-SHA256 checked before decryption. It is not browser password-storage code, a general vault client, or a replacement for the vendor SDK. Unsupported ciphertext types are rejected. The browser application does not import it or its Python dependencies.

Install optional fixture dependencies into the existing project environment, then run its focused checks:

```sh
.venv/bin/python -m pip --isolated install --index-url https://pypi.org/simple --require-hashes --only-binary=:all: -r ThirdParty/VaultwardenFixture/requirements.txt
.venv/bin/python -m unittest discover -s Tests/VaultCryptoTests
```

Dependency versions and wheel digests are pinned. Public SDK password-hash, key-stretch and authenticated-encryption vectors are checked independently of fixture round trips. [sdk-reference.json](sdk-reference.json) records the exact [upstream source commit](https://github.com/bitwarden/sdk-internal/tree/5cf919837e83b71c2508bf99344ea57cf5f84e88/crates/bitwarden-crypto/src) and reference-file digests; no vendor SDK source is embedded in the application. These checks establish only the explicitly covered fixture format, not real-extension login, autofill or account isolation.

## Local HTTPS

The installed Bitwarden 2026.10.0 self-hosted environment form requires HTTPS in release builds. `scripts/vault_tls.py` creates short-lived, self-signed server certificate material for the loopback fixture. Its root must be a direct child of the canonical system temporary directory, have the `arcusis-engine-probe-` prefix and mode 0700, and contain the exact owner-only `.arcusis-probe` marker. Foreign owners, symlinks, linked/nonregular markers and existing TLS directories are rejected.

The certificate has only the IP subject alternative name `127.0.0.1`, server-auth usage, no CA authority and an expiry six hours after generation. Its key and certificate are created exclusively with mode 0600 inside a private directory. `FixtureTLS.client_context()` trusts that certificate only in the returned Python TLS context; no system trust-store or network configuration changes occur. The helper also returns the public SHA-256 SPKI fingerprint for a future process-scoped browser test configuration. Browser trust integration and actual extension login are still pending.

```sh
.venv/bin/python -m unittest discover -s Tests/VaultTLSTests
```

Tests exercise root/marker ownership and filesystem bounds, private key permissions, certificate identity and scope, key preservation, successful local HTTPS, and rejection when the client trusts an unrelated fixture certificate. Pinned Vaultwarden already includes Rocket TLS support; its fixture process can consume the generated paths through `ROCKET_TLS` while retaining an explicit loopback listener.
