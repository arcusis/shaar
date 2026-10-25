# Native crypto-key clear proof

GPL-guarded, isolated technical experiment against the pinned unsupported SDK. No app dependency, SDK-specific terms acceptance, Settings UI, product lock/logout, token deletion, persisted-state deletion, caller-plaintext erasure, or memory-zeroization claim.

Run on arm64 macOS with Rust `1.90-aarch64-apple-darwin`, target installed, offline Cargo cache, Swift 6, and a pristine pinned SDK checkout:

```sh
python3 scripts/test-native-bitwarden-key-clear.py \
  --source /path/to/pristine/sdk-internal \
  --output /private/tmp/new-key-clear-proof
```

Runner clones local source without hardlinks, applies accepted auth patch then candidate clear patch, validates the exact candidate source diff, runs focused offline Rust regression, builds the UniFFI dylib with two Cargo jobs, generates Swift bindings, checks macOS 26.0 minimum, and invokes a real Swift client. The pin is accepted for this scoped experiment after independent source/artifact review and native rerun. Default mode uses the accepted pin; `--candidate` is reserved for future unaccepted proposals. `integration_ready: false` remains explicit. Output path must not exist. Output and receipt are private; fixture material is removed after execution. No network fetch or dependency installation occurs.

The Swift proof initializes two synthetic clients from the pinned SDK's own coherent public test-account vector. It retains crypto and cipher clients, encrypts/decrypts a synthetic cipher, clears shared SDK keys through generated Swift, verifies retained key reads and decryption fail, verifies independent client remains usable, then initializes crypto again and decrypts successfully. Receipt stores source and artifact identities, scoped stage booleans, fixed errors and command exit results; secrets and raw command output stay out of receipt/logs.

The registered Swift state bridge supplies only initialization support; host-owned bridge and session lifecycle remain separate from this operation. This proves scoped in-memory SDK key-store clearing for this pinned experiment. It does not prove complete lock/logout, host token or persisted-state deletion, erasure of caller-owned plaintext copies, or key zeroization. SDK third-party support and distribution terms remain unresolved. Existing SDK license metadata and browser licensing stay unchanged.
