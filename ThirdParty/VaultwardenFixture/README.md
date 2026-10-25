# Disposable vault fixture

Vaultwarden is an optional development-test server for synthetic Bitwarden accounts. It is not embedded in the browser application or deployed as a company service. Its source and binary remain in ignored `build/VaultFixture/`.

`pin.json` identifies release 1.37.4, its source commit, archive SHA-256 and required Rust toolchain. Upstream source is [AGPL-3.0-only](https://github.com/dani-garcia/vaultwarden/blob/7c188967e7a467b19b2757bc3326f9cf3ccae327/LICENSE.txt). The builder verifies the archive and source files, uses the upstream lockfile, and records the resulting binary digest. SQLite and OpenSSL are built from the pinned dependency graph.

With the named Rust toolchain installed, build using the project Python environment:

```sh
.venv/bin/python scripts/build_vault_fixture.py
```

The builder never starts the server. A fixture run must use a marked disposable data directory and loopback binding. Passing this server's workflows cannot establish Bitwarden Cloud, company SSO, native messaging, passkeys or Touch ID acceptance. Tracking: [issue #9](https://github.com/arcusis/browser/issues/9).
