# Shaar engine module: downloads (#288)

Status: phase 2 module proposal for [[Engine_Shaar_Layer_Design]]; Chromium pin 155.0.8059.84. This note is a fresh design based on the current Shaar call sites and the pinned read-only source. It does not propose carrying Ardia implementation into the Shaar layer. The ABI types, `shaar_scope`, `shaar_submit`, `shaar_event`, and `shaar_error_code` below are the ones defined by the shared layer design; this module adds operation schemas and behavior only.

## Current Shaar surface

Swift imports `ChromiumBridge` and consumes `ARCChromiumRuntime`, never the Ardia C header directly. In the current adapter, `ChromiumEngineServices.mm:45-57` resolves these required exports:

| Current engine call | Swift use |
| --- | --- |
| `ac_downloads_list` | `BrowserEngine.swift:605-611` refreshes after profile load while Chromium's download history initializes; `BrowserStore.swift:280,343` refreshes when the user opens Downloads. Initial restoration is requested from `ChromiumBridge.mm:457-463`. |
| `ac_downloads_pause`, `ac_downloads_resume`, `ac_downloads_cancel`, `ac_downloads_remove` | `BrowserEngine.swift:246-254` forwards actions from `DownloadsModel` using the selected profile and download ID. `ChromiumDownloads.mm:41-64` validates the command and translates its response. |

`ac_downloads_keep` exists in the Ardia header but Shaar does not resolve or use it. Directory get/set exports exist only in the Shaar source-build overlay patch, not the shipped engine ABI, and the bridge does not resolve them. `ChromiumBridge.mm:1227-1232` derives a displayed default folder as `<profile path>/Downloads`; it does not ask Chromium for the effective download path.

Current events are `downloads.changed` and `downloads.removed`, selected in `ChromiumEngineServices.mm:27-31,118-126`. `ChromiumDownloads.mm:66-74` decodes the payload, `ChromiumBridge.mm:153-172` forwards callbacks, and `BrowserRuntimeEvents.swift:146-159` distributes them to clients for that profile. The list result is `{downloads: [...]}`. Each record has `id`, `url`, `filename`, `path`, `state`, `paused`, `received`, `total`, `speed`, `mimeType`, `dangerous`, `error`, `offTheRecord`, and `startTime` (`DownloadsModel.swift:157-169` decodes the fields it needs). `BrowserCore/BrowserDownload.swift:7-25,28-50` defines `DownloadState`, `DownloadAction`, and the validated `BrowserDownload` value. Its initializer rejects private records (`offTheRecord == true`, lines 28-38); controls are exposed according to state and danger (`60-67`).

Private downloads are currently not a usable Swift feature: Ardia watches regular and OTR managers, but events are associated with the parent profile and mark OTR in the payload; the ObjC service drops events whose `offTheRecord` flag is true (`ChromiumEngineServices.mm:118-126`), and the Swift decoder rejects OTR list rows. The Shaar ABI must carry the private session ID in the event envelope and scope calls explicitly. Private state remains ephemeral and separate from regular profile downloads.

The Settings UI currently stores the chosen folder only in `BrowserPreferencesStore` (`40-52, 121-130, 215-225, 267-268`), and displays it ahead of the derived default (`BrowserSettingsController.swift:36-46`, `BrowserSettingsView.swift:500-521`). `BrowserEngine.swift:113-116` also gives this Swift preference to `DownloadsModel` for folder listing. That app preference is not currently applied to Chromium's `DownloadPrefs`; consequently a displayed custom folder can diverge from the destination Chromium uses. The source-build-only `profile-download-directory.patch` is the only current code that changes Chromium's per-profile path.

Relevant app data types and adapter files:

