# Shaar Chromium layer design for issue #418

Status: phase 2 design, 2026-11-03. No engine build or runtime claim is made here. This is a fresh interface design informed by [[Engine_Ardia_Inventory]], [[Engine_Interop_Boundary]], [[Private_Browsing]], [[Engine_Source_Build]], and the Swift `ChromiumBridge` adapter. The target is Chromium 155 + pinned ungoogled Chromium + reviewed Shaar changes, with no Ardia source cloned, staged, patched or linked in the final engine.

## Placement and ownership

Place the new implementation under `chrome/browser/shaar/` in the Chromium checkout: `public/shaar_engine.h` (the only exported ABI), `engine/` (launch, run loop, handles, event dispatcher), `profiles/`, `windows/`, `tabs/`, `services/` (downloads, bookmarks, history, site settings/data), `extensions/`, `devtools/`, `media/`, and `mac/` (Objective-C++ AppKit host). GN targets should export only the C functions in the public header from `chrome_framework`; no Chromium C++ object crosses the boundary. The one macOS UI exception is a borrowed `NSView *` returned as `void *`, which the ObjC bridge casts and never releases. A tiny `content/renderer` companion is acceptable only for page/frame hooks that cannot be hosted in `chrome/browser/shaar/`, with explicit GN deps and source ownership.

The Swift package keeps `ChromiumBridge` as its adapter module. It loads the framework, checks the ABI, owns opaque handles, converts the single event stream to existing Swift callbacks/models, and hands a borrowed `NSView *` to existing AppKit windows. The engine owns Chromium `Profile`, `Browser`, `WebContents`, and embedded native host objects. The adapter owns Shaar IDs, SwiftUI/AppKit shell state, permissions/consent presentation, and durable workspace metadata. The engine must not infer a profile from a tab, download or bookmark ID when an operation supplies a profile/session scope.

## Proposed `shaar_engine.h` (ABI v1)

This is an interface sketch to review before implementation. All strings/byte slices supplied by callers are UTF-8, length-delimited and borrowed for the duration of a call; the engine copies input needed later. `shaar_result` and event payload slices are borrowed until the callback returns; synchronous error text is borrowed until the next ABI call and must be copied immediately. Swift copies anything it keeps. Handles are opaque and invalid after explicit close/release or engine shutdown. All entry points and callbacks are serialized on the Chromium UI thread; asynchronous callbacks are delivered later, never inline. No C++ exceptions cross the ABI.

