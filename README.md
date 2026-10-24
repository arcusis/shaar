# Arcusis Browser

A native macOS 26+ browser project with an Arc-style sidebar, spaces assigned to profiles, and a Spotlight-style Command-T launcher. Browser controls use SwiftUI and AppKit.

## Current state

The development app uses a SwiftUI/AppKit interface and a pinned ArdiaCore Chromium framework through a direct Objective-C++ bridge. It does not use the upstream React Native or Expo adapter. The native shell includes spaces, profiles, tabs, pinning, session persistence, and command search across tabs and spaces.

Each profile has its own persistent engine directory. A new space defaults to a separate profile; explicitly sharing a profile also shares its accounts. Changing spaces retains live tab objects and moves the selected native view. Tabs cannot silently switch to a different profile, and an unknown profile never falls back to the default profile.

Spaces can be renamed, recolored, and removed; removing a space closes its tabs, retains the profile's data, and cannot remove the last space. Normal tab closure waits for the engine's beforeunload decision. Profile IDs persist before navigation.

**This is not ready for company daily use.** Disposable local account fixtures prove cookie/localStorage isolation, per-tab sessionStorage, explicit profile sharing, live document retention during switching, and persistence after restart. They do not prove Google Workspace authentication or Bitwarden compatibility. Extension installation and website permissions are currently denied until native consent UI is implemented. History/bookmark UI, drag/reorder, trackpad switching, multiple windows, downloads, signing/notarization, real keychain integration, and engine security updates remain release gates. The engine decision and required compatibility checks are tracked in [issue #1](https://github.com/arcusis/browser/issues/1).

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
```

The engine test starts an authored HTTP fixture on an ephemeral loopback port and runs the bundled engine twice. It exercises the real native store/space integration with two independent profiles and a third explicitly shared space. It writes JSON reports, logs, and offscreen native/page images to a fresh marked temporary directory printed by the runner. It never opens an existing browser profile, orders a window onscreen, enables a debugging socket, changes VPN/DNS/network settings, or signs into real services. Chromium helpers retain their sandbox. Test profiles use a mock keychain and are not a test of release keychain/signing behavior.

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
