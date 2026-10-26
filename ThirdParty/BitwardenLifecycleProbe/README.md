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

Parent review accepted this composed fixture proof: pin has `accepted: true` and
`integration_ready: false`. Default invocation reads the accepted source pin
without `--candidate`. After promotion, `--candidate` fails closed because that
mode requires an unaccepted pin.

Example on arm64 macOS 27:

```sh
python3 scripts/test-native-bitwarden-lifecycle.py \
  --source /path/to/pristine/sdk-internal \
  --output /private/tmp/native-bitwarden-lifecycle-proof
```

Fresh mode-0700 private work under owned output contains SDK clone, fixture
values, requests, tokens, encrypted values, executable, and bindings. Raw
request/output data never enters logs or receipts. Runner removes private work
on exit while retaining nonsecret build artifacts and mode-0600 private receipts
under owned output. Receipt records source/patch/lock/artifact digests, counted Rust tests,
stage booleans, cleanup observations, and actual BrowserCore source digests.
SDK and Swift deployment target is macOS 26; runtime host macOS 27 remains
separate. This accepted fixture proof does not establish integration readiness,
TLS/service, organization/full-vault, vendor/browser form-fill, native UI,
product, or distribution acceptance. No cryptographic zeroization, task
cancellation, or product availability is claimed.