```c
#ifndef SHAAR_ENGINE_H_
#define SHAAR_ENGINE_H_
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
#define SHAAR_ENGINE_ABI_MAJOR 1u
#define SHAAR_ENGINE_ABI_MINOR 0u
#define SHAAR_EXPORT __attribute__((visibility("default")))

typedef struct shaar_engine shaar_engine;
typedef struct shaar_profile shaar_profile;
typedef struct shaar_private_session shaar_private_session;
typedef struct shaar_window shaar_window;
typedef struct shaar_tab shaar_tab;
typedef struct { const char *data; size_t size; } shaar_bytes;
typedef uint64_t shaar_request_id;

typedef enum {
  SHAAR_OK = 0, SHAAR_INVALID_ARGUMENT, SHAAR_UNSUPPORTED_ABI,
  SHAAR_NOT_READY, SHAAR_NOT_FOUND, SHAAR_WRONG_PROFILE,
  SHAAR_WRONG_SESSION, SHAAR_PRIVATE_DISALLOWED, SHAAR_POLICY_BLOCKED,
  SHAAR_PERMISSION_DENIED, SHAAR_CONFLICT, SHAAR_CANCELLED,
  SHAAR_IO_ERROR, SHAAR_CHROMIUM_ERROR, SHAAR_SHUTTING_DOWN
} shaar_error_code;
typedef struct {
  uint32_t size;                 /* sizeof(shaar_error) supplied by caller */
  shaar_error_code code;
  int32_t platform_code;         /* errno/Chromium code when relevant; else 0 */
  shaar_bytes message;           /* diagnostic, not UI copy; borrowed */
} shaar_error;
typedef struct {
  uint32_t size;                 /* sizeof(shaar_result) */
  shaar_request_id request_id;
  shaar_error error;
  shaar_bytes payload_json;      /* versioned operation result, UTF-8 */
} shaar_result;
typedef void (*shaar_reply_fn)(void *context, const shaar_result *result);

typedef enum {
  SHAAR_EVENT_ENGINE, SHAAR_EVENT_PROFILE, SHAAR_EVENT_PRIVATE_SESSION,
  SHAAR_EVENT_WINDOW, SHAAR_EVENT_TAB, SHAAR_EVENT_NAVIGATION,
  SHAAR_EVENT_FIND, SHAAR_EVENT_PERMISSION, SHAAR_EVENT_DOWNLOAD,
  SHAAR_EVENT_BOOKMARK, SHAAR_EVENT_HISTORY, SHAAR_EVENT_SITE_DATA,
  SHAAR_EVENT_EXTENSION, SHAAR_EVENT_DEVTOOLS, SHAAR_EVENT_MEDIA
} shaar_event_kind;
typedef struct {
  uint32_t size;                 /* sizeof(shaar_event) */
  uint64_t sequence;             /* monotonic within this engine instance */
  shaar_event_kind kind;
  shaar_bytes profile_id;        /* Shaar UUID; never a filesystem path */
  shaar_bytes session_id;        /* empty for regular; UUID for private */
  shaar_bytes window_id;         /* empty if event is profile-wide */
  shaar_bytes tab_id;            /* empty if event is not tab-scoped */
  shaar_bytes payload_json;      /* kind + schemaVersion in payload */
} shaar_event;
typedef void (*shaar_event_fn)(void *context, const shaar_event *event);

typedef struct {
  uint32_t size;                 /* sizeof(shaar_config) */
  uint32_t requested_major;
  uint32_t requested_minor;
  shaar_bytes data_root;         /* absolute, validated; no implicit default */
  shaar_bytes locale;
  shaar_event_fn on_event;       /* exactly one stream for this engine */
  void *event_context;
} shaar_config;
SHAAR_EXPORT uint32_t shaar_abi_major(void);
SHAAR_EXPORT uint32_t shaar_abi_minor(void);
SHAAR_EXPORT shaar_error_code shaar_engine_create(
    const shaar_config *, shaar_engine **out, shaar_error *error);
SHAAR_EXPORT shaar_error_code shaar_engine_run(shaar_engine *, shaar_error *error);
SHAAR_EXPORT shaar_error_code shaar_engine_request_quit(shaar_engine *, shaar_error *error);
SHAAR_EXPORT void shaar_engine_release(shaar_engine *);

SHAAR_EXPORT shaar_error_code shaar_profile_open(
    shaar_engine *, shaar_bytes profile_id, shaar_bytes directory,
    shaar_profile **out, shaar_error *error);
SHAAR_EXPORT shaar_error_code shaar_profile_close(shaar_profile *, shaar_error *error);
SHAAR_EXPORT shaar_error_code shaar_private_session_open(
    shaar_profile *, shaar_bytes session_id, shaar_private_session **out,
    shaar_error *error);
SHAAR_EXPORT shaar_error_code shaar_private_session_close(
    shaar_private_session *, shaar_error *error);

/* Exactly one scope is set: regular profile or its private session. */
typedef struct {
  uint32_t size;
  shaar_profile *profile;
  shaar_private_session *private_session;
} shaar_scope;
SHAAR_EXPORT shaar_error_code shaar_window_open(
    shaar_scope, shaar_bytes window_id, shaar_window **out, shaar_error *error);
SHAAR_EXPORT shaar_error_code shaar_window_close(shaar_window *, shaar_error *error);
SHAAR_EXPORT void *shaar_window_host_view(shaar_window *); /* borrowed NSView* on macOS */
SHAAR_EXPORT shaar_error_code shaar_tab_open(
    shaar_window *, shaar_bytes tab_id, shaar_bytes url,
    shaar_tab **out, shaar_error *error);
SHAAR_EXPORT shaar_error_code shaar_tab_close(shaar_tab *, shaar_error *error);

typedef enum {
  SHAAR_OP_TAB_NAVIGATE, SHAAR_OP_TAB_GO, SHAAR_OP_TAB_RELOAD,
  SHAAR_OP_TAB_FIND, SHAAR_OP_TAB_STOP_FIND, SHAAR_OP_TAB_EVALUATE,
  SHAAR_OP_WINDOW_ACTIVATE_TAB, SHAAR_OP_WINDOW_PLACE_TABS,
  SHAAR_OP_DOWNLOAD_LIST, SHAAR_OP_DOWNLOAD_CONTROL, SHAAR_OP_DOWNLOAD_DIRECTORY,
  SHAAR_OP_BOOKMARK_TREE, SHAAR_OP_BOOKMARK_APPLY,
  SHAAR_OP_HISTORY_QUERY, SHAAR_OP_HISTORY_INSERT, SHAAR_OP_HISTORY_DELETE,
  SHAAR_OP_SITE_SETTINGS_GET, SHAAR_OP_SITE_SETTINGS_SET,
  SHAAR_OP_SITE_SETTINGS_RESET, SHAAR_OP_SITE_DATA_CLEAR,
  SHAAR_OP_BROWSING_DATA_CLEAR, SHAAR_OP_EXTENSION_LIST,
  SHAAR_OP_EXTENSION_MANAGE, SHAAR_OP_EXTENSION_ACTION,
  SHAAR_OP_DEVTOOLS_CALL, SHAAR_OP_MEDIA_CONTROL
} shaar_operation;
SHAAR_EXPORT shaar_error_code shaar_submit(
    shaar_engine *, shaar_scope, shaar_window *, shaar_tab *,
    shaar_operation, shaar_bytes args_json, shaar_request_id,
    shaar_reply_fn, void *reply_context, shaar_error *immediate_error);
SHAAR_EXPORT shaar_error_code shaar_cancel_request(
    shaar_engine *, shaar_request_id, shaar_error *error);
#ifdef __cplusplus
}
#endif
#endif
```

