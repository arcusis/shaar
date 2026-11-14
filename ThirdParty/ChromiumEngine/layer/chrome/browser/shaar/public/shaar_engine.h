// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
/* Shaar engine C ABI v1 for issue #418. Step 0 implements the initial exports. */
#ifndef SHAAR_ENGINE_H_
#define SHAAR_ENGINE_H_

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define SHAAR_ENGINE_ABI_MAJOR 1u
#define SHAAR_ENGINE_ABI_MINOR 17u
#define SHAAR_EXPORT __attribute__((visibility("default")))

typedef struct shaar_engine shaar_engine;
typedef struct shaar_profile shaar_profile;
typedef struct shaar_private_session shaar_private_session;
typedef struct shaar_window shaar_window;
typedef struct shaar_tab shaar_tab;
typedef struct { const char *data; size_t size; } shaar_bytes;
typedef uint64_t shaar_request_id;

typedef enum {
  SHAAR_OK = 0,
  SHAAR_INVALID_ARGUMENT = 1,
  SHAAR_UNSUPPORTED_ABI = 2,
  SHAAR_NOT_READY = 3,
  SHAAR_NOT_FOUND = 4,
  SHAAR_WRONG_PROFILE = 5,
  SHAAR_WRONG_SESSION = 6,
  SHAAR_PRIVATE_DISALLOWED = 7,
  SHAAR_POLICY_BLOCKED = 8,
  SHAAR_PERMISSION_DENIED = 9,
  SHAAR_CONFLICT = 10,
  SHAAR_CANCELLED = 11,
  SHAAR_IO_ERROR = 12,
  SHAAR_CHROMIUM_ERROR = 13,
  SHAAR_SHUTTING_DOWN = 14,
  SHAAR_UNSUPPORTED_CAPABILITY = 15
} shaar_error_code;

/* Caller sets size for writable errors; engine sets it in callback results.
 * Synchronous diagnostic message is borrowed until the next ABI call. */
typedef struct {
  uint32_t size;
  shaar_error_code code;
  int32_t platform_code;
  shaar_bytes message;
} shaar_error;

/* Result and event bytes, including nested error text, are borrowed only
 * for the duration of the callback. */
typedef struct {
  uint32_t size;
  shaar_request_id request_id;
  shaar_error error;
  shaar_bytes payload_json;
} shaar_result;
typedef void (*shaar_reply_fn)(void *context, const shaar_result *result);

typedef enum {
  SHAAR_EVENT_ENGINE = 1,
  SHAAR_EVENT_PROFILE = 2,
  SHAAR_EVENT_PRIVATE_SESSION = 3,
  SHAAR_EVENT_WINDOW = 4,
  SHAAR_EVENT_TAB = 5,
  SHAAR_EVENT_NAVIGATION = 6,
  // BEGIN find
  SHAAR_EVENT_FIND = 7,
  // END find
  SHAAR_EVENT_PERMISSION = 8,
  SHAAR_EVENT_DOWNLOAD = 9,
  SHAAR_EVENT_BOOKMARK = 10,
  SHAAR_EVENT_HISTORY = 11,
  SHAAR_EVENT_SITE_DATA = 12,
  SHAAR_EVENT_EXTENSION = 13,
  SHAAR_EVENT_DEVTOOLS = 14,
  SHAAR_EVENT_MEDIA = 15,
  // BEGIN save_prompts
  SHAAR_EVENT_SAVE_PROMPT = 16
  // END save_prompts
} shaar_event_kind;
typedef struct {
  uint32_t size;
  uint64_t sequence;
  shaar_event_kind kind;
  shaar_bytes profile_id; /* empty only for engine-wide events */
  shaar_bytes session_id; /* empty for regular scope */
  shaar_bytes window_id;
  shaar_bytes tab_id;
  shaar_bytes payload_json; /* kind + schemaVersion; no secrets/paths */
} shaar_event;
typedef void (*shaar_event_fn)(void *context, const shaar_event *event);

typedef struct {
  uint32_t size;
  uint32_t requested_major;
  uint32_t requested_minor;
  shaar_bytes data_root;
  shaar_bytes locale;
  shaar_event_fn on_event; /* the only event sink */
  void *event_context;
} shaar_config;

/* Exactly one pointer is set for a scoped operation. */
typedef struct {
  uint32_t size;
  shaar_profile *profile;
  shaar_private_session *private_session;
} shaar_scope;

