# Engine module: normal profiles and profile-scoped state

Scope: normal profile creation, loading, switching, deletion, directory binding, profile lifetime, and state isolation. Private sessions remain first-class ABI scopes from [[Engine_Shaar_Layer_Design]]; this module covers their parent-profile relationship and notes the current private lifecycle where it affects normal profiles. This is a module extension to the shared ABI sketch, not a second ABI. The implementation belongs in `chrome/browser/shaar/profiles/`; only declarations belong in `chrome/browser/shaar/public/shaar_engine.h`.

## Current Shaar behavior

The Swift app persists profile identities and user-facing names in its workspace/preferences models. It does not make an engine-side profile-create call: a profile identity is created by workspace/settings flows, then the engine lazily opens the corresponding Chromium profile when the browser reconciles its saved spaces. Chromium profile data uses the directory `Profile <lowercase UUID>` below the engine user-data root.

| Behavior / current API | Swift use and evidence |
| --- | --- |
| Load each distinct profile used by saved spaces; de-duplicate in-flight loads and cache loaded IDs | `BrowserEngine.swift:588-606` calls `runtime.loadProfileID`; `ChromiumBridge.mm:435-470` validates canonical UUID, queues concurrent waiters, loads by directory, rejects OTR/destroyed objects and binds profile ID to canonical path. |
| Switch the active Chromium profile for a native window, then activate the selected tab | `BrowserEngine.swift:694-700`; adapter `ChromiumBridge.mm:896-907` assigns `state.native.activeProfile` and invalidates outstanding external-app requests when changing profiles. |
| Delete profile engine state | Settings flow `BrowserSettingsController.swift:176-195` validates workspace/preferences first, explicitly loads an unused profile, revalidates, awaits the engine delete, then removes workspace/preferences metadata. `ProfilePrivacyModel.swift:20-53` adapts settings operations; `ChromiumSiteControls.mm:78-100` refuses invalid/OTR/deleting profiles, discards owned tabs and extension manager, calls engine deletion, then removes ID/path bindings. |
| Resolve profile-owned paths | `ChromiumBridge.mm:1227-1232` derives the downloads folder from the loaded profile path (`Downloads` child); extension paths are similarly rooted by profile in `ChromiumExtensions.mm`. The profile path itself is not exposed to Swift as an engine API. |
| Per-profile settings/state | `ProfilePrivacyModel.swift:20-53` exposes profile-scoped load, clear site data/cache, permission origins/get/reset, third-party-cookie get/set and deletion. `ChromiumSiteControls.mm:61-76` reads/writes profile preferences; `ChromiumEngineServices.mm` binds services to profile ID and path. Bookmarks/history/download services are registered per profile during `ChromiumBridge.mm:451-461`. |
| Private-session relationship | `ChromiumPrivateBrowsing.mm:49-50, 58-60, 106-160` leases Chromium's primary OTR profile from a loaded regular profile, refcounts contexts, validates parent/object identity, disables credential/autofill prefs and releases the OTR lease after the final context. Private context/window/tab UUIDs are tracked separately. Current `ac_engine` event labels do not carry private-session identity, so `ChromiumEngineServices.mm:118-126` drops private events. |
| Existing typed Swift model surface | Runtime failures currently become `NSError` via `ARCBridgeError` and are localized by Swift; IDs are UUID strings. Swift models distinguish profile and space: `BrowserWorkspaceStore.swift`, `BrowserPreferencesStore.swift`, and `BrowserSettingsController.swift`. Engine operation errors do not currently have a stable typed enum. |

The existing app events relevant to profile ownership are adapter callbacks, not a profile CRUD event protocol: window/tab callbacks carry a profile ID (`ChromiumBridge.h` runtime callback properties; routed by `BrowserRuntimeEvents.swift` and `BrowserRuntimeRouter.swift`). The new profile lifecycle must emit `SHAAR_EVENT_PROFILE` with `profile_id`, empty `session_id` for a regular profile, and payload `kind` values such as `created`, `loaded`, `activated`, `deleting`, `deleted`, `load_failed`, and `state_changed`. Events follow the design note's sequence ordering and occur after mutation; no path is included in an event. Private events carry their distinct session ID as required by the shared design.