- `Sources/BrowserCore/BrowserDownload.swift:7-67`: public state/action enums and download record semantics.
- `Sources/ArcusisBrowser/DownloadsModel.swift:10-29,31-58,103-130,157-170`: profile-keyed browser records, library folder merge, restore/update/remove, guarded controls and record decoding.
- `Sources/ArcusisBrowser/DownloadsFolderSource.swift:10-55`: scans a directory for completed local files and monitors changes.
- `Sources/ArcusisBrowser/BrowserPreferencesStore.swift:39-53`: currently persisted per-profile folder override.
- `Sources/ArcusisBrowser/BrowserSettingsController.swift:36-46,120-141`: profile folder selection/reset and displayed default.
- `Sources/ChromiumBridge/ChromiumDownloads.mm:18-75`, `ChromiumEngineServices.mm:27-31,45-57,118-126`, `ChromiumBridge.mm:153-174,457-463,969-985,1227-1232`: ObjC service/ABI and runtime callback routes.
- `Sources/ArcusisBrowser/BrowserEngine.swift:246-270,605-611,723-744` and `Sources/ArcusisBrowser/BrowserRuntimeEvents.swift:146-159`: Swift controls, event routing, restoration, and validated open/reveal action.

## Pinned Ardia behavior and Chromium hooks

Read-only reference: `/Users/david/orca/workspaces/shaar/engine-333-364/build/EngineSource/source/ardia/engine/chromium/src/chrome/browser/ardia/ac_downloads.cc` and `ac_downloads.h`; source-build overlay: `ThirdParty/ArdiaCore/patches/profile-download-directory.patch` in this checkout. These paths are evidence only; do not copy their implementation.

The pinned `ac_downloads.cc` behavior is:

- A profile-owned `DownloadsState` attaches `download::AllDownloadItemNotifier` observers to the regular profile and its OTR profiles. It lists each observed manager's `DownloadItem`s, filters transient and extension-installer items, sorts newest first, and looks up IDs by GUID within the watched managers.
- Changes are posted asynchronously. Progress updates are throttled to 100 ms unless pause/danger state changes. It emits `downloads.changed` after an item has entered progress; removal emits `downloads.removed`. Destruction of an OTR profile drops that observer and removes its listed items.
- The record is derived from `DownloadItem` and reports target path (falling back to full path), displayed filename, original URL, state, pause state, byte counts, speed, MIME type, danger/insecure state, interrupt reason, OTR flag, and start time.
- Pause/resume/cancel/remove look up by GUID. Resume checks `CanResume`; remove rejects a nonterminal item. Cancel and resume are marked as user actions. Missing IDs produce an error. The app's current controls do not expose keep/validate-dangerous.

Chromium facilities the implementation hooks are first-party and do not require an Ardia patch: `content::BrowserContext::GetDownloadManager()` (`content/public/browser/browser_context.h`), `content::DownloadManager`'s inherited `download::SimpleDownloadManager::GetAllDownloads` / `GetDownloadByGuid` (`components/download/public/common/simple_download_manager.h`), `download::AllDownloadItemNotifier` and its created/updated/removed observer callbacks (`components/download/content/public/all_download_item_notifier.h`), and the item accessors/actions (`components/download/public/common/download_item.h`). Folder selection uses `DownloadPrefs::FromBrowserContext`, `DownloadPath`, `SetDownloadPath`, and `IsDownloadPathManaged` (`chrome/browser/download/download_prefs.h/.cc`) plus `prefs::kDownloadDefaultDirectory` and `prefs::kSaveFileDefaultDirectory` (`chrome/common/pref_names.h`).

The source-only `profile-download-directory.patch` adds `ac_downloads_directory_get/set` around Chromium `DownloadPrefs`. It rejects OTR/shutdown/policy-managed profiles, checks user-modifiable prefs and existing writable absolute paths, compares effective and stored paths, updates both download and save-file directories, and rolls back on rejected changes. It also adds structured error strings to Ardia `Call`/`Reply`. Shaar should reproduce these product requirements with its own ABI and implementation, not apply or port the patch text. Chromium's existing `DownloadPrefs` API is the authority; do not retain a parallel Swift path as if it were effective.

## Chromium 155 facilities for the Shaar layer