typedef enum {
  SHAAR_WINDOW_REGULAR = 1, /* can bind several regular profiles */
  SHAAR_WINDOW_PRIVATE = 2, /* fixed to one private session */
  SHAAR_WINDOW_PICTURE_IN_PICTURE = 3 /* engine-owned, returned by lookup */
} shaar_window_kind;

/* Domain ranges leave room for minor-version additions without ID collisions. */
typedef enum {
  SHAAR_OP_PROFILE_DELETE = 100,
  SHAAR_OP_PROFILE_GET_STATE = 101,
  SHAAR_OP_PROFILE_SET_STATE = 102,

  SHAAR_OP_WINDOW_BIND_PROFILE = 200,
  SHAAR_OP_WINDOW_SET_ACTIVE_PROFILE = 201,
  SHAAR_OP_WINDOW_ACTIVATE_TAB = 202,
  SHAAR_OP_WINDOW_PLACE_TABS = 203,
  SHAAR_OP_WINDOW_REQUEST_RESOLVE = 204,
  SHAAR_OP_TAB_MOVE = 205,
  SHAAR_OP_TAB_ACTIVATION_RESOLVE = 206,
  SHAAR_OP_WINDOW_SET_BOUNDS = 207,

  /* Sleeping tabs (#1467), ABI minor 11. An engine without this module
   * returns SHAAR_UNSUPPORTED_CAPABILITY. */
  SHAAR_OP_TAB_DISCARD = 208,
  SHAAR_OP_TAB_FREEZE = 209,
  SHAAR_OP_TAB_WAKE = 210,
  SHAAR_OP_TAB_LIFECYCLE_GET = 211,

  SHAAR_OP_TAB_NAVIGATE = 300,
  SHAAR_OP_TAB_GO = 301,
  SHAAR_OP_TAB_RELOAD = 302,
  SHAAR_OP_TAB_STOP = 303,
  SHAAR_OP_TAB_EVALUATE = 304,

  SHAAR_OP_DOWNLOAD_LIST = 400,
  SHAAR_OP_DOWNLOAD_CONTROL = 401,
  SHAAR_OP_DOWNLOAD_DIRECTORY = 402,

  SHAAR_OP_BOOKMARK_TREE = 500,
  SHAAR_OP_BOOKMARK_APPLY = 501,
  // BEGIN bookmarks module operation IDs.
  SHAAR_OP_BOOKMARK_WATCH = 502,
  // END bookmarks module operation IDs.

  SHAAR_OP_HISTORY_QUERY = 600,
  SHAAR_OP_HISTORY_INSERT = 601,
  SHAAR_OP_HISTORY_DELETE = 602,
  // BEGIN history module operation IDs.
  SHAAR_OP_HISTORY_WATCH = 603,
  SHAAR_OP_HISTORY_UNWATCH = 604,
  // END history module operation IDs.

  SHAAR_OP_SITE_SETTINGS_GET = 700,
  SHAAR_OP_SITE_SETTINGS_SET = 701,
  SHAAR_OP_SITE_SETTINGS_RESET = 702,
  SHAAR_OP_SITE_SETTINGS_ORIGINS = 703,
  SHAAR_OP_SITE_DATA_CLEAR = 704,
  SHAAR_OP_BROWSING_DATA_CLEAR = 705,
  SHAAR_OP_SITE_COOKIES_CLEAR = 706,
  SHAAR_OP_THIRD_PARTY_COOKIES_GET = 707,
  SHAAR_OP_THIRD_PARTY_COOKIES_SET = 708,

  SHAAR_OP_EXTENSION_LIST = 800,
  SHAAR_OP_EXTENSION_MANAGE = 801,
  SHAAR_OP_EXTENSION_ACTION = 802,
  SHAAR_OP_EXTENSION_INSTALL_DECISION = 803,
  SHAAR_OP_EXTENSION_POPUP_CLOSE = 804,
  SHAAR_OP_EXTENSION_WEB_STORE_ZOOM = 805,
  SHAAR_OP_EXTENSION_ACTION_STATE = 806,
  SHAAR_OP_EXTENSION_MANAGER_OPEN = 807,
  /* Testing only: audit the three vetted bundled component registrations. */
  SHAAR_OP_PROBE_FRAMEWORK_DEVTOOLS = 890,

  // BEGIN find
  SHAAR_OP_TAB_FIND = 900,
  SHAAR_OP_TAB_STOP_FIND = 901,
  // END find

  // BEGIN devtools operation IDs.
  SHAAR_OP_DEVTOOLS_CALL = 1000,
  SHAAR_OP_DEVTOOLS_UI_SHOW = 1001,
  SHAAR_OP_DEVTOOLS_UI_CLOSE = 1002,
  SHAAR_OP_DEVTOOLS_UI_STATE = 1003,
  SHAAR_OP_DEVTOOLS_UI_SET_DOCK = 1004,
  SHAAR_OP_DEVTOOLS_CONTROL_ENABLE = 1005,
  SHAAR_OP_DEVTOOLS_CONTROL_DISABLE = 1006,
  SHAAR_OP_DEVTOOLS_CONTROL_STATUS = 1007,
  // Testing only: capture the selected owned tab without showing its window.
  SHAAR_OP_PROBE_CAPTURE_TAB = 1008,
  SHAAR_OP_DEVTOOLS_PANEL_OPEN = 1009,
  SHAAR_OP_DEVTOOLS_PANEL_CLOSE = 1010,
  SHAAR_OP_DEVTOOLS_PANEL_GET_RESPONSE_BODY = 1011,
  SHAAR_OP_DEVTOOLS_PANEL_PHASE2_COMMAND = 1012,
  SHAAR_OP_DEVTOOLS_PANEL_SCREENCAST = 1019,
  SHAAR_OP_DEVTOOLS_VIEWPORT_OPEN = 1013,
  SHAAR_OP_DEVTOOLS_VIEWPORT_CLOSE = 1014,
  SHAAR_OP_DEVTOOLS_VIEWPORT_ADD = 1015,
  SHAAR_OP_DEVTOOLS_VIEWPORT_REMOVE = 1016,
  SHAAR_OP_DEVTOOLS_VIEWPORT_ACTION = 1017,
  SHAAR_OP_DEVTOOLS_VIEWPORT_FRAME = 1018,
  // Testing only: exercise the native DevTools URL and Node frontend routes.
  SHAAR_OP_PROBE_DEVTOOLS_OPEN_URL = 1090,
  SHAAR_OP_PROBE_NODE_FRONTEND = 1091,
  SHAAR_OP_PROBE_DEVTOOLS_FRONTEND_ATTACHED = 1092,
  // Testing only: send a native mouse click to a never-shown owned fixture tab.
  SHAAR_OP_PROBE_TRUSTED_CLICK = 1093,
  // Testing only: open Node frontend against a local inspector fixture.
  SHAAR_OP_PROBE_NODE_LIVE = 1094,
  // Testing only: inspect a popup owned by the selected fixture tab.
  SHAAR_OP_PROBE_POPUP_EVALUATE = 1095,
  SHAAR_OP_PROBE_POPUP_CAPTURE = 1096,
  // END devtools operation IDs.

  // BEGIN media
  SHAAR_OP_MEDIA_GET_STATE = 1100,
  SHAAR_OP_MEDIA_CONTROL = 1101,
  SHAAR_OP_MEDIA_SET_AUTO_PIP = 1102,
  SHAAR_OP_MEDIA_ENTER_PIP = 1103,
  SHAAR_OP_MEDIA_EXIT_PIP = 1104,
  SHAAR_OP_MEDIA_LIST_CAPTURE_SOURCES = 1105,
  SHAAR_OP_MEDIA_CAPTURE_REPLY = 1106,
  SHAAR_OP_PROBE_MEDIA_GESTURE = 1107,
  SHAAR_OP_MEDIA_PERMISSION_DECISION = 1108,
  // END media
  /* HTTP authentication credentials, ABI minor 17. */
  SHAAR_OP_HTTP_AUTH_CREDENTIALS_REPLY = 1601,
  // BEGIN storage_keychain
  SHAAR_OP_STORAGE_KEYCHAIN_IDENTITY = 1400,
  // END storage_keychain
  // BEGIN save_prompts
  SHAAR_OP_SAVE_PROMPT_DECIDE = 1500
  // END save_prompts
} shaar_operation;

