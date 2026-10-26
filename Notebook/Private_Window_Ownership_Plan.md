# Private window ownership

Private windows are required by #6 and remain unimplemented. This contract defines the next source work; it is not private-session acceptance. Base: production `48b0ac186eca6e5e1d2960e38fd7166399b1fd7d`.

## Engine boundary

Pinned ArdiaCore source is `91e17a5655519d2dc385ec8452432469232ff9af` (see `ThirdParty/ArdiaCore/pin.json`). The public header exposes `offTheRecordProfileFor:completion:`, `releaseProfile:`, `offTheRecord` and `destroyed`. Header Git blob `b3c2ece92ee5619209e7e4f83e394e9860476c62` matches this repository. Pinned upstream [`ardiacore_api.mm`](https://github.com/mantrakp04/ardia/blob/91e17a5655519d2dc385ec8452432469232ff9af/engine/ardiacore/src/ardia/core/ardiacore_api.mm), blob `a0d6540b3386887d4b4e6395b4553d412ea0df81`, provides the actual factory/release behavior: one primary OTR profile per regular Profile; creation waits while an earlier OTR profile is dying; release delegates to `ProfileDestroyer` when no matching non-closing native browser remains. Native source/API presence is separate from pinned-binary runtime acceptance and provenance (#19).

Current app bridge rejects OTR in normal profile load, navigation/order and engine-created-window routing. Service events mark OTR under the original Profile path; the adapter intentionally drops them. Preserve those regular-path guards. Private ownership needs explicit separate maps and APIs, never an OTR entry in `_profiles` or a temporary regular disk profile deleted afterward.

## Implementation sequence

1. **Actual native ownership and fixture.** One serial owner changes `Sources/ChromiumBridge/include/ChromiumBridge.h`, `Sources/ChromiumBridge/ChromiumBridge.mm`, `Sources/ArcusisBrowser/EngineProbe.swift`, `scripts/engine_fixture.py`, `scripts/test-engine.sh`; adds `Sources/ArcusisBrowser/PrivateWindowProbe.swift` and `Tests/EngineFixtureTests/test_private_window_fixture.py`. Create explicit private native contexts from already-loaded regular Profiles; bind opaque context/window/tab identities and pending async ownership. Keep source regular Profile and OTR lifetime separate. Reuse one private context only for windows deliberately sharing the same source Profile. Confirm native close before retiring the final owner/releasing OTR; cancellation and stale callbacks cannot destroy a live context. Unsupported popups/extensions remain denied. No product menu or private UI yet. Prove actual cookies/storage/history and close/reopen isolation against the pinned engine before adding a model abstraction.
2. **Transient product host/store.** After native proof, one serial owner changes `NativeBrowserHost.swift`, `BrowserStore.swift`, `BrowserWindow.swift`, `ArcusisBrowser.swift`, `BrowserEngine.swift` and owning app tests. Use a private context/store with no normal workspace writer, restore record, normal closed-tab recovery, pin/favorite/catalog mutation or persisted Library history. Derive further file scopes from slice1's final API. Do not add a generic lifecycle model unless actual native ownership requires it. Add owning-window commands and unmistakable private appearance; SDK/vault integration stays unavailable until separate private policy and lifecycle are accepted.
3. **Production persistence/restart gate.** Extend the same private fixture and add host/store tests. Snapshot settled normal workspace bytes before private operations; create/navigate/close private windows without any normal catalog/selection/geometry writes. Compare exact bytes/hash after private operations and graceful quit. Restart same owned fixture root: normal saved windows/localStorage/cookies/history recover; private window/tab/metadata and old private cookie/storage do not. A fresh private session starts empty. Physical input, menus, accessibility and company services remain separate gates.

## Owned native acceptance

Use only marked fresh disposable roots and the existing loopback fixture server/hidden native engine runner. Never existing browser profiles, accounts, vendor endpoints or desktop events. Every report must contain real stage booleans, bounded run-owned IDs and digests; missing/malformed/zero-check results fail. Preserve failure evidence and verify process/listener/window cleanup.

| Check | Required observation |
| --- | --- |
| Source/Profile ownership | Unknown, closed, malformed or OTR-as-source contexts reject. Two regular Profiles get distinct OTR contexts; two private windows sharing one regular Profile deliberately share only that OTR context. |
| Cookies/localStorage | Normal and private pages on the same loopback origin read only their own markers. Separate private source Profiles stay isolated. Sharing within one OTR context is deliberate. Last private close/reopen clears old private values; normal values remain. |
| sessionStorage | Distinct tabs retain tab-local semantics. Normal live tab survives private close; newly opened private tab has no prior tab session. Do not require normal sessionStorage to survive process restart: app restores URLs as new documents. |
| History | Actual native normal-history query retains authored normal path and excludes authored private path, before/after close and restart. Dropped OTR events alone are insufficient evidence. Return sanitized path classes/digests, not page data. |
| Native lifecycle | Private tabs/windows stay in explicit private ownership; close cancellation retains ownership; confirmed final close retires callbacks/tabs/window IDs before OTR release. Closing one shared private owner leaves the other live. Normal windows and selection remain unchanged. |
| Workspace/restart | At product-host stage require exact settled normal workspace bytes/hash unchanged by private operations. No private records, Library entries, launcher results or recovery entries after restart; normal localStorage/cookies/history survive. |

## Decisions before product UI

Downloads, bookmarks, extensions, permission/media/external-app prompts and password-manager availability require explicit private routes. Initially unavailable or memory-only where supported; never route private metadata through normal services merely because engine events use the original path. Download files explicitly requested by users are not auto-deleted on private close. Do not promise all private data leaves no disk artifacts from Chromium internals without evidence.

The bridge and host/probe dispatch files are shared seams. Implement sequentially or transfer named ownership; no concurrent edits. SDK proof #113 is independent; composed native vault lifecycle remains #114. No source plan, fake model, hidden screenshot or dropped event proves private browsing works.

Related: [[Managed_Workspace_Persistence]], [[Native_Window_Ownership]], [[Bookmark_History]], [[Source_And_Native_Verification]], [[Native_Vault_Session_Boundary]].