`shaar_submit` is a versioned dispatch point, not a license to use unvalidated string methods: operation IDs are compile-time enums, and each operation has a documented JSON schema, allowed scopes/handles and typed result. Reject unknown fields where they might weaken ownership or permissions. A call checks that the supplied window/tab belongs to the supplied scope; no fallback to the default or most-recent profile. `SHAAR_OP_HISTORY_INSERT` is reserved for #299, `SHAAR_OP_DOWNLOAD_DIRECTORY` for exact profile get/set, and site settings/data for #289. Each operation either reports `SHAAR_OK` in its async result or a typed error; no success-shaped empty response. The adapter maps typed errors to localized Swift errors.

The event stream is registered once at engine creation. Every **profile-scoped** event has a regular profile ID and, for OTR, a separate private session ID; only engine-wide events may have an empty profile ID. Private events are never labeled solely with the parent profile. Events are ordered by sequence and dispatched after state mutation, with a final close event before handle invalidation. The adapter never treats an event without an expected scope/ID as a regular-profile event. Requests carry caller-generated IDs for cancellation and stale-result rejection. Prompt requests carry event IDs, target handles and an expiry; replies use a dedicated typed operation added with that module. Never emit secrets or raw profile paths in events. Page scripts and DevTools commands are restricted by allowlisted capabilities rather than arbitrary remote access.

`shaar_engine_create` checks major version and struct sizes; minor versions may append fields and enum members. A newer engine must accept smaller known structs and ignore appended fields it does not understand only when negotiated minor permits it. Framework exports are checked at load and recorded in source-build receipts. At shutdown, cancel outstanding requests, emit close events, detach borrowed views, invalidate handles, then release callbacks. `shaar_engine_run` owns the same AppKit run loop boundary the existing adapter expects; the bridge keeps its startup and quit callback facade until Swift is migrated.

## Build runner and packaging path

The final runner should use a new Shaar-owned config, e.g. `ThirdParty/ChromiumEngine/source-build.json`, pinning Chromium, ungoogled/macOS, depot_tools, Siso, toolchain and Shaar patch/layer digests. `scripts/build-engine-source.py` retains owner-only ignored output, exact revision/tree checks, path guards, cache isolation, timeouts, job limits, free-space floor, recovery logs, framework hashes and exported-ABI receipt. It no longer clones `mantrakp04/ardia`, verifies Ardia's engine tree, stages Ardia scripts, invokes `series.py`, copies either Ardia layer, or applies `profile-download-directory.patch`. Replace those stages with Shaar-maintained scripts: pinned Chromium sync, ungoogled patches/domain substitution, ordered **Shaar-owned** patches, Shaar layer copy/verification, GN generation and `chrome_framework` build. Keep the `chrome_framework` target/name initially; framework renaming is a separate packaging decision.