// Private sessions module IDs.
typedef enum {
  SHAAR_MODULE_PRIVATE_SESSIONS = 1200,
  // BEGIN extensions
  SHAAR_MODULE_EXTENSIONS = 1300,
  // END extensions
  // BEGIN storage_keychain
  SHAAR_MODULE_STORAGE_KEYCHAIN = 1400
  // END storage_keychain
} shaar_module_id;
// BEGIN site_data
enum { SHAAR_MODULE_SITE_DATA = 1201 };
// END site_data
// BEGIN media
enum { SHAAR_MODULE_MEDIA = 1203 };
// END media
// BEGIN save_prompts
enum { SHAAR_MODULE_SAVE_PROMPTS = 1500 };
// END save_prompts

// BEGIN devtools command and module IDs.
typedef enum {
  SHAAR_DEVTOOLS_CAPABILITY_INSPECTOR = 1,
  SHAAR_DEVTOOLS_CAPABILITY_DEVELOPER = 2,
  SHAAR_DEVTOOLS_CAPABILITY_DEVTOOLS_PANEL = 3
} shaar_devtools_capability;

typedef enum {
  SHAAR_DEVTOOLS_SCREENCAST_START = 1,
  SHAAR_DEVTOOLS_SCREENCAST_STOP = 2,
  SHAAR_DEVTOOLS_SCREENCAST_ACK = 3
} shaar_devtools_screencast_command;

