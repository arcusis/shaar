# Bitwarden native auth compatibility spike

Experimental source patch against pinned Bitwarden SDK source. No production browser dependency or app integration.

Run only after coordinator accepts patch SHA and `pin.json` marks that exact patch accepted. Runner requires an existing pristine SDK checkout and a new, unused output path:

```sh
.venv/bin/python scripts/test-native-bitwarden-auth.py \
  --source /path/to/pristine/sdk-internal \
  --output /path/to/new/NativeBitwardenAuthProof
```

Runner verifies source commit, tracked cleanliness, patch SHA and preinstalled Rust target; clones source locally without hardlinks; applies patch in clone; runs full offline, locked `bitwarden-auth` tests; builds `bitwarden-uniffi`; and generates Swift bindings with SDK's `uniffi-bindgen`. It uses existing Rust `1.90-aarch64-apple-darwin` toolchain and macOS 26.0 deployment flags. It never downloads SDK source or installs toolchains. Output contains isolated clone, Cargo target, generated Swift, and redacted `receipt.json`; input checkout and pre-existing output paths stay untouched.

Receipt records source, patch and artifact hashes, exact commands and exit codes, test counts, host version, and deployment target. Command output stays suppressed; no request password, token, or raw assertion body is recorded. Synthetic mock HTTP tests do not prove actual Swift auth invocation, server interoperability, vault session installation, account, vault, sync, cloud, vendor, or production acceptance. SDK license/terms and distribution rights remain unresolved; this experiment makes no legal or distribution claim. Existing SDK license metadata stays unchanged. `LICENSE_GPL.txt` is a separate notice for the experimental patch and does not change browser licensing.

The source patch is accepted for this isolated experiment at the hash in `pin.json`. This is not approval to bundle the SDK or distribute a production integration.