Paths below are relative to the synced Chromium root `/Users/david/orca/workspaces/shaar/engine-333-364/build/EngineSource/chromium_git/chromium/src`.

| Need | Chromium API and source paths |
| --- | --- |
| Enumerate and target one profile's downloads | `content::BrowserContext::GetDownloadManager()` in `content/public/browser/browser_context.h`; the returned `content::DownloadManager` inherits `download::SimpleDownloadManager::GetAllDownloads` and `GetDownloadByGuid` from `components/download/public/common/simple_download_manager.h`. Bind the `shaar_profile`'s exact `Profile*`, never search another manager or infer scope from a GUID. |
| Observe create/progress/removal | `download::AllDownloadItemNotifier` in `components/download/content/public/all_download_item_notifier.h` and observer `OnDownloadCreated/Updated/Removed`. Post after mutation through the engine's UI-thread event dispatcher and coalesce progress without suppressing terminal, pause, or danger transitions. |
| Serialize records and control | `download::DownloadItem` in `components/download/public/common/download_item.h`: `GetGuid`, `GetState`, `GetLastReason`, `IsPaused`, `CanResume`, `IsDone`, `Pause`, `Resume`, `Cancel`, `Remove`, `GetOriginalUrl`, `GetTargetFilePath`, `GetFullPath`, `GetFileNameToReportUser`, `GetTotalBytes`, `GetReceivedBytes`, `CurrentSpeed`, `GetStartTime`, `IsTransient`, `GetDownloadSource`, `IsDangerous`, `IsInsecure`. Keep Chromium enum/state mapping explicit and use the target path for active downloads; do not treat `GetFullPath()` as a stable target (the header documents it as an intermediate path). |
| Apply and read profile directory | `chrome/browser/download/download_prefs.h/.cc` (`DownloadPrefs::FromBrowserContext`, `DownloadPath`, `SetDownloadPath`, `IsDownloadPathManaged`) and `chrome/common/pref_names.h` download/save-file prefs. Validate exact profile, shutdown, policy/modifiability, path normalization/existence/writability, and Chromium's effective result. Persist through `DownloadPrefs`/`PrefService`, not app-only metadata. |
| Avoid internal downloads | `chrome/browser/download/download_crx_util.h` and `extensions/browser/webstore_installer.h` for extension-install/trusted downloads, alongside `DownloadItem::IsTransient` and `GetDownloadSource`. Match product exclusions deliberately; don't expose install artifacts in the user's Downloads list. |
| Map interrupt diagnostics | `components/download/public/common/download_interrupt_reasons.h` (`DownloadInterruptReasonToString`) for a diagnostic reason. Return typed operation errors separately from per-item failure state. |

All profile manager observation, lookup, control, and preference operations run on Chromium's UI sequence. Observer lifetime must be owned by the Shaar profile service and detached before profile/session teardown. Check the manager's initialization state before interpreting an empty enumeration as no downloads; Swift currently retries refresh after profile load because download history initializes asynchronously.

## `shaar_engine.h` module contract

Keep the design's single exported `shaar_submit` entry point and `SHAAR_OP_DOWNLOAD_LIST`, `SHAAR_OP_DOWNLOAD_CONTROL`, and `SHAAR_OP_DOWNLOAD_DIRECTORY` operation IDs. Do not add `ac_*`-shaped exports or a second callback convention. Each call supplies exactly one `shaar_scope`: either a regular `shaar_profile` or one of its explicit `shaar_private_session` handles. Reject mismatched/closed handles, cross-profile download IDs, unknown action values, and a directory operation scoped to a private session.

Proposed operation contracts (`args_json` / successful `payload_json`, all versioned):