typedef enum {
  SHAAR_DEVTOOLS_PANEL_CONSOLE_API_CALLED = 1,
  SHAAR_DEVTOOLS_PANEL_EXCEPTION_THROWN = 2,
  SHAAR_DEVTOOLS_PANEL_LOG_ENTRY_ADDED = 3,
  SHAAR_DEVTOOLS_PANEL_REQUEST_WILL_BE_SENT = 4,
  SHAAR_DEVTOOLS_PANEL_RESPONSE_RECEIVED = 5,
  SHAAR_DEVTOOLS_PANEL_LOADING_FINISHED = 6,
  SHAAR_DEVTOOLS_PANEL_LOADING_FAILED = 7,
  SHAAR_DEVTOOLS_PANEL_DATA_RECEIVED = 8,
  SHAAR_DEVTOOLS_PANEL_PAGE_LIFECYCLE = 9,
  SHAAR_DEVTOOLS_PANEL_PERFORMANCE_METRICS = 10,
  SHAAR_DEVTOOLS_PANEL_EVENTS_DROPPED = 11,
  SHAAR_DEVTOOLS_PANEL_SCREENCAST_FRAME = 29,
  SHAAR_DEVTOOLS_PANEL_DOM_STORAGE_ADDED = 12,
  SHAAR_DEVTOOLS_PANEL_DOM_STORAGE_UPDATED = 13,
  SHAAR_DEVTOOLS_PANEL_DOM_STORAGE_REMOVED = 14,
  SHAAR_DEVTOOLS_PANEL_DOM_STORAGE_CLEARED = 15,
  SHAAR_DEVTOOLS_PANEL_SERVICE_WORKER_REGISTRATION = 16,
  SHAAR_DEVTOOLS_PANEL_SERVICE_WORKER_VERSION = 17,
  SHAAR_DEVTOOLS_PANEL_SERVICE_WORKER_ERROR = 18,
  SHAAR_DEVTOOLS_PANEL_PERFORMANCE_TIMELINE = 19
} shaar_devtools_panel_event_id;
typedef enum {
  SHAAR_DEVTOOLS_PHASE2_DOM_STORAGE_ITEMS = 1,
  SHAAR_DEVTOOLS_PHASE2_DOM_STORAGE_SET = 2,
  SHAAR_DEVTOOLS_PHASE2_DOM_STORAGE_REMOVE = 3,
  SHAAR_DEVTOOLS_PHASE2_DOM_STORAGE_CLEAR = 4,
  SHAAR_DEVTOOLS_PHASE2_INDEXED_DB_NAMES = 5,
  SHAAR_DEVTOOLS_PHASE2_INDEXED_DB_SCHEMA = 6,
  SHAAR_DEVTOOLS_PHASE2_INDEXED_DB_DATA = 7,
  SHAAR_DEVTOOLS_PHASE2_CACHE_NAMES = 8,
  SHAAR_DEVTOOLS_PHASE2_CACHE_ENTRIES = 9,
  SHAAR_DEVTOOLS_PHASE2_CACHE_RESPONSE = 10,
  SHAAR_DEVTOOLS_PHASE2_SERVICE_WORKER_UPDATE = 11,
  SHAAR_DEVTOOLS_PHASE2_SERVICE_WORKER_UNREGISTER = 12,
  SHAAR_DEVTOOLS_PHASE2_PERFORMANCE_METRICS = 13,
  SHAAR_DEVTOOLS_PHASE2_DOM_COUNTERS = 14,
  SHAAR_DEVTOOLS_PHASE2_RESOURCE_TREE = 15,
  SHAAR_DEVTOOLS_PHASE2_RESOURCE_CONTENT = 16,
  SHAAR_DEVTOOLS_PHASE2_LONG_TASKS = 17,
  SHAAR_DEVTOOLS_PHASE2_VITALS_INPUTS = 18
} shaar_devtools_phase2_command_id;
typedef enum {
  SHAAR_DEVTOOLS_DOCK_RIGHT = 1,
  SHAAR_DEVTOOLS_DOCK_BOTTOM = 2,
  SHAAR_DEVTOOLS_DOCK_LEFT = 3,
  SHAAR_DEVTOOLS_DOCK_UNDOCKED = 4
} shaar_devtools_dock;
typedef enum {
  SHAAR_DEVTOOLS_RUNTIME_EVALUATE = 1,
  SHAAR_DEVTOOLS_RUNTIME_RELEASE_OBJECT = 2,
  SHAAR_DEVTOOLS_RUNTIME_GET_PROPERTIES = 3,
  SHAAR_DEVTOOLS_RUNTIME_RELEASE_OBJECT_GROUP = 4,
  SHAAR_DEVTOOLS_DOM_ENABLE = 5,
  SHAAR_DEVTOOLS_DOM_GET_DOCUMENT = 6,
  SHAAR_DEVTOOLS_DOM_REQUEST_NODE = 7,
  SHAAR_DEVTOOLS_DOM_GET_BOX_MODEL = 8,
  SHAAR_DEVTOOLS_CSS_ENABLE = 9,
  SHAAR_DEVTOOLS_CSS_GET_PLATFORM_FONTS_FOR_NODE = 10,
  SHAAR_DEVTOOLS_CSS_GET_BACKGROUND_COLORS = 11,
  SHAAR_DEVTOOLS_CSS_GET_MATCHED_STYLES_FOR_NODE = 12,
  SHAAR_DEVTOOLS_CSS_GET_COMPUTED_STYLE_FOR_NODE = 13,
  SHAAR_DEVTOOLS_CSS_GET_STYLESHEET_TEXT = 14,
  SHAAR_DEVTOOLS_PAGE_ENABLE = 15,
  SHAAR_DEVTOOLS_PAGE_GET_RESOURCE_TREE = 16,
  SHAAR_DEVTOOLS_PAGE_GET_RESOURCE_CONTENT = 17,
  SHAAR_DEVTOOLS_PAGE_CAPTURE_SCREENSHOT = 18,
  SHAAR_DEVTOOLS_OVERLAY_ENABLE = 19,
  SHAAR_DEVTOOLS_OVERLAY_DISABLE = 20,
  SHAAR_DEVTOOLS_OVERLAY_SET_SHOW_GRID_OVERLAYS = 21,
  SHAAR_DEVTOOLS_OVERLAY_SET_SHOW_FLEX_OVERLAYS = 22,
  SHAAR_DEVTOOLS_OVERLAY_GET_GRID_HIGHLIGHT_OBJECTS_FOR_TEST = 23,
  SHAAR_DEVTOOLS_DOM_DESCRIBE_NODE = 24,
  SHAAR_DEVTOOLS_ACCESSIBILITY_GET_PARTIAL_AX_TREE = 25,
  SHAAR_DEVTOOLS_EMULATION_SET_DEVICE_METRICS_OVERRIDE = 26,
  SHAAR_DEVTOOLS_EMULATION_CLEAR_DEVICE_METRICS_OVERRIDE = 27,
  SHAAR_DEVTOOLS_NETWORK_ENABLE = 28,
  SHAAR_DEVTOOLS_NETWORK_EMULATE_NETWORK_CONDITIONS = 29,
  SHAAR_DEVTOOLS_EMULATION_SET_CPU_THROTTLING_RATE = 30,
  SHAAR_DEVTOOLS_EMULATION_SET_GEOLOCATION_OVERRIDE = 31,
  SHAAR_DEVTOOLS_EMULATION_CLEAR_GEOLOCATION_OVERRIDE = 32,
  SHAAR_DEVTOOLS_EMULATION_SET_TIMEZONE_OVERRIDE = 33,
  SHAAR_DEVTOOLS_EMULATION_SET_LOCALE_OVERRIDE = 34,
  SHAAR_DEVTOOLS_EMULATION_SET_USER_AGENT_OVERRIDE = 35,
  SHAAR_DEVTOOLS_EMULATION_SET_EMULATED_MEDIA = 36,
  SHAAR_DEVTOOLS_PERFORMANCE_ENABLE = 37,
  SHAAR_DEVTOOLS_PERFORMANCE_GET_METRICS = 38,
  SHAAR_DEVTOOLS_PAGE_ADD_SCRIPT_TO_EVALUATE_ON_NEW_DOCUMENT = 39,
  SHAAR_DEVTOOLS_PAGE_REMOVE_SCRIPT_TO_EVALUATE_ON_NEW_DOCUMENT = 40,
  SHAAR_DEVTOOLS_NETWORK_GET_COOKIES = 41,
  SHAAR_DEVTOOLS_NETWORK_SET_COOKIE = 42,
  SHAAR_DEVTOOLS_NETWORK_DELETE_COOKIES = 43,
  SHAAR_DEVTOOLS_EMULATION_SET_SAFE_AREA_INSETS_OVERRIDE = 44,
  SHAAR_DEVTOOLS_PAGE_HANDLE_JAVASCRIPT_DIALOG = 45
} shaar_devtools_command;
typedef enum { SHAAR_MODULE_DEVTOOLS = 1202 } shaar_devtools_module_id;
// END devtools command and module IDs.