## Ardia implementation being replaced

The pinned implementation is inspected read-only under `/Users/david/orca/workspaces/shaar/engine-333-364/build/EngineSource/source/ardia` and the synced Chromium tree at `/Users/david/orca/workspaces/shaar/engine-333-364/build/EngineSource/chromium_git/chromium/src`.

- Ardia's `engine/chromium/src/chrome/browser/ardia/ac_engine.cc` and `.h` own the engine/profile registry, asynchronous profile load/release/delete, and the “active profile” selection surface. `engine/ardiacore/src/ardia/core/ac_browser.mm` and `ac_browser_window.mm` adapt this to the embedded macOS browser/window lifecycle. `engine/ardiacore/src/ardia/core/ardiacore_api.mm` exposes the ObjC API and `ArdiaCoreProfile` wrapper. Shaar currently calls the resulting ObjC methods through `ChromiumBridge.mm`, not through a profile-specific `ac_*` export.
- `ChromiumBridge.mm:435-470` maps Shaar UUID to the `Profile <uuid>` directory, stores the native object in `_profiles`, and binds path-keyed services. `:896-907` changes the active native window profile. `ChromiumSiteControls.mm:78-100` performs guarded deletion and unregisters services. `ChromiumPrivateBrowsing.mm` uses `offTheRecordProfileFor:` and an adapter-owned lease/context map.
- Chromium hooks relied upon are primarily standard profile infrastructure rather than a dedicated profile patch: browser `ProfileManager` owns path lookup, async creation, attributes, keep-alives and deletion; `Profile` owns path identity, original-profile and OTR relationships, keyed services and prefs. `chromium-ardia-layer.patch` installs the Ardia integration/build hooks under Chromium; `chromium-cef-carryover.patch` includes embedded-browser teardown behavior used by profile release. No profile-specific local overlay patch is identified in the current Shaar source-build inventory. The separate `profile-download-directory.patch` is not profile CRUD; it adds downloads-directory selection and is not used by today's bridge.

This is behavior inventory only. The new code must be written independently and use Chromium interfaces; do not copy Ardia source or its implementation structure.

## Chromium APIs for the Shaar layer

Use the pinned Chromium 155 headers and browser-owned managers, with all manager access on the UI sequence:

| Need | Chromium API and header path (relative to `src/`) |
| --- | --- |
| Resolve profile by validated path; create a profile asynchronously without blocking the UI thread; observe completion | `ProfileManager::GetProfileByPath`, `ProfileManager::CreateProfileAsync`, `ProfileManagerObserver`; `chrome/browser/profiles/profile_manager.h`, observer declarations in `chrome/browser/profiles/profile_manager_observer.h`. |
| Own profile manager and application user-data root | `ProfileManager` through `g_browser_process->profile_manager()`; `chrome/browser/profiles/profile_manager.h`, `chrome/browser/browser_process.h`. The Shaar engine config supplies the absolute data root; Chromium does not choose a fallback root for this ABI. |
| Validate normal versus OTR and parent relationship | `Profile::IsOffTheRecord`, `Profile::GetOriginalProfile`, `Profile::GetPath`, `Profile::GetPrimaryOTRProfile`; `chrome/browser/profiles/profile.h`. OTR session lifecycle is defined by the shared ABI, with a stable session handle and explicit last-client close. |
| Delete profile data and preserve Chromium cleanup semantics | `ProfileManager::GetProfileAttributesStorage`, `ProfileAttributesStorage::GetProfileAttributesWithPath`, `ProfileManager::ScheduleProfileDirectoryForDeletion` (or the exact supported deletion path in this pin); `chrome/browser/profiles/profile_manager.h`, `chrome/browser/profiles/profile_attributes_storage.h`. Confirm deletion preconditions and async completion against this pin before implementation; do not recursively remove a live profile directory from Shaar code. |
| Per-profile keyed services and preferences | Resolve service from the concrete `Profile*` using the service's `GetForProfile` API; use `Profile` prefs (`GetPrefs`) for registered profile prefs. Relevant examples include `chrome/browser/history/history_service_factory.h`, `chrome/browser/bookmarks/bookmark_model_factory.h`, `chrome/browser/download/download_core_service_factory.h` and `chrome/browser/profiles/profile.h`. Pass the explicit profile handle throughout; never infer from last-used profile or a tab. |
| Profile lifetime while windows/services are active | `ScopedProfileKeepAlive` and `ScopedKeepAlive` as appropriate; `chrome/browser/profiles/keep_alive/scoped_profile_keep_alive.h`. Release only after windows, services and asynchronous replies detach. |