| Operation | Arguments and result |
| --- | --- |
| `SHAAR_OP_DOWNLOAD_LIST` | Args `{ "schemaVersion": 1 }`. Result `{ "schemaVersion": 1, "downloads": [DownloadRecord] }`, newest first. |
| `SHAAR_OP_DOWNLOAD_CONTROL` | Args `{ "schemaVersion": 1, "downloadId": "<Chromium GUID>", "action": "pause" | "resume" | "cancel" | "remove" }`. Empty success payload is acceptable. Resume when `CanResume()` is false returns `SHAAR_CONFLICT`; removing a nonterminal item returns `SHAAR_CONFLICT`; unknown or foreign ID returns `SHAAR_NOT_FOUND`. Repeated pause/cancel may be idempotent if state permits; document the decision in implementation and test it. |
| `SHAAR_OP_DOWNLOAD_DIRECTORY` | Args `{ "schemaVersion": 1, "action": "get" }`, `{ "schemaVersion": 1, "action": "set", "directory": "/absolute/path" }`, or `{ "schemaVersion": 1, "action": "useDefault" }`; result `{ "schemaVersion": 1, "directory": "/effective/path" }`. Set only a normalized absolute existing writable directory accepted by Chromium. No process-wide environment override. |

`DownloadRecord` retains the current fields needed for parity: `id`, `url`, `filename`, `path`, `state` (`downloading`, `finished`, `cancelled`, `failed`), `paused`, `received`, `total` (`-1` unknown), `speed`, `mimeType`, `dangerous`, nullable diagnostic `error`, and `startTime` (Unix milliseconds). Add `offTheRecord` only as a compatibility field if Swift needs staged migration; authoritative scope is `shaar_event.profile_id/session_id` and the supplied `shaar_scope`. Do not encode a filesystem profile path in identity fields. A download target path remains in the record because the existing client uses it to open/reveal a finished file; Swift must still canonicalize it and ensure it is inside the effective profile download directory before opening/revealing.

Use the shared `shaar_error` for typed failures, not `{ "error": "..." }` success-shaped results. Map malformed JSON/fields to `SHAAR_INVALID_ARGUMENT`; unsupported directory mutation under managed policy to `SHAAR_POLICY_BLOCKED`; inaccessible or rejected filesystem paths to `SHAAR_IO_ERROR` (or a consistently selected typed path code); wrong profile/session to `SHAAR_WRONG_PROFILE` / `SHAAR_WRONG_SESSION`; unavailable or closed profile to `SHAAR_NOT_READY` / `SHAAR_SHUTTING_DOWN`; invalid action state to `SHAAR_CONFLICT`; and a download absent from the supplied manager to `SHAAR_NOT_FOUND`. Keep localized user-facing copy in Swift; `message` is diagnostic.

Emit `SHAAR_EVENT_DOWNLOAD` on the shared ordered event stream. For every event set `profile_id` to its Shaar UUID; set `session_id` empty for a regular profile and to the private-session UUID for OTR. Payloads use `schemaVersion: 1` and one of `{ "change": "upsert", "download": DownloadRecord }` or `{ "change": "remove", "downloadId": "..." }`. Events update state after Chromium mutation and are delivered asynchronously, never inline. Do not leak OTR events into regular caches or persistence. Private downloads are scoped to their private session, listable/controllable only through that handle, ephemeral, and removed from Swift when the session closes; do not restore them from regular download history or merge them into the profile Library. If Chromium shares an OTR manager with the parent in a way that cannot enforce this contract, reject the operation with a typed error until the engine creates a correctly scoped OTR route.