// BEGIN media
typedef enum {
  SHAAR_MEDIA_PLAY = 0, SHAAR_MEDIA_PAUSE = 1,
  SHAAR_MEDIA_PREVIOUS_TRACK = 2, SHAAR_MEDIA_NEXT_TRACK = 3,
  SHAAR_MEDIA_SEEK_BACKWARD = 4, SHAAR_MEDIA_SEEK_FORWARD = 5,
  SHAAR_MEDIA_SEEK_TO = 6, SHAAR_MEDIA_SET_TAB_MUTED = 7,
  SHAAR_MEDIA_SET_ELEMENT_VOLUME = 8, SHAAR_MEDIA_PIP_PLAY = 9,
  SHAAR_MEDIA_PIP_PAUSE = 10, SHAAR_MEDIA_PIP_SKIP = 11,
  SHAAR_MEDIA_PIP_ENTER = 12, SHAAR_MEDIA_PIP_EXIT = 13
} shaar_media_command;
// END media

SHAAR_EXPORT uint32_t shaar_abi_major(void);
SHAAR_EXPORT uint32_t shaar_abi_minor(void);
SHAAR_EXPORT shaar_error_code shaar_engine_create(
    const shaar_config *, shaar_engine **out, shaar_error *error);
SHAAR_EXPORT shaar_error_code shaar_engine_run(
    shaar_engine *, shaar_error *error);
