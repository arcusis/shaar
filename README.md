# Arcusis Browser

Native macOS 26+ browser with SwiftUI/AppKit controls, an Arc-style sidebar, profile-isolated Spaces and a Spotlight-style Command-T launcher. Uses pinned Chromium through ArdiaCore.

Project knowledge lives in [Notebook](Notebook/_INDEX_Main.md): [build/run](Notebook/Build_And_Run.md), [architecture](Notebook/_INDEX_Browser.md), [verification](Notebook/_INDEX_Verification.md), and [acceptance gates](Notebook/Project_State.md).

```sh
swift build
swift test --jobs 2
bash scripts/bundle-app.sh --with-engine
```

The engine bundle requires macOS 26+, Xcode 26+ and Apple silicon. `swift run ArcusisBrowser` provides a UI-only preview. Development bundles are ad hoc signed; company daily use and signed/notarized distribution remain unaccepted.

[Milestone and issues](https://github.com/arcusis/shaar/milestone/1) track remaining work. Engine inputs and upstream notices: [ThirdParty/ArdiaCore](ThirdParty/ArdiaCore/README.md).
