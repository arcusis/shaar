# Bitwarden compatibility boundaries

The extension and native password-manager integrations are separate. Extension tests do not establish native SDK, Keychain, form-fill, or vendor compatibility. See [[Native_Password_Manager_Options]].

An opt-in fixture installs the signed Chrome Web Store extension into a disposable Profile and exercises its fresh-install onboarding and restart behavior:

```sh
bash scripts/test-engine.sh --bitwarden
```

The fixture does not enter credentials or access an existing vault. A separate timing control delays its first onboarding input:

```sh
bash scripts/test-engine.sh --bitwarden-onboarding-control
```

The control is diagnostic only; its result cannot satisfy clean first-click acceptance. Synthetic vault fixtures cover login, lock/unlock, Profile binding, and restart in isolated test accounts. They do not establish vendor autofill/save/update, passkeys, native messaging, Touch ID, side panels, company authentication, or real-service compatibility.

Related: [[Extension_Consent]], [[Native_Vault_Session_Boundary]], [[Project_State]].