SHAAR_EXPORT shaar_error_code shaar_engine_request_quit(
    shaar_engine *, shaar_error *error);
SHAAR_EXPORT void shaar_engine_release(shaar_engine *);
/* Verification-only diagnostics. Calls require SHAAR_ENGINE_TESTING=1 and the
 * active engine; output bytes are borrowed until the next call on this thread. */
SHAAR_EXPORT shaar_error_code shaar_test_keep_alive_state(
    shaar_engine *, shaar_bytes *out, shaar_error *error);
/* Loads only the fixture at <owned marked probe root>/Extension in a regular
 * profile. This is unavailable to shipping runs. */
SHAAR_EXPORT shaar_error_code shaar_test_load_component_extension(
    shaar_engine *, shaar_profile *, shaar_bytes path, shaar_bytes *extension_id,
    shaar_error *error);

/* On SHAAR_OK, out is a reserved handle; one later reply confirms readiness. */
SHAAR_EXPORT shaar_error_code shaar_profile_open(
    shaar_engine *, shaar_bytes profile_id, shaar_bytes directory,
    int create_if_missing, shaar_request_id, shaar_reply_fn, void *reply_context,
    shaar_profile **out, shaar_error *immediate_error);
SHAAR_EXPORT shaar_error_code shaar_profile_close(
    shaar_profile *, shaar_error *error);
/* BEGIN Shaar profiles module ABI exports. */
SHAAR_EXPORT shaar_error_code shaar_profile_create(
    shaar_engine *, shaar_bytes profile_id, shaar_bytes display_name,
    shaar_request_id, shaar_reply_fn, void *reply_context,
    shaar_profile **out, shaar_error *immediate_error);
SHAAR_EXPORT shaar_error_code shaar_profile_delete(
    shaar_profile *, shaar_error *error);
SHAAR_EXPORT shaar_error_code shaar_profile_get_state(
    shaar_profile *, shaar_bytes state_key, shaar_bytes *value_json,
    shaar_error *error);
SHAAR_EXPORT shaar_error_code shaar_profile_set_state(
    shaar_profile *, shaar_bytes state_key, shaar_bytes value_json,
    shaar_error *error);