The API names above are present in the synced Chromium 155 headers where checked. Profile deletion and keep-alive sequencing needs a focused compile-time/API review when the implementation lands; do not promise deletion completion before Chromium reports it.

## Proposed profile additions to `shaar_engine.h`

Keep the shared design's `shaar_engine`, `shaar_profile`, `shaar_private_session`, `shaar_bytes`, `shaar_error`, `shaar_result`, `shaar_event`, `shaar_scope`, callback and threading/ownership rules unchanged. Add these profile lifecycle operations to the shared header; they fill the CRUD/path gap in its current `profile_open`/`profile_close` sketch:

```c
SHAAR_EXPORT shaar_error_code shaar_profile_create(
    shaar_engine *, shaar_bytes profile_id, shaar_bytes display_name,
    shaar_profile **out, shaar_error *error);
SHAAR_EXPORT shaar_error_code shaar_profile_open(
    shaar_engine *, shaar_bytes profile_id, shaar_bytes directory,
    shaar_profile **out,
    shaar_error *error);
SHAAR_EXPORT shaar_error_code shaar_profile_close(
    shaar_profile *, shaar_error *error);
SHAAR_EXPORT shaar_error_code shaar_profile_activate(
    shaar_profile *, shaar_window *, shaar_error *error);
SHAAR_EXPORT shaar_error_code shaar_profile_delete(
    shaar_profile *, shaar_error *error);
SHAAR_EXPORT shaar_error_code shaar_profile_get_state(
    shaar_profile *, shaar_bytes state_key, shaar_bytes *value_json,
    shaar_error *error);
SHAAR_EXPORT shaar_error_code shaar_profile_set_state(
    shaar_profile *, shaar_bytes state_key, shaar_bytes value_json,
    shaar_error *error);
SHAAR_EXPORT shaar_error_code shaar_profile_get_path(
    shaar_profile *, shaar_bytes *path, shaar_error *error);
```

Contract details:

- IDs are canonical Shaar UUIDs. `create` allocates only beneath the configured data root using the fixed `Profile <lowercase UUID>` mapping; display name belongs to profile attributes/UI metadata and is length/UTF-8 validated. It returns an async request/result under the common callback contract if Chromium creation is asynchronous. Preserve the shared sketch's `profile_open(..., profile_id, directory, ...)` signature, but treat `directory` only as a compatibility assertion: it must exactly equal the canonical relative `Profile <lowercase UUID>` path and resolve beneath the configured data root. It is never authority to select an arbitrary path. Open is idempotent for an already-open ID.
- `activate` is explicit per target window, requires an open regular profile, and returns `WRONG_PROFILE`, `NOT_FOUND` or `NOT_READY` as appropriate. Window/profile affinity and callback sequencing follow the common handle rules. Switching does not change workspace selection metadata; Swift remains its authority.
- `delete` requires the profile to be open so ownership can be checked, marks it deleting, rejects new operations, and fails with typed `CONFLICT` while any private session lease, window, tab, keep-alive or in-flight operation still refers to it. On success it emits ordered `deleting` then `deleted`, invalidates the handle after the callback/event ordering rule, and schedules Chromium profile data removal through `ProfileManager::GetDeleteProfileHelper().MaybeScheduleProfileForDeletion`; do not directly remove a live profile directory. The completion contract must reflect Chromium's scheduling/completion semantics. Failed scheduling clears the deleting state and preserves the profile and bindings.
- Profile directories are derived from engine `data_root`, UUID mapping and Chromium `Profile::GetPath`; never accept a path from Swift as authority. `get_path` is an internal adapter facility for path-derived downloads/extensions, returns an absolute canonical path only to the caller, and must not place it in logs/events/errors. Consider replacing this with narrow engine directory APIs as adjacent modules migrate.
- `get_state`/`set_state` are restricted to a documented, versioned allowlist of small profile preferences needed by current Swift controls. They are not a generic preference key/value escape hatch. Unknown keys return `INVALID_ARGUMENT`; unsupported policy writes return `POLICY_BLOCKED`. Bookmark/history/download state stays in the service APIs owned by their modules. State changes emit `state_changed` only after a verified effective mutation.
- Use ABI `shaar_error_code` values (`INVALID_ARGUMENT`, `NOT_FOUND`, `WRONG_PROFILE`, `PRIVATE_DISALLOWED`, `CONFLICT`, `IO_ERROR`, `CHROMIUM_ERROR`, `SHUTTING_DOWN`); keep localized UI text in Swift. Replies and event payloads include stable `profile_id`; private scope uses both parent profile and unique `session_id` under the shared design.

