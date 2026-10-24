# Arcusis Browser

A native macOS 26+ browser project with an Arc-style sidebar, spaces assigned to profiles, and a Spotlight-style Command-T launcher. Browser controls use SwiftUI and AppKit.

## Current state

The development app uses a SwiftUI/AppKit interface and a pinned ArdiaCore Chromium framework through a direct Objective-C++ bridge. It does not use the upstream React Native or Expo adapter. The native shell includes spaces, profiles, tabs, pinning, session persistence, and command search across tabs and spaces.

Each profile has its own persistent engine directory. A new space defaults to a separate profile; explicitly sharing a profile also shares its accounts. Changing spaces retains live tab objects and moves the selected native view. Tabs cannot silently switch to a different profile, and an unknown profile never falls back to the default profile.

Spaces can be renamed, recolored, and removed; removing a space closes its tabs, retains the profile's data, and cannot remove the last space. Normal tab closure waits for the engine's beforeunload decision. Profile IDs persist before navigation.

The profile-scoped extension menu lists installed extensions and hosts action popups in native popovers. Native installation consent displays the engine's requested permissions, extension ID/version, source site, and destination profile. Switching profile/tab or navigating away cancels stale consent; popup views close on context changes and never enter saved tab lists. Unknown or unbound requests are denied. Extension side panels are not implemented.

Camera and microphone requests use native consent bound to the requesting origin, selected page, and profile. Grants last for the current visit. Extension installation and media requests share one consent queue; unseen or stale requests cannot be granted. A toolbar indicator lists capturing tabs across spaces and returns to the owning tab. Switching spaces retains active calls. Screen-sharing selection and other website permission types are not implemented; unsupported permission requests are denied.

Find in Page uses a native bar and Chromium's find API for highlighting, counts, and previous/next matches. Its query belongs to the selected document and is excluded from saved sessions. Changing tab/profile, navigating or reloading, opening consent, or closing the bar clears the search. A different tab starts with an empty query even when its space shares the same profile. The browser does not use a shared Find pasteboard or page scripts to perform matching.

**This is not ready for company daily use.** Disposable fixtures prove account and MV3 extension storage isolation and restart recovery. A real Chrome Web Store probe reaches native consent and registers Bitwarden 2026.10.0 as an enabled `FROM_STORE` extension. Its setup/welcome UI renders, and the email login form was verified after restart. The fresh-install probe still fails to advance from onboarding to that form; the overall gate remains red while the probe's interaction flow is investigated. This does not establish full Bitwarden support. Google Workspace authentication, real Meet devices and screen sharing, history/bookmark UI, drag/reorder, trackpad switching, multiple windows, downloads, signing/notarization, real keychain integration, and engine security updates remain release gates. Evidence and the compatibility matrix are tracked in [issue #1](https://github.com/arcusis/browser/issues/1).

## Build and run

Requires macOS 26+ and Xcode 26+ with Swift 6.2 or newer. The pinned development engine supports Apple silicon. The shell and unit tests build without downloading it.

```sh
swift build
swift run ArcusisBrowser
```

To build the browser with its engine (requires `curl`, `jq`, and `rg`):

```sh
bash scripts/bundle-app.sh --with-engine
```

The script verifies the engine archive's pinned SHA-256, embeds its framework/helpers/resources, signs nested code inside out, and verifies the local bundle. The result is `build/Arcusis Browser.app`, signed ad hoc for development. It is not a notarized release or registered as a default browser. Engine inputs and upstream notices are in [ThirdParty/ArdiaCore](ThirdParty/ArdiaCore/README.md).

`bash scripts/bundle-app.sh` without `--with-engine` builds `build/Arcusis Browser Shell.app`, a separate UI-only preview. `swift run ArcusisBrowser` also runs that preview without webpage rendering.

Command-T / Command-L opens the launcher. Command-S toggles the sidebar. Control-Option-[ / ] switches spaces. Arrow keys select launcher results, Return executes, and Escape dismisses. Opening or dismissing the launcher creates no tab.

Command-F opens Find in Page. Command-G / Shift-Command-G selects the next/previous match; Return in the find field also selects the next match. Escape or Done closes find and requests focus for its owning page. Live native keyboard/focus behavior still requires an interactive acceptance check.