/* enabled is 0 or 1. Missing from older engines; the app treats that as
 * "applies the next time this profile opens." */
SHAAR_EXPORT shaar_error_code shaar_profile_set_https_only(
    shaar_profile *, int enabled, shaar_error *error);
SHAAR_EXPORT shaar_error_code shaar_profile_get_path(
    shaar_profile *, shaar_bytes *path, shaar_error *error);
/* END Shaar profiles module ABI exports. */
SHAAR_EXPORT shaar_error_code shaar_private_session_open(
    shaar_profile *, shaar_bytes session_id, shaar_private_session **out,
    shaar_error *error);
SHAAR_EXPORT shaar_error_code shaar_private_session_close(
    shaar_private_session *, shaar_error *error);
/* Exact HTTP(S) origin in the private session's OTR content settings map.
 * set=0 reads, set=1 writes allow=0 (block) or allow=1 (allow). */
SHAAR_EXPORT shaar_error_code shaar_private_session_cookie_setting(
    shaar_private_session *, shaar_bytes origin, int set, int allow,
    int *allowed, shaar_error *error);
/* Live OTR defaults and parent comparison, encoded as a NUL-terminated JSON
 * object. The caller owns the buffer; no private profile pointer escapes. */
SHAAR_EXPORT shaar_error_code shaar_private_session_privacy_status(
    shaar_private_session *, char *json, size_t capacity, shaar_error *error);
/* Rules are canonical DNS names in a JSON string array (max 4 MiB). Revision
 * identifies exact content and cannot be reused with different rules. */
SHAAR_EXPORT shaar_error_code shaar_private_session_tracker_rules(
    shaar_private_session *, shaar_bytes revision, shaar_bytes domains_json,
    shaar_error *error);
/* Writes a NUL-terminated revision into caller storage (at least 201 bytes). */
SHAAR_EXPORT shaar_error_code shaar_private_session_tracker_status(
    shaar_private_session *, char *revision, size_t revision_capacity,
    int *domain_count, int *blocked_requests, shaar_error *error);
/* Exact HTTP(S) top-frame origin. set=0 reads, set=1 writes. */
SHAAR_EXPORT shaar_error_code shaar_private_session_tracker_allowance(
    shaar_private_session *, shaar_bytes origin, int set, int allow,
    int *allowed, shaar_error *error);

/* Regular host may bind multiple regular profiles; private host is fixed. */
SHAAR_EXPORT shaar_error_code shaar_window_open(
    shaar_engine *, shaar_window_kind, shaar_private_session *private_session,
    shaar_bytes window_id, shaar_window **out, shaar_error *error);
SHAAR_EXPORT shaar_error_code shaar_window_close(
    shaar_window *, shaar_error *error);
SHAAR_EXPORT void *shaar_window_host_view(shaar_window *); /* borrowed NSView* */
SHAAR_EXPORT void *shaar_window_native_window(shaar_window *); /* borrowed NSWindow* */
SHAAR_EXPORT shaar_error_code shaar_tab_open(
    shaar_scope, shaar_window *, shaar_bytes tab_id, shaar_bytes url,
    int foreground, shaar_tab **out, shaar_error *error);
SHAAR_EXPORT shaar_error_code shaar_tab_close(
    shaar_tab *, shaar_error *error);
SHAAR_EXPORT void *shaar_tab_host_view(shaar_tab *); /* borrowed NSView* */
/* Verification-only native ownership and display evidence. Caller sets size;
 * every field is derived from the registered Chromium tab and page host. */
typedef struct {
  uint32_t size;
  int live_web_contents;
  int selected_native_tab;
  int displayed_native_web_contents;
  int context_is_private;
  int scope_owns_tab;
} shaar_tab_probe_state;
SHAAR_EXPORT shaar_error_code shaar_tab_get_probe_state(
    shaar_engine *, shaar_scope, shaar_window *, shaar_tab *,
    shaar_tab_probe_state *out, shaar_error *error);
/* Borrowed PNG bytes remain valid until the next favicon query on this tab or
 * its close. The caller copies them before returning to its own event loop.
 * The scope must own the live tab in the supplied window. */
SHAAR_EXPORT shaar_error_code shaar_tab_favicon_png(
    shaar_engine *, shaar_scope, shaar_window *, shaar_tab *,
    shaar_bytes *out_png, shaar_error *error);
/* Borrowed until POPUP_CLOSE or its owning tab or window closes. */
SHAAR_EXPORT void *shaar_extension_popup_view(
    shaar_engine *, shaar_window *, shaar_bytes popup_id);
