# Shaar

Shaar (Hebrew שער, “gateway”) is a native macOS web browser built with Swift 6.2, SwiftUI, and AppKit. It combines profile-isolated browsing spaces with a Chromium rendering engine supplied through ArdiaCore.

## Requirements

- macOS 26 or later
- Apple silicon
- Xcode 26 with Swift 6.2 or later
- `bash`, `curl`, `jq`, `rg`, and Python 3 to fetch and bundle the engine

## Build and run

Build and launch the UI shell:

```sh
swift build
swift run ArcusisBrowser
```

To create a local app with the pinned Chromium engine:

```sh
bash scripts/bundle-app.sh --with-engine
```

This creates `build/Shaar.app`, signed ad hoc for local development. It is not a notarized release. The script verifies the pinned engine archive digest and extracted payload before staging it. See [Build and Run](Notebook/Build_And_Run.md) for engine source-build details and limits.

## Project layout

- `Sources/` — browser application, shared browser logic, and Chromium bridge
- `Tests/` — Swift unit and integration tests
- `Resources/` — app resources and bundled extension manager
- `ThirdParty/` — pinned upstream inputs, licenses, and notices
- `scripts/` — local build, packaging, and verification tools
- `Notebook/` — project architecture, build instructions, and verification notes

## Credits

See [CREDITS.md](CREDITS.md) for project and upstream acknowledgements. Chromium's bundled dependency notices are available from `chrome://credits` in an engine-enabled build; see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## License

Shaar's project license has not yet been chosen and will be announced here. Until then, no license for Shaar project code is granted by this repository. Third-party components remain subject to their own licenses; see [NOTICE](NOTICE) and [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
