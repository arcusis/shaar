# Find module spec for issue #418

Status: module proposal, 2026-11-03. This extends [[Engine_Shaar_Layer_Design]] phase 9 and follows [[Engine_ABI_Conventions]] as published in #420. It is a fresh interface proposal for Chromium 155; it does not reuse Ardia implementation code. No build or runtime claim is made.

## Current Shaar path

Find has no resolved `ac_*` call or C export. The app goes through the Objective-C `ChromiumBridge` adapter and Ardia's Objective-C tab API:

| Layer | Current behavior and source |
| --- | --- |
| Swift UI | `Sources/ArcusisBrowser/PageFindBar.swift:12-53` renders query, match status, previous/next controls, Enter, Escape and Done. `Sources/ArcusisBrowser/PageFindState.swift:8-40` holds transient profile/tab/document identity, UUID request token, query, count, active ordinal and progress; query state is not persisted. |
| Swift model | `Sources/ArcusisBrowser/BrowserStore.swift:365-408` issues a fresh request UUID per query/step, ignores stale tab/token/document results, stops on empty query or dismissal, and treats an unavailable native request separately. `Sources/ArcusisBrowser/BrowserEngine.swift:272-285` forwards the request and translates native result fields. Loading a new document dismisses find at `:392-394`. |
| Swift callback routing | `Sources/ArcusisBrowser/BrowserRuntimeEvents.swift:53-55` routes the result by tab to the owning client. The callback shape is declared as `onFindResult(tabID, requestID, count, active, final)` in `Sources/ChromiumBridge/include/ChromiumBridge.h:97`. |
| Bridge and state | `Sources/ChromiumBridge/include/ChromiumBridge.h:160-162` declares `findInTabID:profileID:requestID:text:forward:` and `stopFindingInTabID:`. `Sources/ChromiumBridge/ChromiumRuntimeInternal.h:22-43` keeps active find tab, request token and text with each native window state. `Sources/ChromiumBridge/ChromiumBridge.mm:1001-1030` validates live/selected tab and owning profile, stops a previous tab's find, clears the previous native session when query text changes, starts the new request and stops with selection retained on dismissal. `:1319-1325` publishes only matching results for the currently selected find tab. `:1422-1426` stops find during tab close. |
| Ardia API boundary | `ThirdParty/ArdiaCore/ArdiaCore.h:203,261-262` declares `didFindMatches:active:final:`, `find:forward:` and `stopFinding`. These are Objective-C protocol methods, not `ac_*` exports. |

There is no separate selection API in Shaar's bridge. Chromium's active match is selected by find navigation; dismissal keeps that selection, while clearing the query clears it. The UI requests case-insensitive matching, wraps next/previous, and does not expose match rectangles or arbitrary page selection.

## Pinned Ardia implementation and patch dependency

The read-only pin is at `engine-333-364/build/EngineSource/source/ardia`; the synced Chromium source is at `engine-333-364/build/EngineSource/chromium_git/chromium/src`.

- `chromium_git/chromium/src/ardia/core/ardiacore_api.mm:2398-2416` implements `ArdiaCoreTab.find:forward:` and `stopFinding`. It obtains `find_in_page::FindTabHelper` for the tab's `content::WebContents`, calls `StartFinding(UTF8ToUTF16(text), forward, false, true)`, and on stop calls `StopFinding(SelectionAction::kKeep)`. Empty input to `StartFinding` follows Chromium's clear-selection path.
- `chromium_git/chromium/src/ardia/core/ac_browser.h:239-244,314-315,353` makes `TabBridge` a `FindResultObserver`, declares result/destruction hooks and stores the observed helper.
- `chromium_git/chromium/src/ardia/core/ac_browser.mm:1155-1181` lazily attaches the observer, reads `FindNotificationDetails` from the helper and forwards count, active ordinal and final-update status to the Ardia delegate; helper destruction removes the observer.
- `chromium_git/chromium/src/ardia/core/public/ArdiaCore.h:203,261-262` is the public delegate/tab contract.

No find-specific Chromium patch appears in the pinned `engine/patches/series`; find uses Chromium's existing helper and observer interfaces. The Ardia layer adds its observer/Objective-C forwarding path. The replacement should not carry those Ardia files or invent a patch dependency for find.

