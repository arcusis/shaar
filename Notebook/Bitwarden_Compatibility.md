# Bitwarden extension compatibility

Bitwarden is supported as a regular Chromium extension through Shaar's global extension support. The compatibility probe installs the signed Chrome Web Store extension into a disposable Profile and checks its onboarding and restart behavior:

```sh
bash scripts/test-engine.sh --bitwarden
```

The probe does not enter vault credentials or access an existing account. Results cover this extension flow only; they do not establish every Bitwarden feature or vendor support commitment.

Related: [[Extension_Consent]], [[Extension_Storage_Verification]], [[Project_State]].