The runner replacement is a **new output generation**, not an in-place reinterpretation of an old `build/EngineSource/receipt.json`. Existing receipts bind the Ardia source, its script substitutions and patch hash; a new config/schema and owner record must reject those receipts or use a separate ignored output root. In particular, the shared read-only `engine-333-364/build/EngineSource` is never a resume or cleanup target. The proposed stage mapping is:

| Existing runner input or stage | Shaar-owned replacement |
| --- | --- |
| `ThirdParty/ArdiaCore/source-build.json` with `source.repository`, `engineTree`, and one overlay patch digest | New immutable config pins Chromium, ungoogled/macOS, depot_tools/Siso/Git LFS, ordered Shaar patch manifest, Shaar layer tree digest, GN args and output identity; no Ardia repository or tree field. |
| `prepare_sources()` clones `source/ardia`, verifies `HEAD:engine`, then stages `source/ardia-build` | Clone only pinned tool and ungoogled sources; read Shaar build scripts and layer from this repository after validating their committed hashes. Never fetch a later Ardia release. |
| Adapted upstream `01-sync.sh` and Ardia `03-ungoogled.py` / `04-domain-substitution.sh` | Shaar-maintained sync/ungoogled/domain stages with explicit owned paths, pinned revision checks and captured script hashes. Keep `gclient` cache, no-auth environment, job cap and runhooks receipt checks. |
| Ardia `series.py`, `AC_SERIES_BASE`, `engine/chromium` and `engine/ardiacore` layer copies | Deterministic ordered Shaar patch manifest after ungoogled/domain substitution, then Shaar layer installation into `chrome/browser/shaar/` (and reviewed renderer hooks only where necessary). Record pre/post patch tree hashes and per-file hashes; reject unexpected touched paths. |
| `profile-patch` overlay and its interrupted-build reverse check | Remove the Ardia-specific stage. Implement #288 through Shaar's profile-scoped downloads module and include it in the Shaar patch/layer manifest; resume checks validate exactly that manifest. |
| Adapted `02-gn-args.sh`, `05-build.sh`, `chrome_framework` collection | Shaar-owned GN args/build commands; keep the pinned GN binary, background QoS, six-job cap, framework architecture/minimum-OS checks and full artifact hashes. Require `shaar_abi_major`, `shaar_engine_create` and the reviewed export set in the receipt; reject `ac_*` and `ArdiaCore*` exports in the final artifact. |
| `scripts/fetch-engine.sh`, `scripts/engine_payload.py`, `scripts/bundle-app.sh` use Ardia archive/pin/notices | At final cutover, fetch a Shaar-pinned archive by digest, validate payload/ABI/resource layout, package current Chromium/third-party notices, and keep the verification executable separate from the shipping bundle. Normal CI stays on its known-good pin until native probes pass. |

Source patches should be rebased from pinned Chromium/ungoogled inputs and reviewed one behavior at a time. Rewrite the needed CEF-derived behavior from its BSD-licensed patch with attribution if retained; independently assess Ardia patch behavior and implement it in new Shaar code rather than copying its text. Preserve the existing Safe Storage keychain identity until a tested migration is available. Explicitly decide how security components and extension updates are served; do not silently inherit Chromium/ungoogled defaults. Tests for runner stages must assert no Ardia URL/path/import in final inputs or receipt and no new source or binary under `engine-333-364`.

During module migration, a **temporary** source build can contain both pinned Ardia and Shaar exports, with the Swift adapter choosing a module at an explicit gate. This is only a phase-3 development bridge; it must stay pinned to the pre-relicense Ardia commit and never ship as the final no-Ardia target. After all adapters move, switch the runner to the final Shaar-only inputs, update `fetch-engine.sh`/`pin.json` and `bundle-app.sh` to verify and package the new framework and notices, remove `ThirdParty/ArdiaCore` and references, then prove the final binary has no `ac_*`/`ArdiaCore` exports or linked objects. Normal CI must not select a source-build artifact until its native probes and release gates pass.

## Migration sequence and CI gates