## Chromium APIs for Shaar's layer

Use the existing per-`WebContents` helper and observer APIs, owned by a Shaar tab-side observer/service under `chrome/browser/shaar/tabs/` (or the agreed tab implementation directory):

- `components/find_in_page/find_tab_helper.h`: `FindTabHelper::FromWebContents`, `StartFinding`, `StopFinding`, `AddObserver`/`RemoveObserver`, `find_result()`, and `OnFindTabHelperDestroyed`. The helper owns Chromium's request/session IDs and rejects obsolete renderer replies; do not duplicate its matching engine.
- `components/find_in_page/find_result_observer.h`: `FindResultObserver::OnFindResultAvailable` and helper-destruction notification.
- `components/find_in_page/find_notification_details.h`: `request_id`, `number_of_matches`, `active_match_ordinal` and `final_update` accessors. Preserve Chromium's `-1` unknown count/ordinal until a real update arrives; do not convert it to zero.
- `chrome/browser/ui/find_bar/find_bar_state.cc:20-22` is a Chromium example of creating `FindTabHelper` for a `WebContents`. Use only the helper lifecycle pattern needed for our own observer; do not import Chrome's UI state or search prepopulation policy.

Call `StartFinding(UTF8ToUTF16(query), forward, /*case_sensitive=*/false, /*find_match=*/true)` for new text and next/previous. Keep one active UI request bound to the selected tab/document in the adapter; `FindTabHelper` remains per-WebContents. For dismiss, tab switch, or replacement, invalidate the bridge's caller request token before stopping so queued old notifications cannot reach Swift. Use `StopFinding(SelectionAction::kKeep)` on dismissal to preserve the selected match; use `kClear` when the user erases the query. Remove observers safely on helper/tab destruction. No JS matching or synthetic match DOM is needed.

## Proposed `shaar_engine.h` surface

Add no new exported function, event sink, handle, or ABI version. Use the existing `shaar_submit` dispatcher, `shaar_scope`, `shaar_tab`, `shaar_request_id`, `shaar_error`, and `SHAAR_EVENT_FIND` from the shared design. Assign explicit stable enum values during consolidation; do not renumber existing IDs.

| Operation | Scope / handles | Arguments and result |
| --- | --- | --- |
| `SHAAR_OP_TAB_FIND` | Exactly one profile or private-session scope; required tab handle must belong to it and must be the selected live tab for this find UI. Both regular and private scopes are supported. | Versioned args: `{"schemaVersion":1,"query":"...","forward":true}`. Query is UTF-8, case-insensitive and may be empty only to clear the active query/selection. Request ID is the caller-generated `shaar_request_id`; accepted scheduling gets one non-inline typed completion, then zero or more `SHAAR_EVENT_FIND` result updates with that same ID. |
| `SHAAR_OP_TAB_STOP_FIND` | Same exact scope and tab validation; regular and private supported. | Versioned args: `{"schemaVersion":1,"selection":"keep"}` or `{"schemaVersion":1,"selection":"clear"}`. `keep` is dismissal/tab deactivation behavior; `clear` is empty-query behavior. Accepted stop receives one typed completion. Cancel outstanding find work best-effort and suppress its later events after the stop takes effect. |

The event remains on the one engine event stream. Every find event has `kind` and `schemaVersion`, parent `profile_id`, `session_id` when private, and the exact `tab_id`; no raw path or query text is emitted. Result payload: `{"kind":"result","schemaVersion":1,"requestID":"<decimal shaar_request_id>","matchCount":<int>,"activeMatch":<int>,"final":<bool>}`. Encode the 64-bit request ID as a decimal JSON string to avoid numeric precision loss. Keep `-1` for unknown intermediate values to match Chromium. Emit only after the Chromium state update and include intermediate/final updates as received. Event sequence is engine-monotonic. A terminal stopped event is optional; Swift already closes local UI state on stop, so do not add it unless another consumer needs it.