/* Borrowed, fully initialized docked DevTools NSView*. Null while closed or
 * undocked. Caller must retain no ownership and release it when the tab closes.
 */
SHAAR_EXPORT void *shaar_devtools_frontend_view(shaar_engine *, shaar_scope,
                                                shaar_window *, shaar_tab *);
/* Verification-only geometry reported by the DevTools frontend and the native
 * page host. Available only with SHAAR_ENGINE_TESTING=1 after docking. */
typedef struct {
  uint32_t size;
  double container_width;
  double inspected_page_right;
  double frontend_placeholder_right;
  double frontend_width;
} shaar_devtools_geometry;
SHAAR_EXPORT shaar_error_code shaar_test_devtools_geometry(
    shaar_engine *, shaar_scope, shaar_window *, shaar_tab *,
    shaar_devtools_geometry *out, shaar_error *error);
/* UI-thread page hosting. Handles must be registered to the same engine/window.
 * Attach selects a tab; detach is idempotent for an unselected tab. */
SHAAR_EXPORT shaar_error_code shaar_tab_view_attach(
    shaar_engine *, shaar_window *, shaar_tab *, shaar_error *);
SHAAR_EXPORT shaar_error_code shaar_tab_view_detach(
    shaar_engine *, shaar_window *, shaar_tab *, shaar_error *);
SHAAR_EXPORT shaar_error_code shaar_tab_view_focus(
    shaar_engine *, shaar_window *, shaar_tab *, shaar_error *);
SHAAR_EXPORT shaar_error_code shaar_window_host_resize(
    shaar_engine *, shaar_window *, double width, double height, shaar_error *);
SHAAR_EXPORT shaar_error_code shaar_media_pip_window(
    shaar_scope, shaar_tab *, shaar_window **out, shaar_error *error);
/* Borrowed JSON bytes are valid until the next call on this UI thread. The
 * selected regular tab must belong to scope and window. */
SHAAR_EXPORT shaar_error_code shaar_site_security_info(
    shaar_engine *, shaar_scope, shaar_window *, shaar_tab *,
    shaar_bytes *out_json, shaar_error *error);

/* Verification-only private-quit hooks. Release builds leave
 * shaar_enable_quit_probe_hooks off, so these symbols are not linked.
 * Callers dlsym the whole set and keep the older probe path when any symbol
 * is missing. Release drops a prepare hold and succeeds when none is armed.
 * Immediate failure has no later callback. A result payload is empty on error.
 * Audit JSON is borrowed until the next call on this thread. */
SHAAR_EXPORT shaar_error_code shaar_test_renderer_activate(
    shaar_engine *, shaar_scope, shaar_window *, shaar_tab *, int x, int y,
    shaar_request_id, shaar_reply_fn, void *reply_context, shaar_error *);
SHAAR_EXPORT shaar_error_code shaar_test_quit_dialog_prepare(
    shaar_engine *, shaar_scope, shaar_window *, shaar_tab *, shaar_request_id,
    shaar_reply_fn, void *reply_context, shaar_error *);
SHAAR_EXPORT shaar_error_code shaar_test_quit_dialog_cancel(
    shaar_engine *, shaar_scope, shaar_window *, shaar_tab *, shaar_request_id,
    shaar_reply_fn, void *reply_context, shaar_error *);
SHAAR_EXPORT shaar_error_code shaar_test_quit_dialog_audit(
    shaar_engine *, shaar_scope, shaar_window *, shaar_tab *,
    shaar_bytes *out_json, shaar_error *);
SHAAR_EXPORT shaar_error_code shaar_test_quit_dialog_release(
    shaar_engine *, shaar_scope, shaar_window *, shaar_tab *, shaar_error *);

/* args_json includes schemaVersion. Immediate failure has no later callback;
 * accepted requests complete once. A result payload is empty on error. */
SHAAR_EXPORT shaar_error_code shaar_submit(
    shaar_engine *, shaar_scope, shaar_window *, shaar_tab *,
    shaar_operation, shaar_bytes args_json, shaar_request_id,
    shaar_reply_fn, void *reply_context, shaar_error *immediate_error);
SHAAR_EXPORT shaar_error_code shaar_cancel_request(
    shaar_engine *, shaar_request_id, shaar_error *error);
SHAAR_EXPORT shaar_error_code shaar_print_reply(const char *request_id,
                                                 int accepted);

#ifdef __cplusplus
}
#endif
#endif
