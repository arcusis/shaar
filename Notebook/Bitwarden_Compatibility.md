# Bitwarden compatibility gates

These results describe the tested extension backend. User-facing password-manager integration is optional and native Settings is required. Backend choice is under review in [[Native_Password_Manager_Options]]; extension test results do not establish SDK/native-provider compatibility.

An additional opt-in integration test uses the actual Chrome Web Store and a separate empty disposable profile:

```sh
bash scripts/test-engine.sh --bitwarden
```

This test downloads and installs the signed store extension through the real native consent handler, then follows onboarding toward its email login form and checks installation recovery after restart. It skips the optional browser-password-manager settings change. It never enters credentials or alters an existing Bitwarden vault. Failed stages return a nonzero exit status and write diagnostics; an initial failure is preserved even when the restart phase passes. Route/input transitions are recorded. Only after readiness has failed does a separate diagnostic try a second ordinary Log in click; its result cannot change the failed gate. Diagnostic API reads and extension-error inspection follow that second click. The fresh-install onboarding-to-login failure currently keeps this gate red; successful component-fixture checks do not override it. Full vendor autofill/save/update, passkeys, native messaging, Touch ID, side panels, and company authentication remain unverified. The separate vault control below covers synthetic login/lock/unlock/restart only.

A separate diagnostic control waits for a two-second intro-screen age before its first Log in input. The clean mode retains its existing 500ms stable-screen age. The control changes test input timing only; browser behavior, vendor code and extension storage are not patched or prewarmed.

```sh
bash scripts/test-engine.sh --bitwarden-onboarding-control
```

Both Bitwarden modes emit phase/mode-bound vendor reports and `bitwarden-onboarding-summary.json`. A passing control always records `controlOnly: true` and `firstClickAcceptancePassed: false`. Missing or malformed phase/mode/check evidence cannot produce a clean acceptance result. The current two-second control reaches the fresh email login form after its first Log in click; clean first-click readiness remains a separate gate. This establishes timing sensitivity, not a vendor-only or engine-only root cause. It does not replace native input/stock-browser comparison or vault testing.

The separate synthetic vault control uses two disposable encrypted accounts and the normally installed vendor extension over private loopback HTTPS. [PR #48](https://github.com/arcusis/shaar/pull/48) passed both initial and normal restart phases: login, Lock/Unlock/relock, account identity, cross-profile mismatch and deliberate shared-profile behavior. Its result remains `controlOnly: true` and `firstClickAcceptancePassed: false`. It does not prove vendor autofill/save/update or clean first-click compatibility. Phase-specific stage requirements are mandatory; stages belonging to the other phase are not acceptance evidence.

Related: [[Extension_Consent]], [[Project_State]].
