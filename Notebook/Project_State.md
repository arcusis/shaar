# Project scope and acceptance

Native macOS 26+ internal Arc replacement: SwiftUI/AppKit chrome, pinned Chromium, arbitrary Spaces with per-Space pins/folders/saved tabs, simultaneous isolated accounts and explicit profile sharing, page-centered Command-T, Library/downloads and native dragging. Bitwarden required. Surfshark excluded. Google Workspace/Meet and Cloudflare Access remain company acceptance gates.

The [first milestone](https://github.com/arcusis/browser/milestone/1) remains open. GitHub issues own live task state; this note records acceptance boundaries, not session activity.

- Native shell, profile/Space models, launcher, sidebar organization, Library and browser essentials are published on `production`.
- Lazy tab restoration avoids loading every saved page. Sidebar indexing removes repeated sibling scans; model/CPU checks do not establish total-process performance with hundreds of live pages.
- Synthetic vendor login/lock/unlock/restart control passes in two separate profiles and an explicitly shared-profile Space. Full autofill/save/update and clean first-click compatibility remain [#9](https://github.com/arcusis/browser/issues/9).
- Physical keyboard/pointer/trackpad, drag/drop, native focus and close cancellation remain [#4](https://github.com/arcusis/browser/issues/4), [#5](https://github.com/arcusis/browser/issues/5), [#21](https://github.com/arcusis/browser/issues/21), [#24](https://github.com/arcusis/browser/issues/24) and [#37](https://github.com/arcusis/browser/issues/37).
- Real company Workspace/Meet/Cloudflare Access compatibility remains [#1](https://github.com/arcusis/browser/issues/1), [#3](https://github.com/arcusis/browser/issues/3) and [#6](https://github.com/arcusis/browser/issues/6).
- Realistic process performance, engine update/provenance and signed/notarized distribution remain [#8](https://github.com/arcusis/browser/issues/8) and [#19](https://github.com/arcusis/browser/issues/19). Archive comparison currently rejects changed CodeResources; source/build attestation remains incomplete.

Source CI, authored screenshots and hidden native fixtures each prove their own scope. None establishes physical input, company-site compatibility or release acceptance. Company daily use is not accepted yet. Development bundles are ad hoc signed, not notarized releases.

Related: [[Bitwarden_Compatibility]], [[Source_And_Native_Verification]], [[Abrupt_Restart_Durability]].
