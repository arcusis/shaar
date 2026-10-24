# Arcusis Browser

A native macOS 26+ browser project with an Arc-style sidebar, spaces assigned to profiles, and a Spotlight-style Command-T launcher. Browser controls use SwiftUI and AppKit.

## Current state

The first native-shell prototype builds and includes local spaces, profile assignments, tabs, pinning, selection, session persistence, and command search across tabs and spaces. The native space editor supports a new profile or explicit sharing of an existing profile. Spaces can be renamed, recolored, and removed; removing a space keeps its profile and refuses to remove the last space. Profile IDs are persisted on first launch before any navigation.

**Webpage rendering and Chrome extensions are not connected yet.** Profile identities in this prototype do not provide real cookie/account isolation until an engine is integrated and verified. History, bookmark search, drag/reorder, trackpad switching, multiple windows, and browser permissions remain future work.

The rendering engine decision is tracked in [issue #1](https://github.com/arcusis/browser/issues/1). Native SwiftUI/AppKit UI with Chromium is the proposed path for mandatory Chrome extensions. Choosing Apple WebKit instead requires validating the required extension list and accepting any documented compatibility limits.

## Build and run

Requires macOS 26+ and Xcode 26+ with Swift 6.2 or newer. No third-party packages are required for the shell.

```sh
swift build
swift run ArcusisBrowser
```

To assemble a local app bundle:

```sh
bash scripts/bundle-app.sh
```

The result is `build/Arcusis Browser.app`, signed ad hoc for local development. It is not a signed/notarized release. The prototype is not registered as a default browser.

Command-T / Command-L opens the launcher. Command-S toggles the sidebar. Control-Option-[ / ] switches spaces. Arrow keys select launcher results, Return executes, and Escape dismisses. Opening or dismissing the launcher creates no tab.

Sessions live in `~/Library/Application Support/Arcusis Browser/session.json`. Saved sessions include tab URLs, titles, profile assignments, pins, and selection. A malformed or unsupported session is preserved; the app uses a temporary session and reports that changes will not be saved.

## Verification

```sh
swift build
swift test
xcrun swift-format lint --strict --recursive Package.swift Sources Tests
```

Generate native view previews without opening a window or capturing the desktop:

```sh
.build/debug/ArcusisBrowser --render-preview /tmp/arcusis-shell.png
.build/debug/ArcusisBrowser --render-preview /tmp/arcusis-command.png --command
.build/debug/ArcusisBrowser --render-preview /tmp/arcusis-compact.png --command --compact
.build/debug/ArcusisBrowser --render-preview /tmp/arcusis-space-editor.png --space-editor
```

These previews verify native layout; they do not prove window focus, shortcuts, real account isolation, or browser engine compatibility.

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
