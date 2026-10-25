# Bitwarden native session proof

This isolated proof composes pinned Swift password login with the SDK's typed user-crypto initializer, then encrypts and decrypts one synthetic cipher. It proves local login-to-key and cipher behavior only; it does not fetch a vault or establish product integration.

Run on arm64 macOS 26+ with accepted SDK proof artifacts and pristine pinned source already present:

```sh
python3 scripts/test-native-bitwarden-session.py \
  --proof-root /private/tmp/native-bitwarden-auth-proof-850c53c \
  --source ~/orca/workspaces/browser/<accepted-sdk-source> \
  --output /private/tmp/native-bitwarden-session-proof
```

The runner validates pin, patch, source cleanliness, artifact hashes, generated bindings, support source, and deployment target before building. It reads public SDK test-account vectors from pristine source, chooses an ephemeral new password, prepares `passwordHash` and wrapped user key through SDK crypto, and passes all credential and crypto values through captured process output or stdin. The loopback mock binds only to `127.0.0.1`; child output and request bodies never enter terminal output or receipts. Temporary build files are removed on exit. Receipt contains stage booleans and source/artifact hashes only.

`integration_ready=false` is intentional. No app dependency, UI, fetched-vault behavior, or distribution claim follows from this proof.