Swift adapter changes: replace runtime loading with a small profile handle registry keyed by UUID; call `create/open/close/activate/delete`, copy callback bytes before returning from the C callback, map typed codes to `ARCChromiumRuntime`-facing Swift errors, and dispatch `SHAAR_EVENT_PROFILE` through the existing `BrowserRuntimeRouter`/`BrowserRuntimeEvents` facade. Keep `BrowserEngine`'s current lazy-load reconciliation and activation order. `BrowserSettingsController` continues to validate and move workspace references before engine deletion and persists preference/workspace removal only after successful engine completion. Replace `downloadsDirectory(forProfileID:)`'s raw path dependency with a profile-owned directory API when download-directory work lands. Update `EngineProfileSettings` and tests without exposing C handles to SwiftUI models. Private windows create/close a `shaar_private_session` associated with the parent handle; a regular profile cannot be deleted until all session leases have ended.

## Tests and parity gates

- **Unit tests:** UUID/path mapping and traversal rejection; deterministic path under data root; idempotent concurrent opens and waiter completion; create/open/close state machine; typed errors for malformed ID, unknown/deleting profile, wrong profile/window, shutdown and OTR misuse; scoped preference allowlist; deletion rollback on Chromium failure; handle invalidation exactly once; keep-alive and private-session refcount barriers; event sequence, profile/session IDs and no path leakage.
- **Engine simulation tests:** Fake `ProfileManager`/profile factory with delayed and reordered callbacks; same profile requested by two windows; different profiles with isolated prefs/bookmarks/history/download directories; activate switches only the requested window; failed load leaves no service/path binding; delete refuses a live tab/window/private lease and succeeds after closure; shutdown cancels pending create/load/delete; event delivery occurs after state mutation. Add profile switches to the existing headless engine fixture without a Chromium build on developer machines.
- **Smoke checks:** In source-engine CI, create two profiles, write distinct preference and cookie/bookmark state, load each from its deterministic directory, switch profiles in one window and verify origin/sign-in state separation, restart and verify persistence, then delete one and verify the other remains intact. Open two private windows for one parent, verify they share only that parent's temporary OTR state, close one without destroying the other's context, close the final one and verify teardown; ensure private sessions cannot create/open persistent profile paths or persist profile state. Probe events for correct IDs and absence of filesystem paths. Exercise failed load/delete and a normal quit with outstanding profile work.

These gates establish behavior; compilation alone does not establish profile isolation or safe deletion. Keep the normal prebuilt-engine lane unchanged until a built source engine passes the module probes as defined by the shared migration sequence.

## Effort and risks

Estimate: **2–3 engineer-weeks** for profile CRUD/lifetime/path binding and adapter migration, plus **1–2 weeks** for private-session wiring where not already delivered by its own module. Excludes Chromium source build/sync wall time and shared ABI scaffolding.

Main risks are asynchronous ProfileManager startup and deletion semantics, safely quiescing windows/services/keep-alives before deleting profile data, stable UUID-to-path compatibility with existing user data, path exposure through convenience APIs, keyed-service isolation, and private-session lease teardown. Preserve the existing directory mapping and `Ardia Safe Storage` keychain identity until data migration is separately tested. The current Swift deletion workflow deliberately preflights workspace references and revalidates after loading; retain that order so a failed engine deletion cannot erase user metadata. No local engine build or runtime parity claim is made by this specification.
