# Swift auth proof

This proof invokes the generated Swift UniFFI auth API from the pinned SDK dylib and directs it at a runner-owned HTTP mock bound to `127.0.0.1`. The only endpoint configured in SDK settings is that mock. Device identity and the server authorization hash are checked in mock process memory; credentials, hashes, tokens, raw requests, SDK errors, and child output are not written to proof output.

Reproduce on arm64 macOS 26+ with the already-built accepted proof artifacts:

```sh
python3 scripts/test-native-bitwarden-swift-auth.py \
  --proof-root /private/tmp/native-bitwarden-auth-proof-850c53c \
  --source ~/orca/workspaces/browser/browser-queue-company-readiness/build/NativeBitwardenSDKProbe/sdk-internal \
  --output /private/tmp/native-bitwarden-swift-auth-proof-focused-retry-2
```

`--source` must point at pristine pinned checkout. Do not use `/private/tmp/native-bitwarden-auth-proof-850c53c/sdk-internal`: that checkout is patched. `--output` must be a fresh path. Runner validates fixed receipt, clean pinned source, patch SHA-256, dylib SHA-256, generated Swift tree SHA-256, and minimum deployment metadata before compiling. It writes a mode-0600 atomic `receipt.json`; terminal output uses fixed labels. Auth calls have process bounds. Runner shuts down its loopback server and removes private build output on every exit path. Receipt records source/artifact hashes, host OS/architecture, executable hash, and macOS 26.0 minimum metadata for dylib and Swift executable.

Current scope: native Swift/FFI HTTP mock only. `auth_passed` reports prelogin, MFA challenge, valid-MFA retry, invalid-MFA rejection, malformed challenge rejection, posted identity/device type, and SDK-derived password hash checks. `native_task_cancellation_supported=false` is explicit: task cancellation does not cancel the pinned generated Swift FFI call. A separate bounded parent-owned termination records child exit and listener socket/thread cleanup; it does not convert native cancellation into supported behavior. `integration_ready=false` remains explicit even when diagnostic stages pass. This does not establish TLS behavior, compatibility with a real server, a usable vault session, sync, autofill, product support, or release readiness. The generated client identifier is synthetic and makes no server registration claim. Successful auth response does not create or claim product session state. SDK internal API remains unstable and unsupported for third-party use; GPL experiment and notices remain applicable.

Runner also exercises malformed local requests and fixed redacted responses. Boundary tests cover changed artifact bytes, strict boolean/schema and nested receipt validation, path escape, receipt symlink, exact standalone child labels, sanitized child environment, foreign endpoint rejection, malformed request rejection and listener cleanup. No child output, error body, request, credential, hash, or token is persisted. Parent must independently rerun proof after applying this diff. Host stale-result protection and native lifecycle support remain open work under issue #94; integration readiness stays false.