Sessions live in `~/Library/Application Support/Arcusis Browser/session.json`. Saved sessions include tab URLs, titles, profile assignments, pins, and selection. Engine data lives in `Chromium/Profile <profile UUID>` below the same support folder. Real profiles use the OS keychain; the mock keychain is restricted to marked disposable test directories. No existing Chrome or Arc profile is imported. A malformed or unsupported session is preserved; the app uses a temporary session and reports that changes will not be saved.

## Verification

```sh
swift build
swift test
xcrun swift-format lint --strict --recursive Package.swift Sources Tests
bash scripts/test-engine.sh
```

Generate native view previews without opening a window or capturing the desktop:

```sh
.build/debug/ArcusisBrowser --render-preview /tmp/arcusis-shell.png
.build/debug/ArcusisBrowser --render-preview /tmp/arcusis-command.png --command
.build/debug/ArcusisBrowser --render-preview /tmp/arcusis-compact.png --command --compact
.build/debug/ArcusisBrowser --render-preview /tmp/arcusis-space-editor.png --space-editor
.build/debug/ArcusisBrowser --render-preview /tmp/arcusis-extension-consent.png --extension-consent
```

The engine test starts an authored HTTP fixture on an ephemeral loopback port and runs the bundled engine twice. It exercises the real native store/space integration with two independent profiles and a third explicitly shared space. A component-loaded MV3 fixture checks per-profile extension storage, service workers, long-lived ports, offscreen documents, content scripts, scripted autofill into disposable fields, active-tab targeting, popup disposal, and restart recovery. Component loading is restricted to the marked temporary probe root and does not prove normal store installation. The fixture's manifest contains a public test key only; no private key is distributed.

Media checks use Chromium fake camera/microphone devices and its simulated system-permission backend, restricted to marked disposable probe profiles. They verify separate-profile consent, temporary grants, denial, cancellation on context change, call continuity across space switches, and capture indicators. They never request physical hardware or change real macOS permissions. These checks do not establish Google Meet compatibility or real camera/microphone, screen-sharing, or macOS privacy-prompt behavior.

Find checks search authored fixture text through the real engine, including case-insensitive matching, forward/backward wraparound, rapid query replacement, profile/tab ownership, clearing, and same-URL reload cleanup. The runner also captures native find layouts at normal and minimum window sizes, and captures engine highlights separately. These checks do not prove Find behavior in every web app, PDF, canvas editor, or live native keyboard interaction.

The runner writes JSON reports, logs, and offscreen native/page/popup images to a fresh temporary directory. It never opens an existing browser profile, orders a window onscreen, enables a debugging socket, changes VPN/DNS/network settings, or signs into real services. Chromium helpers retain their sandbox. Disposable test profiles enable extension error diagnostics and use a mock keychain; they do not verify release keychain/signing behavior.

An additional opt-in integration test uses the actual Chrome Web Store and a separate empty disposable profile:

```sh
bash scripts/test-engine.sh --bitwarden
```

This test downloads and installs the signed store extension through the real native consent handler, then follows onboarding toward its email login form and checks installation recovery after restart. It skips the optional browser-password-manager settings change. It never enters credentials or alters an existing Bitwarden vault. Failed stages return a nonzero exit status and write diagnostics; an initial failure is preserved even when the restart phase passes. Diagnostic API reads run only after readiness failure is decided. The fresh-install onboarding-to-login failure currently keeps this gate red; successful component-fixture checks do not override it. Bitwarden unlock, real autofill/save/update, passkeys, native messaging, Touch ID, side panels, and company authentication remain unverified.

Offscreen SwiftUI/AppKit images verify native layout. Chromium's remote rendering surface may be absent from an AppKit bitmap; the test captures the authored page separately through the engine's in-process API. These images do not verify live keyboard focus, window shortcuts, Google Workspace, Bitwarden, Cloudflare Access, or a signed company installation.

## Plan

[GitHub milestone: Native Arc-style browser — macOS 26+](https://github.com/arcusis/browser/milestone/1)

1. [Engine and Chrome extension compatibility](https://github.com/arcusis/browser/issues/1)
2. [Native shell and persistent model](https://github.com/arcusis/browser/issues/2)
3. [Spaces, profiles, and switching](https://github.com/arcusis/browser/issues/3)
4. [Spotlight-style launcher](https://github.com/arcusis/browser/issues/4)
5. [Arc-style interface and interactions](https://github.com/arcusis/browser/issues/5)
6. [Daily-driver essentials](https://github.com/arcusis/browser/issues/6)
7. [Later features](https://github.com/arcusis/browser/issues/7)
8. [Verification and distribution](https://github.com/arcusis/browser/issues/8)
