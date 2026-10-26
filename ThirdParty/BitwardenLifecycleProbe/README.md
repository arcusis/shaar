# Native Bitwarden vault lifecycle probe

This candidate composes accepted password-auth, shared-key-clear, and sync
patches in one fresh checkout of the pinned SDK source. It runs offline and
locked with Rust 1.90, builds one UniFFI dylib, generates one matching Swift
binding set, then compiles the actual `PasswordAuthenticationGate` and
`PasswordCredentialStore` BrowserCore sources into the native probe.

The probe uses the pinned public SDK crypto vector, an owned loopback HTTP mock,
synthetic HTTPS authority identity for scoped Keychain records, and typed random
probe namespace. It tests actual login, initialized user crypto, gated token and
credential publication, SDK sync and cipher decryption, key and host bridge
clear on lock, retained handle rejection, explicit unlock, and disconnect.
The synthetic HTTPS identity scopes local storage only; TLS and authority
binding acceptance remain false.

Current pin remains `accepted: false` and `integration_ready: false` until parent
review. `--candidate` is required for current pin. With parent review promotion,
default run mode requires `accepted: true`; candidate flag then fails closed.

Example on arm64 macOS 27:

```sh
python3 scripts/test-native-bitwarden-lifecycle.py --candidate \
  --source /path/to/pristine/sdk-internal \
  --output /private/tmp/native-bitwarden-lifecycle-proof
```

SDK clone, fixture values, requests, tokens, encrypted values, executable, and
bindings stay under fresh mode-0700 private work. Raw request/output data never
enters logs or receipts. Work is removed on every exit. Receipt uses mode 0600
and records source/patch/lock/artifact digests, counted Rust tests, stage
booleans, cleanup observations, and actual BrowserCore source digests. SDK and
Swift deployment target is macOS 26; runtime host macOS 27 remains separate.
This candidate does not establish TLS/service, organization/full-vault,
vendor/browser form-fill, native UI, product, zeroization, or distribution
acceptance.