Return `SHAAR_INVALID_ARGUMENT` for malformed UTF-8/JSON, unknown fields, empty request ID, invalid direction/selection, or query past the documented limit; `SHAAR_NOT_FOUND` for stale tab; `SHAAR_WRONG_PROFILE` / `SHAAR_WRONG_SESSION` for scope mismatch; `SHAAR_CONFLICT` when a request ID is already outstanding; `SHAAR_NOT_READY` if the tab has no live `WebContents`; and `SHAAR_CHROMIUM_ERROR` only for an actual Chromium failure. Empty query is valid as the documented clear operation. Private find is transient and allowed, but its event must carry the private session ID; never place query or result state in profile persistence.

## Swift adapter changes

- Keep `PageFindBar`, `PageFindState`, `BrowserStore` and the user's existing keyboard/UI behavior. `PageFindState.requestID` remains the UI stale-result guard; the adapter allocates a nonzero caller-generated `shaar_request_id` per operation and keeps a scoped mapping back to the UUID for result routing. Do not truncate UUID bits to manufacture a 64-bit ID. Record profile/session/tab/document generation with the mapping.
- Add a Shaar-backed implementation in `ChromiumBridge` for `find` and `stopFinding`. Map current runtime calls in `BrowserEngine.swift:272-285` to `SHAAR_OP_TAB_FIND` / `SHAAR_OP_TAB_STOP_FIND`, passing explicit profile or private-session scope and the tab handle. Do not resolve scope from tab ID alone.
- Decode only `SHAAR_EVENT_FIND` with matching profile, session, tab, request ID and live document generation; keep existing stale-event filtering in `BrowserStore.swift:393-401`. Copy borrowed event bytes before returning from the callback and dispatch on the main/UI actor per ABI convention.
- Map typed submit errors to the existing unavailable state. Keep close, empty-query, tab-switch and navigation invalidation behavior; ensure the bridge invalidates a request before cancelling/stopping it. Do not persist find query or active match in a saved workspace.
- In the temporary dual-export migration, leave the existing Ardia adapter available behind the module selection gate; switch this module only after the find simulation and smoke checks below pass.

## Tests and acceptance checks

- **Unit:** extend `Tests/BrowserAppTests/PageFindTests.swift` for query replacement/token rejection, empty-query clear versus dismiss-keep, final/intermediate updates, invalid handles/scopes and private-session event routing. Verify the native adapter rejects wrong-profile and wrong-session calls and unknown schema fields without producing an event.
- **Engine simulation:** add a headless Chromium-backed fixture with a known repeated string. Assert initial count/active ordinal, next and previous, wraparound, case-insensitive match, zero matches, rapid query replacement suppressing stale results, empty query clearing, dismiss preserving selected match, tab close/navigation cancelling notifications, and observer teardown. Run each case in regular and private scopes; prove a private result is never delivered as regular or retained after session close.
- **Smoke:** extend `Sources/ShaarVerification/PageFindProbe.swift` (invoked by `Sources/ShaarVerification/EngineProbe.swift:672`) to exercise the same end-to-end sequence through the new ABI and native find highlight. Preserve current negative checks for inactive/mismatched profile and late results. Add an assertion for selection preservation after Done and clearing after empty query. Headless fixture content must be authored by the probe; matching itself stays in Chromium, not JS. A live keyboard/focus check is separate from the current offscreen UI capture and must not be claimed from that capture.
- **CI gate:** run focused Swift tests and the targeted headless engine simulation in source-engine CI before selecting the Shaar find adapter. No local full build, full suite, or engine build is part of this specification.

## Effort and risks

Estimate: **0.5–1 engineer-week**, consistent with phase 9 of [[Engine_Shaar_Layer_Design]], excluding Chromium source sync/build wall time. Main work is binding asynchronous Chromium notifications to caller request IDs and ensuring observer teardown/cancellation semantics across navigation and close.

Risks are stale results during rapid typing or tab/document changes; helper notifications may be intermediate and can report `-1`; keeping highlighted selection on dismiss differs from clearing on empty query; private results can be misrouted if the event omits its session ID; and observer lifetime must follow `WebContents`/`FindTabHelper` destruction. Chromium owns matching/counting/selection semantics, while Swift owns visible query/status and stale UI rejection. The existing `PageFindProbe` captures the bar offscreen, so it does not prove live keyboard focus. Native compile or a successful find simulation alone does not prove production engine integration until the new source-engine CI lane runs it.