These are rough engineering ranges for implementation plus focused validation, excluding Chromium sync/build wall time and release compliance. Each module lands with its Swift `ChromiumBridge` adapter behind an explicit implementation choice and keeps the pinned Ardia path as the CI default until a verified dual-export engine is available. In source-engine CI, switch one module at a time, run the relevant headless native probe and existing Swift tests, then make that module's new adapter the default there. The normal prebuilt-engine CI lane remains green throughout. No engine builds are part of phases 1–2.

| Order / module | Compatibility step and acceptance gate | Rough effort |
| --- | --- | --- |
| 0. ABI scaffold, build hooks and event bridge | Add header, GN export, framework load/ABI checks, event copying/dispatch, typed Swift errors, source-build receipt assertions. Keep existing `ARCChromiumRuntime` facade. Runner dry-run/unit tests and Swift compile. | 1–2 weeks |
| 1. Lifecycle | New engine start/quit, event dispatch and shutdown callbacks; keep the current runtime facade. Startup and quit/cancel probes. | 1–2 weeks |
| 2. Profiles | Exact directory/UUID binding, profile load/release/delete and preference ownership. Profile switch and deletion probes. | 1–2 weeks |
| 3. Windows and tabs | AppKit host view, Browser/TabStrip ownership, open/adopt/place/select/close, popup and extension-view requests. Preserve deferred tab-strip reconciliation. Window/tab order and native-window probes. | 3–5 weeks |
| 4. Navigation | URL/load/reload/back/forward, restore/duplicate, renderer-gone, document commit, favicon, security summary and page channel. Maintain saved-workspace IDs; recovery and abrupt-restart probes. | 2–4 weeks |
| 5. Private sessions | Explicit OTR handle per parent profile, unique session/window/tab IDs, lease and teardown, scoped permissions; never persist private history/downloads or route OTR events to regular caches. Private fixture and privacy probes. | 2–4 weeks |
| 6. Downloads | List/control/events, target selection and per-profile directory read/write with policy validation for #288; no process-wide path authority. Download and folder probes, restart persistence. | 2–3 weeks |
| 7. Bookmarks | Tree/apply/watch with acknowledged mutation and refresh semantics. Library and favorites probes, profile isolation. | 1–2 weeks |
| 8. History | Query/delete/watch plus #299 insertion, with explicit private-session rejection and source attribution. History/import and profile-isolation probes. | 1–2 weeks |
| 9. Site data | Origin-scoped settings get/set/reset, exact-origin enumeration, cookies/cache/site-data clearing and private cookie exceptions for #289; typed policy errors. Site-control and profile-privacy probes. | 2–3 weeks |
| 10. Extensions | Installed list/actions, Web Store consent, managed install/update/unpacked-path policy, hidden popup/side-panel host, install once for every profile (#287), and component extensions. Extension storage, Bitwarden and consent probes. | 4–7 weeks |
| 11. Find | Find request IDs, count/active/final event, stop/cancel across navigation and tab close. Find-in-page probe. | 0.5–1 week |
| 12. DevTools and Inspector | Docked view, in-process protocol allowlist, tab-bound token/target, external remote endpoint policy and developer diagnostics. DevTools/Inspector probes and unauthorized-token negatives. | 2–4 weeks |
| 13. Media | Permission/capture, Media Session and frame ownership, PiP, tab sharing, casting and rendering/power behavior; remove page-script fallback only after equivalent native events. Media, PiP and capture probes. | 4–7 weeks |
| 14. Storage and keychain | Preserve readable cookies/passwords during #312 migration from the Ardia Safe Storage identity to Shaar's; verify upgrade, rollback and fresh install. Storage and keychain probes. | 2–4 weeks |
| 15. Ardia removal and final packaging | Shaar-only runner, pin/archive verification, NOTICE/credits, exported-symbol scan, full headless native fixture matrix, signed/notarized release review. | 2–3 weeks |

Total rough implementation effort is about **30–54 engineer-weeks** across modules, with overlap possible after the ABI and window foundations. The highest risk is macOS Browser/AppKit hosting, private teardown, extension update/policy behavior, storage key migration, and media/DevTools hooks. Each has a dedicated native probe before the old adapter is removed. A successful compile alone does not establish privacy isolation, data readability, update security, signing, or release readiness.