For directory state, make the Chromium regular-profile pref the source of truth. `get` reports the effective directory or a typed unavailability/policy result, never a fabricated `<profile>/Downloads`. `set` verifies managed and user-modifiable prefs before mutation, writes the download path (and the save-file path if Chromium's destination behavior requires parity), then reads back effective and stored values. Roll back both prior prefs if Chromium rejects the requested path. Reset is a `set` action with `useDefault: true` (instead of a stale Swift-only override) and reports Chromium's effective default. Private sessions cannot change a parent profile's location.

## Swift adapter migration

`ChromiumBridge` remains the Swift-facing adapter module; replace `ChromiumEngineServices`' `dlsym(ac_...)` table with the common Shaar ABI loader and route all three download operation IDs through `shaar_submit`. Translate `shaar_error_code` to a typed Swift `EngineError` and localized download messages; copy callback data before returning from C. Use request IDs and reject late callbacks after profile/session teardown.

Keep `DownloadsModel`'s UI-facing `DownloadState`, `DownloadAction`, record identity, sorting, and file safety behavior where compatible. Change model identity/cache keys from profile-only to `(profileID, optional privateSessionID)` for engine events and ephemeral private views. Ensure private data is not serialized or shared with regular clients; close clears session rows. Route control using the current profile/session scope, with the download GUID only as the item key. Preserve cross-window delivery to all clients attached to the same scope.

Replace `BrowserPreferencesStore` as the authority for the download destination with the directory operation. `BrowserSettingsController` should call `get` for display, `set` when the folder picker returns, and `useDefault` for reset; show typed policy/access errors and update settings only after engine acknowledgement. `DownloadsModel`'s folder scanner should receive the engine-reported effective directory. Keep local app preferences only if product intentionally wants a separate *requested* choice, and never report that value as active until Chromium confirms it. `BrowserEngine.revealDownload` must validate the record's canonical target against the same effective directory before passing it to `NSWorkspace`.

## Parity tests and smoke checks

| Layer | Required evidence |
| --- | --- |
| C++ unit tests | Record mapping for each Chromium state, unknown total and empty target path; newest-first ordering; exclusions for transient and extension installer downloads; coalescing progress while retaining pause/danger/terminal transitions; observer detach on profile/session destruction; foreign GUID isolation; controls in allowed/disallowed states; DownloadPrefs managed, missing, unwritable, relative, parent-traversal, rejected-setting and rollback cases; reset returns Chromium's effective default. |
| Engine simulation / headless fixture | Two regular profiles with overlapping lifecycle and same actions; create/start/pause/resume/cancel/complete/remove event ordering; list after history initialization and restart; verify remove only removes history entry/file semantics matching `DownloadItem::Remove`; ensure two adapter clients see the same profile update. Private session tests assert distinct session IDs, no regular-profile cache/persistence leakage, session-only list/control, and cleanup on session close. |
| Adapter/model tests | Decode every record field and typed error; ignore malformed/stale replies; scope events to the right profile/session; private cache teardown; picker set/reset acknowledgement; scanner follows effective path; refusal to reveal paths outside that directory. |
| Smoke checks on the built engine | Headless end-to-end fixture initiates an authored HTTP download, checks list/progress and a terminal event, pauses/resumes a controllable fixture, cancels another, removes a completed item while checking documented file behavior, verifies persisted list after engine restart, selects a distinct folder for each regular profile and confirms actual file destinations, then tests default reset. Include private download isolation and teardown. Compare the public Swift-visible behavior to today's state/actions/record fields and folder/library view; test the legacy prebuilt adapter lane independently until the source-engine lane passes. |

Do not treat a Swift compile, synthetic event, or directory getter alone as parity. Normal CI/prebuilt-engine behavior remains the default until the headless source-engine fixture and the relevant Swift model tests pass.

## Effort and risks

Keep the shared design estimate for migration row 6: **2–3 engineer-weeks**, excluding Chromium source sync/build wall time. This includes the profile-owned service and observer lifetime, schema/error implementation, directory policy, Swift adapter/model changes, and fixture coverage.

Main risks are private `DownloadManager` ownership/history semantics, profile shutdown racing observer callbacks, downloads whose target path is not yet selected, event flooding or reordered terminal notifications, policy-controlled download directories, and accidental mismatch between the settings UI, Chromium's effective destination, and file reveal validation. Chromium's `DownloadItem::Remove()` removes the record from views/history and may delete an in-progress/interrupted temporary file; it is not the same as deleting a completed downloaded file. Preserve and explicitly test that distinction. The list's path field is sensitive local filesystem data but needed by current file actions; keep it confined to the scoped engine event/call and do not emit profile paths or use a path as a profile identifier.
