# Engine module: navigation, load state, and new-window requests

Issue: [#418](https://github.com/arcusis/shaar/issues/418)

Design basis: [[Engine_Ardia_Inventory]] and [[Engine_Shaar_Layer_Design]] (merged in #419).
Scope: URL navigation, back/forward/reload/stop, URL/title/loading/capability updates, navigation failures, page-created tabs and popup/new-window requests. This note extends the shared ABI sketch; it does not redefine engine, profile, window, tab, or callback ownership.

## 1. Current Shaar use

There is no navigation-specific `ac_*` function resolved or invoked by Shaar. `ac_*` is the C service surface used for downloads, library, site controls, and event registration (see the inventory). Navigation is currently Objective-C calls on `ARCChromiumRuntime`, backed by `ArdiaCoreTab` and `ArdiaCoreWindow`.

| App behavior | Current path |
| --- | --- |
| Address entry and favorite-page navigation | `BrowserEngine.swift:89-98,121-136` validates selected/live ownership and calls `navigateTabID(_:profileID:windowID:url:)`; `BrowserStore.swift:129-130,647` supplies favorite-page navigation. |
| Page URL/title/loading/back-forward state | `ChromiumBridge.h:107-112` declares `onTabChanged` and its private counterpart. `ChromiumBridge.mm:571-594` publishes URL, title, loading, `canGoBack`, and `canGoForward`, splitting regular and private mappings. `BrowserEngine.swift:388-405` updates `PageState`, load UI, tab/favorite metadata, and document-dependent models. |
| Back, forward, reload | Regular API declarations are `ChromiumBridge.h:155-159`; implementations include `ChromiumBridge.mm:909-933`. Private APIs are `ChromiumBridge.h:312-315`, implemented in `ChromiumPrivateBrowsing.mm:421-440`. UI actions are in `PageNavigationButtons.swift:14-32`, `PrivateBrowserWindow.swift:142-160`, and reload mode is routed by `BrowserEngine.swift:121-123`. `BrowserStore.swift:707-735` implements reload and failed-page recovery. |
| Navigation events / commit / failures | `BrowserRuntimeEvents.swift:30-41` forwards tab updates, renderer loss, and document commit. `ChromiumBridge.h:115-116` exposes private navigation failure; `ChromiumBridge.mm:1483-1491` translates it. `BrowserEngine.swift:388-405` consumes state changes. |
| Page-created tab and window request | `BrowserRuntimeEvents.swift:43-52` binds and forwards `onNewTab`, discarding an unclaimed tab. `NativeBrowserHost.swift:164-170` handles window-request and adoption callbacks. `ChromiumBridge.mm:596-730` classifies and adopts page-created tabs; `ChromiumBridge.mm:706-730` dispatches popup/window requests and closes rejected/unadoptable tabs. |

For regular navigation, `ChromiumBridge.mm:477-505` checks canonical IDs, URL form, profile/window/tab ownership, and lifecycle before calling `loadURL:userInitiated:`. Back/forward/reload advance the document generation and invalidate external-app requests (`:909-933`). Private operations independently validate context/window/tab ownership and allowed URLs (`ChromiumPrivateBrowsing.mm:406-439`). Keep these stale-document and ownership protections in the adapter migration until equivalent engine request cancellation and typed errors are established.

## 2. Pinned Ardia implementation and patch dependencies

Sources below are read-only in `engine-333-364/build/EngineSource/source/ardia`.

- `engine/ardiacore/src/ardia/core/public/ArdiaCore.h` declares `ArdiaCoreTab` navigation methods/properties (`goBack`, `goForward`, `reload`, `reloadIgnoringCache`, `loadURL:userInitiated:`, URL/title/loading/capability state), tab/window delegates, and callbacks for failed navigation, blocked popups, and new tabs.
- `engine/ardiacore/src/ardia/core/ardiacore_api.mm` implements the Objective-C tab API over Chromium `content::WebContents` and its `NavigationController`; it also translates popup blocker requests and window dispositions.
- `engine/ardiacore/src/ardia/core/ac_browser.h` and `ac_browser.mm` own tab/window state, implement `content::WebContentsObserver` and `content::WebContentsDelegate` callbacks, observe navigation start/finish/failure, propagate URL/title/loading/can-go state, and receive newly inserted contents. `ac_browser.mm` also handles navigation failure and delegate callbacks.
- Shaar's bridge routes these objects in `Sources/ChromiumBridge/ChromiumBridge.mm` and `ChromiumPrivateBrowsing.mm` as described above. `ChromiumBridge.mm:788-825` defers tab-strip reconciliation after activation because synchronous reconciliation can reenter Ardia notifications. Preserve ordering/defer semantics in the Shaar event dispatcher.
- The shared inventory's patch list contains no patch specifically required to make ordinary `NavigationController` navigation work. `chromium-window-hosted.patch` and `chromium-hidden-window-current-window.patch` affect native window hosting/current-window selection, which is adjacent to popup presentation and must be reviewed with the window module. `chromium-extension-window-hidden.patch` concerns extension-owned popup windows, not page-created tabs. `chromium-initial-document-access.patch` affects early document access and is relevant to extensions/page hooks, not basic URL/load-state reporting. Do not treat any as a navigation API dependency. Confirm their precise behavior and retained/replaced status in the relevant window, extension, and page-channel module specs.

This is a behavior inventory, not a recipe for copying Ardia implementation.

## 3. Chromium 155 APIs for Shaar's layer

The pinned full tree is `engine-333-364/build/EngineSource/chromium_git/chromium/src`.

| Need | Chromium API and tree paths |
| --- | --- |
| Navigate, history, back/forward, reload | `content::WebContents::GetController()` in `content/public/browser/web_contents.h`; `content::NavigationController` in `content/public/browser/navigation_controller.h` (`LoadURLWithParams`, `CanGoBack/CanGoForward`, `GoBack/GoForward`, `Reload` with `content::ReloadType`). Prefer `NavigationController` for session-history semantics; `WebContents::GetLastCommittedURL()` is not a substitute for pending/current visible URL. |
| Loading state, visible/committed URL, title, renderer loss | `content::WebContentsObserver` in `content/public/browser/web_contents_observer.h`: `DidStartNavigation`, `DidFinishNavigation`, `PrimaryPageChanged`, `TitleWasSet`, `DidFailLoad`, `LoadProgressChanged`, `WebContentsDestroyed`, and render-process-gone callback. `content::WebContents` in `web_contents.h` provides `IsLoading`, `GetVisibleURL`, `GetTitle`, and controller access. Use `NavigationHandle` from `content/public/browser/navigation_handle.h` to distinguish primary main frame, same-document, committed, error-page, redirect, and failure cases. |
| New tabs/windows from a page | `content::WebContentsDelegate` in `content/public/browser/web_contents_delegate.h`: `OpenURLFromTab` and `AddNewContents`; `content::WebContents::CreateParams` in `web_contents.h` to bind the correct `BrowserContext`. Chromium creates the target contents; Shaar's delegate owns the pending request and either adopts it into a Shaar window/tab or closes it. |
| Chrome tab creation/insertion and ownership | `Browser` and `TabStripModel` in `chrome/browser/ui/browser.h`, `chrome/browser/ui/tabs/tab_strip_model.h`, and `chrome/browser/ui/tabs/tab_strip_model_observer.h`. Use `TabStripModel`'s insertion/adoption APIs and observer notifications only behind Shaar's explicit profile/window ownership checks. |
| Blocked popup requests | `components/blocked_content/popup_blocker_tab_helper.h` and `components/blocked_content/popup_opener_tab_helper.h`; honor Chromium's popup-blocker decisions and user gesture metadata rather than bypassing them with direct URL loads. |

Observe state from a per-tab `WebContentsObserver`; avoid treating `DidStartNavigation` and `DidFinishNavigation` as a guaranteed one-to-one pair. Emit an initial snapshot when the tab is bound, updates for meaningful main-frame/same-document state changes, and a final close event before invalidating the tab handle. Track a monotonic navigation generation in Shaar for stale callbacks and cancellation. URL/title are untrusted page data; URL policy validation occurs before initiating navigation and must not be replaced by UI-only filtering.

## 4. ABI extension for navigation

Use the existing ABI v1 types, `shaar_scope`, opaque handles, `shaar_submit`, request IDs, single event callback, and typed errors from `Engine_Shaar_Layer_Design`. All operations below require the `shaar_scope` for the owning regular profile or first-class private session, plus the exact `shaar_window` and `shaar_tab`; reject a mismatched handle as `SHAAR_WRONG_PROFILE`/`SHAAR_WRONG_SESSION`. Never infer scope from the URL or tab. Private requests use the private session's independent IDs in every event, and private browsing state remains nonpersistent.

### Operation additions and payloads

The shared enum already has `SHAAR_OP_TAB_NAVIGATE`, `SHAAR_OP_TAB_GO`, and `SHAAR_OP_TAB_RELOAD`. Add `SHAAR_OP_TAB_STOP` and `SHAAR_OP_WINDOW_REQUEST_RESOLVE`; append them without renumbering existing ABI members. All use `shaar_submit` and return `shaar_result` asynchronously; malformed input and ownership errors can be returned immediately using the existing `immediate_error` contract.

- `TAB_NAVIGATE`: args `{schemaVersion:1,url:string,userInitiated:boolean}`. Accept only supported navigation schemes under one shared engine policy. Reject empty/oversized/control-character URLs and malformed host/port values as `SHAAR_INVALID_ARGUMENT`; return `SHAAR_POLICY_BLOCKED` for prohibited schemes or policy restrictions. Preserve user-initiated attribution for Chromium security/UI behavior.
- `TAB_GO`: args `{schemaVersion:1,direction:"back"|"forward"}`. If history is unavailable, return a typed `SHAAR_CONFLICT` result with reason `no_back_entry`/`no_forward_entry`; do not silently treat a no-op as success.
- `TAB_RELOAD`: args `{schemaVersion:1,mode:"normal"|"bypass_cache"}`. Keep cache bypass explicit. A combined clear-data-and-reload action remains a site-data operation followed by navigation logic, not a hidden reload mode.
- `TAB_STOP`: args `{schemaVersion:1}`. Stop the current navigation with Chromium's stop API; return success only after the request is accepted by the UI-thread dispatcher.
- `WINDOW_REQUEST_RESOLVE`: args `{schemaVersion:1,requestID:string,decision:"adopt"|"deny",targetWindowID?:string,tabID?:string}`. Scope must match the opener's session. `adopt` requires an already opened target window in that same scope; engine adopts the pending `WebContents`, assigns the caller-provided tab ID (or a generated ID under the same ID policy), and returns the tab/window IDs. `deny` closes pending contents. Missing/expired requests return `SHAAR_NOT_FOUND`; cross-scope or cross-profile targets return typed ownership errors. A request is single-use, expires, and is cancelled on opener/target/window/session close.

Keep result payloads versioned, reject unknown fields, and return real errors rather than empty success objects. The ABI sketch's `shaar_error_code` has no dedicated invalid-state code; use `SHAAR_CONFLICT` for a valid operation blocked by current navigation/history state and `SHAAR_CHROMIUM_ERROR` only for engine failures, including a stable reason in the result payload. Do not expand the global error enum in this module without coordinating the ABI owner.

### Events

Use `SHAAR_EVENT_NAVIGATION` for tab-state snapshots and transitions. Payload schema v1 should carry `phase` (`started`, `committed`, `finished`, `failed`, `stopped`, `state`), `navigationID`, monotonically increasing per-tab `generation`, `url`, `title`, `loading`, `canGoBack`, `canGoForward`, `sameDocument`, and optional typed `failure` (`netError`, `isMainFrame`, `descriptionCode`). Null/empty URL and title have documented exact meanings. Emit page-readable URLs only; redact credentials and never send profile paths. Send progress only if the adapter actually consumes it. Keep terminal results distinct from successful commits (e.g. an HTTP error-page commit is a commit with failure metadata, not a transport success).

Use the existing `SHAAR_EVENT_WINDOW` for a new-window request payload: `kind:"newWindowRequest"`, `requestID`, opener tab ID, requested URL, disposition (`newTab`, `newWindow`, `popup`, `backgroundTab`), user gesture, and safe feature hints. Include regular profile ID and private session ID per the shared event contract. The pending contents is not yet a public tab handle; the Swift shell decides presentation and creates/binds the target window, then resolves the request. Use `SHAAR_EVENT_TAB` for tab adoption/close and preserve ordering: request event, resolution result, tab-created/adopted event, then navigation state. Rejected, expired, malformed, or unhandled requests close the pending contents. This event is for page-created windows; extension-action popups remain owned by the extension module.

## 5. Swift adapter migration

Keep `ChromiumBridge` as the existing Swift-facing adapter. Add thin wrappers for the new ABI operations that encode the documented payloads, pass the exact scope/window/tab handles and request ID, copy callback bytes before returning, and map error codes to the existing localized adapter error type. Translate `SHAAR_EVENT_NAVIGATION` into the existing tab state/update callbacks first so `BrowserEngine` and `BrowserStore` keep their current model contract; later simplification of those callbacks belongs in a separate app change.

Migrate `BrowserEngine.swift:89-98,121-136` and page controls to the shared operations; remove the separate regular/private navigation entry points only after parity probes pass. Convert `BrowserEngine.swift:388-405` state updates from event payloads. Route `SHAAR_EVENT_WINDOW` requests through `BrowserRuntimeEvents.swift:43-52`/`NativeBrowserHost.swift:164-170`: generate/validate a target window in the event's exact profile/session, resolve with an explicit adopt/deny, and preserve opener ID, foreground/background disposition, tab order, and focus policy. Do not auto-adopt based on a currently active or default profile. On client teardown, cancel outstanding request IDs; if a callback is stale, reject or ignore it and close pending engine contents. Keep document-generation invalidation for Inspector, external app, and page-find state tied to accepted navigation events.

## 6. Verification plan

These are acceptance checks for the future implementation; no local engine build is part of this spec task.

- **Unit tests:** URL/scheme/size validation; navigation argument and enum decoding; exact profile/session/window/tab ownership; history boundary errors; reload-mode mapping; event payload versioning, ordering, ID propagation, and URL credential redaction; stale generation suppression; popup request expiry/single-use and invalid-target rejection.
- **Engine simulation:** Use a deterministic fake `WebContents`/controller and observer/delegate or Chromium test harness to drive start → redirect → commit → title → finish; same-document pushState/hash; failed provisional/main-frame load and error-page commit; stop; renderer loss; back/forward capability transitions; reload and bypass-cache. Assert every event snapshot and request result, including cancellation and callbacks after tab close.
- **Engine simulation (popup):** exercise user-gesture popup, script popup without gesture, blocked popup and explicit user opening, background tab, new window, malformed URL, target creation delay, deny, timeout, opener close, private-session close, and cross-profile target. Assert Chromium policy is honored, pending contents are closed exactly once, and no popup escapes its parent regular/private scope.
- **Smoke checks:** in a regular profile and a private session, navigate through address bar, redirects, same-document changes, back/forward, normal and hard reload, stop, page title changes, network failure/retry, browser back/forward/reload UI, popup/new-window adoption and denial. Confirm URL/title/loading/canGo state stays in the matching window/tab, private IDs are distinct and events never appear in regular state, then close/reopen regular profile and verify durable workspace URL behavior without private persistence. Run existing BrowserStore/failed-page/private-browser tests plus the native source-engine probe and CI ABI/export checks when implementation exists.

Parity means equivalent visible state transitions and popup/window policy, including rejection behavior and ownership. A compiling adapter or a static mock alone does not prove Chromium observer timing, AppKit adoption, or private teardown.

## 7. Effort and risks

Rough effort: **2–4 engineer-weeks**, consistent with the navigation/recovery range in the shared design, excluding Chromium sync/build time and the broader window/tab foundation. Scope includes C++ operation/event implementation, Swift adapter routing, regular/private parity, simulation tests, and native smoke probes. Popup/new-window handoff depends on the window/tab module's host and adoption work, so this can overlap only after its ownership API is agreed.

Main risks are event ordering/reentrancy around `TabStripModel` callbacks; distinguishing visible, pending, committed, same-document, and error-page URLs; late callbacks after tab reuse/close; popup blocker and user-gesture semantics; delayed AppKit window creation during a pending popup; and private-session ID isolation/teardown. History/reload methods can be no-ops at boundary states, so the typed result contract must be explicit. The migration must preserve cancellation of document-bound requests and not accidentally route page-created windows through extension popup handling. This module alone does not establish engine-build, Chromium patch-removal, or production runtime parity.
