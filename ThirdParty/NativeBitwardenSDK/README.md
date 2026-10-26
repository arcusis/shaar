# Local Bitwarden SDK package

Build on arm64 macOS 26 with `.venv/bin/python scripts/build-native-bitwarden-sdk.py`; pass `--source <pristine-sdk-checkout>` when source is outside `build/SDKCache/bitwarden-sdk-5cf9198`. Builder accepts only pinned pristine commit/tree/lock and exact accepted auth, key-clear, sync patches from `ThirdParty/BitwardenLifecycleProbe/pin.json`. Build runs offline with locked Cargo inputs and generates matching UniFFI Swift bindings. It writes an ignored Swift package at `build/NativeBitwardenSDK/Package`; a SwiftPM client can depend on that local path and import `ArcusisBitwardenSDK`.

Package manifest and ignored receipt record source Git tree, patch, lock, binding, support, license, dylib, package, architecture and deployment hashes. A retained tiny consumer and relocated app-style executable/library support independent import and runtime reproduction. SDK checkout stays read-only; only owned staged dylib gets local install-name and ad-hoc signature changes.

Reproduce SwiftPM import with `swift build --package-path build/NativeBitwardenSDK/repro/consumer --product sdk-consumer -Xlinker -headerpad_max_install_names`; run relocated consumer with `env -i PATH="$PATH" HOME="$HOME" build/NativeBitwardenSDK/repro/sdk-consumer`.

This package exposes unsupported Bitwarden Password Manager internals. Existing fixture result remains `accepted=true`, `integration_ready=false`. Package smoke proves typed local SDK use only; it does not establish vendor support, auth/TLS compatibility, full-vault behavior, browser integration, release readiness, or distribution/license approval. No generated SDK is committed.
