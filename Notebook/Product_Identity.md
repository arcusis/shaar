# Product identity: Shaar

The browser is **Shaar** (Hebrew שער, "gateway"): a browser is a gateway to the internet. Arcusis is the company; it appears as the copyright holder ("© 2026 Arcusis. All rights reserved."), not in the product name.

## What carries the name

`ProductIdentity.name` in `Sources/BrowserCore/ProductIdentity.swift` is the only place the name is spelled. Menus, window titles, the quit dialog, Settings About, the process-lock message read it. The bundle is `build/Shaar.app` (`build/Shaar Shell.app` for the UI-only preview).

## What deliberately keeps the old identity

- Bundle identifier `com.arcusis.browser`. The never-shipped probe harness uses `com.arcusis.browser.verification` instead; see [[Verification_Harness]].
- Data folder name `Arcusis Browser` (`ProductIdentity.dataFolderName`) under the user-level Application Support directory.
- Swift target and executable names (`ArcusisBrowser`).

macOS keys LaunchServices, privacy permissions (camera, microphone, location), the default-browser setting, and Keychain items to the bundle identifier. The app finds profiles, sessions, and saved passwords through the data folder. Renaming either would make Shaar a new app to macOS and lose that state. Change them only with a migration.

## Brand assets

Logo, app icon, palette, and usage rules live in `Branding/` with `Branding/DESIGN.md`. The bundled `Resources/Branding/Shaar.icns` is generated from `Branding/shaar-app-icon.svg` by `scripts/generate-app-icon.sh`.

Related: [[Build_And_Run]], [[Project_State]], [[Managed_Workspace_Persistence]].
