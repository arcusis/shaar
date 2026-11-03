// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#include "chrome/browser/shaar/devtools/shaar_devtools.h"

#include <stddef.h>
#include <stdint.h>
#include <limits.h>

#include <algorithm>
#include <cstdio>
#include <cstring>
#include <functional>
#include <initializer_list>
#include <map>
#include <string_view>
#include <utility>

#include "base/functional/bind.h"
#include "base/no_destructor.h"
#include "base/containers/span.h"
#include "base/json/json_reader.h"
#include "base/json/json_writer.h"
#include "base/task/sequenced_task_runner.h"
#include "base/strings/string_number_conversions.h"
#include "base/time/time.h"
#include "base/timer/timer.h"
#include "chrome/browser/devtools/devtools_window.h"
#include "chrome/browser/devtools/devtools_settings.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/shaar/engine/shaar_engine_context.h"
#include "chrome/browser/shaar/engine/shaar_event_bridge.h"
#include "content/public/browser/devtools_agent_host.h"
#include "content/public/browser/navigation_handle.h"
#include "content/public/browser/web_contents.h"
#include "content/public/browser/web_contents_observer.h"

namespace shaar::devtools {
namespace {

constexpr size_t kMaxArgumentsBytes = 1024 * 1024;
constexpr int kInspector = 1;
constexpr int kDeveloper = 2;
constexpr char kFrontendStateEvent[] =
    "{\"schemaVersion\":1,\"kind\":\"frontendState\",\"open\":%s,"
    "\"dockSide\":%u,\"extent\":%d}";

struct CommandEntry {
  shaar_devtools_command command;
  const char* method;
  bool inspector;
  bool developer;
};

constexpr CommandEntry kCommands[] = {
    {SHAAR_DEVTOOLS_RUNTIME_EVALUATE, "Runtime.evaluate", true, true},
    {SHAAR_DEVTOOLS_RUNTIME_RELEASE_OBJECT, "Runtime.releaseObject", true, true},
    {SHAAR_DEVTOOLS_RUNTIME_GET_PROPERTIES, "Runtime.getProperties", true, true},
    {SHAAR_DEVTOOLS_RUNTIME_RELEASE_OBJECT_GROUP, "Runtime.releaseObjectGroup", true, true},
    {SHAAR_DEVTOOLS_DOM_ENABLE, "DOM.enable", true, false},
    {SHAAR_DEVTOOLS_DOM_GET_DOCUMENT, "DOM.getDocument", true, false},
    {SHAAR_DEVTOOLS_DOM_REQUEST_NODE, "DOM.requestNode", true, false},
    {SHAAR_DEVTOOLS_DOM_GET_BOX_MODEL, "DOM.getBoxModel", true, false},
    {SHAAR_DEVTOOLS_CSS_ENABLE, "CSS.enable", true, false},
    {SHAAR_DEVTOOLS_CSS_GET_PLATFORM_FONTS_FOR_NODE, "CSS.getPlatformFontsForNode", true, false},
    {SHAAR_DEVTOOLS_CSS_GET_BACKGROUND_COLORS, "CSS.getBackgroundColors", true, false},
    {SHAAR_DEVTOOLS_CSS_GET_MATCHED_STYLES_FOR_NODE, "CSS.getMatchedStylesForNode", true, false},
    {SHAAR_DEVTOOLS_CSS_GET_COMPUTED_STYLE_FOR_NODE, "CSS.getComputedStyleForNode", true, false},
    {SHAAR_DEVTOOLS_CSS_GET_STYLESHEET_TEXT, "CSS.getStyleSheetText", true, false},
    {SHAAR_DEVTOOLS_PAGE_ENABLE, "Page.enable", true, true},
    {SHAAR_DEVTOOLS_PAGE_GET_RESOURCE_TREE, "Page.getResourceTree", true, true},
    {SHAAR_DEVTOOLS_PAGE_GET_RESOURCE_CONTENT, "Page.getResourceContent", true, false},
    {SHAAR_DEVTOOLS_PAGE_CAPTURE_SCREENSHOT, "Page.captureScreenshot", true, false},
    {SHAAR_DEVTOOLS_OVERLAY_ENABLE, "Overlay.enable", true, false},
    {SHAAR_DEVTOOLS_OVERLAY_DISABLE, "Overlay.disable", true, false},
    {SHAAR_DEVTOOLS_OVERLAY_SET_SHOW_GRID_OVERLAYS, "Overlay.setShowGridOverlays", true, false},
    {SHAAR_DEVTOOLS_OVERLAY_SET_SHOW_FLEX_OVERLAYS, "Overlay.setShowFlexOverlays", true, false},
    {SHAAR_DEVTOOLS_OVERLAY_GET_GRID_HIGHLIGHT_OBJECTS_FOR_TEST, "Overlay.getGridHighlightObjectsForTest", true, false},
    {SHAAR_DEVTOOLS_DOM_DESCRIBE_NODE, "DOM.describeNode", true, false},
    {SHAAR_DEVTOOLS_ACCESSIBILITY_GET_PARTIAL_AX_TREE, "Accessibility.getPartialAXTree", true, false},
    {SHAAR_DEVTOOLS_EMULATION_SET_DEVICE_METRICS_OVERRIDE, "Emulation.setDeviceMetricsOverride", false, true},
    {SHAAR_DEVTOOLS_EMULATION_CLEAR_DEVICE_METRICS_OVERRIDE, "Emulation.clearDeviceMetricsOverride", false, true},
    {SHAAR_DEVTOOLS_NETWORK_ENABLE, "Network.enable", false, true},
    {SHAAR_DEVTOOLS_NETWORK_EMULATE_NETWORK_CONDITIONS, "Network.emulateNetworkConditions", false, true},
    {SHAAR_DEVTOOLS_EMULATION_SET_CPU_THROTTLING_RATE, "Emulation.setCPUThrottlingRate", false, true},
    {SHAAR_DEVTOOLS_EMULATION_SET_GEOLOCATION_OVERRIDE, "Emulation.setGeolocationOverride", false, true},
    {SHAAR_DEVTOOLS_EMULATION_CLEAR_GEOLOCATION_OVERRIDE, "Emulation.clearGeolocationOverride", false, true},
    {SHAAR_DEVTOOLS_EMULATION_SET_TIMEZONE_OVERRIDE, "Emulation.setTimezoneOverride", false, true},
    {SHAAR_DEVTOOLS_EMULATION_SET_LOCALE_OVERRIDE, "Emulation.setLocaleOverride", false, true},
    {SHAAR_DEVTOOLS_EMULATION_SET_USER_AGENT_OVERRIDE, "Emulation.setUserAgentOverride", false, true},
    {SHAAR_DEVTOOLS_EMULATION_SET_EMULATED_MEDIA, "Emulation.setEmulatedMedia", false, true},
    {SHAAR_DEVTOOLS_PERFORMANCE_ENABLE, "Performance.enable", false, true},
    {SHAAR_DEVTOOLS_PERFORMANCE_GET_METRICS, "Performance.getMetrics", false, true},
    {SHAAR_DEVTOOLS_PAGE_ADD_SCRIPT_TO_EVALUATE_ON_NEW_DOCUMENT, "Page.addScriptToEvaluateOnNewDocument", false, true},
    {SHAAR_DEVTOOLS_PAGE_REMOVE_SCRIPT_TO_EVALUATE_ON_NEW_DOCUMENT, "Page.removeScriptToEvaluateOnNewDocument", false, true},
};

struct ReplyContext {
  shaar_engine* engine;
  shaar_request_id request_id;
  shaar_reply_fn reply;
  void* context;
};

void DeliverReply(ReplyContext request, shaar_error_code code,
                  std::string payload, std::string message) {
  shaar_result result{};
  result.size = sizeof(result);
  result.request_id = request.request_id;
  result.error.size = sizeof(result.error);
  result.error.code = code;
  result.error.message = {message.data(), message.size()};
  result.payload_json = {payload.data(), payload.size()};
  if (request.reply)
    request.reply(request.context, &result);
}

void Reply(ReplyContext request, shaar_error_code code, std::string payload,
           std::string message = {}) {
  base::SequencedTaskRunner::GetCurrentDefault()->PostTask(
      FROM_HERE, base::BindOnce(&DeliverReply, request, code,
                                std::move(payload), std::move(message)));
}

shaar_error_code Fail(shaar_error* error, shaar_error_code code,
                      const char* message) {
  if (error) {
    const uint32_t supplied = error->size;
    if (supplied >= offsetof(shaar_error, code) + sizeof(error->code))
      error->code = code;
    if (supplied >= offsetof(shaar_error, platform_code) + sizeof(error->platform_code))
      error->platform_code = 0;
    if (supplied >= offsetof(shaar_error, message) + sizeof(error->message))
      error->message = {message, std::strlen(message)};
  }
  return code;
}

bool ExactKeys(const base::Value::Dict& dict,
               std::initializer_list<std::string_view> keys) {
  for (const auto item : dict) {
    bool found = false;
    for (auto key : keys)
      found |= item.first == key;
    if (!found)
      return false;
  }
  return true;
}

bool ParamsHaveOnly(const base::Value::Dict& params,
                    std::initializer_list<std::string_view> keys) {
  return ExactKeys(params, keys);
}

bool ValidateParams(shaar_devtools_command command,
                    const base::Value::Dict& params) {
  switch (command) {
    case SHAAR_DEVTOOLS_RUNTIME_EVALUATE:
      return ParamsHaveOnly(params, {"expression", "objectGroup",
          "silent", "contextId", "returnByValue", "generatePreview",
          "awaitPromise", "timeout", "uniqueContextId",
          "serializationOptions"});
    case SHAAR_DEVTOOLS_RUNTIME_RELEASE_OBJECT:
      return ParamsHaveOnly(params, {"objectId"});
    case SHAAR_DEVTOOLS_RUNTIME_GET_PROPERTIES:
      return ParamsHaveOnly(params, {"objectId", "ownProperties",
          "accessorPropertiesOnly", "generatePreview", "nonIndexedPropertiesOnly",
          "generateNativeGetters"});
    case SHAAR_DEVTOOLS_RUNTIME_RELEASE_OBJECT_GROUP:
      return ParamsHaveOnly(params, {"objectGroup"});
    case SHAAR_DEVTOOLS_DOM_ENABLE:
    case SHAAR_DEVTOOLS_CSS_ENABLE:
    case SHAAR_DEVTOOLS_PAGE_ENABLE:
    case SHAAR_DEVTOOLS_PAGE_GET_RESOURCE_TREE:
    case SHAAR_DEVTOOLS_OVERLAY_ENABLE:
    case SHAAR_DEVTOOLS_OVERLAY_DISABLE:
    case SHAAR_DEVTOOLS_OVERLAY_GET_GRID_HIGHLIGHT_OBJECTS_FOR_TEST:
    case SHAAR_DEVTOOLS_EMULATION_CLEAR_DEVICE_METRICS_OVERRIDE:
    case SHAAR_DEVTOOLS_NETWORK_ENABLE:
    case SHAAR_DEVTOOLS_EMULATION_CLEAR_GEOLOCATION_OVERRIDE:
    case SHAAR_DEVTOOLS_PERFORMANCE_ENABLE:
    case SHAAR_DEVTOOLS_PERFORMANCE_GET_METRICS:
      return ParamsHaveOnly(params, {});
    case SHAAR_DEVTOOLS_DOM_GET_DOCUMENT:
      return ParamsHaveOnly(params, {"depth", "pierce"});
    case SHAAR_DEVTOOLS_DOM_REQUEST_NODE:
      return ParamsHaveOnly(params, {"objectId"});
    case SHAAR_DEVTOOLS_DOM_GET_BOX_MODEL:
      return ParamsHaveOnly(params, {"nodeId", "backendNodeId", "objectId"});
    case SHAAR_DEVTOOLS_CSS_GET_MATCHED_STYLES_FOR_NODE:
      return ParamsHaveOnly(params, {"nodeId", "includePseudo", "includeInherited",
          "includeImportant", "nodeForPopover", "navigateContext"});
    case SHAAR_DEVTOOLS_CSS_GET_PLATFORM_FONTS_FOR_NODE:
    case SHAAR_DEVTOOLS_CSS_GET_BACKGROUND_COLORS:
    case SHAAR_DEVTOOLS_CSS_GET_COMPUTED_STYLE_FOR_NODE:
      return ParamsHaveOnly(params, {"nodeId"});
    case SHAAR_DEVTOOLS_CSS_GET_STYLESHEET_TEXT:
      return ParamsHaveOnly(params, {"styleSheetId"});
    case SHAAR_DEVTOOLS_PAGE_GET_RESOURCE_CONTENT:
      return ParamsHaveOnly(params, {"frameId", "url"});
    case SHAAR_DEVTOOLS_PAGE_CAPTURE_SCREENSHOT:
      return ParamsHaveOnly(params, {"format", "quality", "clip", "fromSurface",
          "captureBeyondViewport", "optimizeForSpeed"});
    case SHAAR_DEVTOOLS_OVERLAY_SET_SHOW_GRID_OVERLAYS:
      return ParamsHaveOnly(params, {"gridNodeHighlightConfigs"});
    case SHAAR_DEVTOOLS_OVERLAY_SET_SHOW_FLEX_OVERLAYS:
      return ParamsHaveOnly(params, {"flexNodeHighlightConfigs"});
    case SHAAR_DEVTOOLS_DOM_DESCRIBE_NODE:
      return ParamsHaveOnly(params, {"nodeId", "backendNodeId", "objectId", "depth",
          "pierce"});
    case SHAAR_DEVTOOLS_ACCESSIBILITY_GET_PARTIAL_AX_TREE:
      return ParamsHaveOnly(params, {"objectId", "backendNodeId", "nodeId",
          "fetchRelatives"});
    case SHAAR_DEVTOOLS_EMULATION_SET_DEVICE_METRICS_OVERRIDE:
      return ParamsHaveOnly(params, {"width", "height", "deviceScaleFactor",
          "mobile", "scale", "screenWidth", "screenHeight", "positionX",
          "positionY", "dontSetVisibleSize", "screenOrientation", "viewport"});
    case SHAAR_DEVTOOLS_NETWORK_EMULATE_NETWORK_CONDITIONS:
      return ParamsHaveOnly(params, {"offline", "latency", "downloadThroughput",
          "uploadThroughput", "connectionType", "packetLoss", "packetQueueLength",
          "packetReordering"});
    case SHAAR_DEVTOOLS_EMULATION_SET_CPU_THROTTLING_RATE:
      return ParamsHaveOnly(params, {"rate"});
    case SHAAR_DEVTOOLS_EMULATION_SET_GEOLOCATION_OVERRIDE:
      return ParamsHaveOnly(params, {"latitude", "longitude", "accuracy",
          "altitude", "altitudeAccuracy", "heading", "speed"});
    case SHAAR_DEVTOOLS_EMULATION_SET_TIMEZONE_OVERRIDE:
      return ParamsHaveOnly(params, {"timezoneId"});
    case SHAAR_DEVTOOLS_EMULATION_SET_LOCALE_OVERRIDE:
      return ParamsHaveOnly(params, {"locale"});
    case SHAAR_DEVTOOLS_EMULATION_SET_USER_AGENT_OVERRIDE:
      return ParamsHaveOnly(params, {"userAgent", "acceptLanguage", "platform",
          "userAgentMetadata"});
    case SHAAR_DEVTOOLS_EMULATION_SET_EMULATED_MEDIA:
      return ParamsHaveOnly(params, {"media", "features"});
    case SHAAR_DEVTOOLS_PAGE_ADD_SCRIPT_TO_EVALUATE_ON_NEW_DOCUMENT:
      return ParamsHaveOnly(params, {"source", "worldName", "includeCommandLineAPI",
          "runImmediately", "worldContextId"});
    case SHAAR_DEVTOOLS_PAGE_REMOVE_SCRIPT_TO_EVALUATE_ON_NEW_DOCUMENT:
      return ParamsHaveOnly(params, {"identifier"});
    case SHAAR_DEVTOOLS_NETWORK_GET_COOKIES:
    case SHAAR_DEVTOOLS_NETWORK_SET_COOKIE:
    case SHAAR_DEVTOOLS_NETWORK_DELETE_COOKIES:
      return false;
  }
  return false;
}

bool HasRequiredString(const base::Value::Dict& params,
                       std::string_view key) {
  const std::string* value = params.FindString(key);
  return value && !value->empty();
}

bool HasRequiredInteger(const base::Value::Dict& params,
                        std::string_view key) {
  return params.FindInt(key).has_value();
}

bool HasRequiredBoolean(const base::Value::Dict& params,
                        std::string_view key) {
  return params.FindBool(key).has_value();
}

bool HasNumericValue(const base::Value::Dict& params,
                     std::string_view key) {
  const base::Value* value = params.Find(key);
  return value && (value->is_int() || value->is_double());
}

bool HasRequiredFields(shaar_devtools_command command,
                       const base::Value::Dict& params) {
  switch (command) {
    case SHAAR_DEVTOOLS_RUNTIME_EVALUATE:
      return HasRequiredString(params, "expression");
    case SHAAR_DEVTOOLS_RUNTIME_RELEASE_OBJECT:
    case SHAAR_DEVTOOLS_RUNTIME_GET_PROPERTIES:
      return HasRequiredString(params, "objectId");
    case SHAAR_DEVTOOLS_RUNTIME_RELEASE_OBJECT_GROUP:
      return HasRequiredString(params, "objectGroup");
    case SHAAR_DEVTOOLS_DOM_GET_BOX_MODEL:
      return HasRequiredInteger(params, "nodeId") ||
             HasRequiredInteger(params, "backendNodeId") ||
             HasRequiredString(params, "objectId");
    case SHAAR_DEVTOOLS_DOM_REQUEST_NODE:
      return HasRequiredString(params, "objectId");
    case SHAAR_DEVTOOLS_CSS_GET_MATCHED_STYLES_FOR_NODE:
    case SHAAR_DEVTOOLS_CSS_GET_PLATFORM_FONTS_FOR_NODE:
    case SHAAR_DEVTOOLS_CSS_GET_BACKGROUND_COLORS:
    case SHAAR_DEVTOOLS_CSS_GET_COMPUTED_STYLE_FOR_NODE:
      return HasRequiredInteger(params, "nodeId");
    case SHAAR_DEVTOOLS_CSS_GET_STYLESHEET_TEXT:
      return HasRequiredString(params, "styleSheetId");
    case SHAAR_DEVTOOLS_PAGE_GET_RESOURCE_CONTENT:
      return HasRequiredString(params, "frameId") &&
             HasRequiredString(params, "url");
    case SHAAR_DEVTOOLS_OVERLAY_SET_SHOW_GRID_OVERLAYS:
      return params.FindList("gridNodeHighlightConfigs") != nullptr;
    case SHAAR_DEVTOOLS_OVERLAY_SET_SHOW_FLEX_OVERLAYS:
      return params.FindList("flexNodeHighlightConfigs") != nullptr;
    case SHAAR_DEVTOOLS_DOM_DESCRIBE_NODE:
    case SHAAR_DEVTOOLS_ACCESSIBILITY_GET_PARTIAL_AX_TREE:
      return HasRequiredInteger(params, "nodeId") ||
             HasRequiredInteger(params, "backendNodeId") ||
             HasRequiredString(params, "objectId");
    case SHAAR_DEVTOOLS_EMULATION_SET_DEVICE_METRICS_OVERRIDE:
      return HasRequiredInteger(params, "width") &&
             HasRequiredInteger(params, "height") &&
             HasNumericValue(params, "deviceScaleFactor") &&
             HasRequiredBoolean(params, "mobile");
    case SHAAR_DEVTOOLS_NETWORK_EMULATE_NETWORK_CONDITIONS:
      return params.FindBool("offline").has_value() &&
             HasNumericValue(params, "latency") &&
             HasNumericValue(params, "downloadThroughput") &&
             HasNumericValue(params, "uploadThroughput");
    case SHAAR_DEVTOOLS_EMULATION_SET_CPU_THROTTLING_RATE:
      return HasNumericValue(params, "rate");
    case SHAAR_DEVTOOLS_EMULATION_SET_GEOLOCATION_OVERRIDE:
      return HasNumericValue(params, "latitude") &&
             HasNumericValue(params, "longitude") &&
             HasNumericValue(params, "accuracy");
    case SHAAR_DEVTOOLS_EMULATION_SET_TIMEZONE_OVERRIDE:
      return HasRequiredString(params, "timezoneId");
    case SHAAR_DEVTOOLS_EMULATION_SET_LOCALE_OVERRIDE:
      return HasRequiredString(params, "locale");
    case SHAAR_DEVTOOLS_EMULATION_SET_USER_AGENT_OVERRIDE:
      return HasRequiredString(params, "userAgent");
    case SHAAR_DEVTOOLS_EMULATION_SET_EMULATED_MEDIA:
      return params.FindString("media") != nullptr ||
             params.FindList("features") != nullptr;
    case SHAAR_DEVTOOLS_PAGE_ADD_SCRIPT_TO_EVALUATE_ON_NEW_DOCUMENT:
      return HasRequiredString(params, "source");
    case SHAAR_DEVTOOLS_PAGE_REMOVE_SCRIPT_TO_EVALUATE_ON_NEW_DOCUMENT:
      return HasRequiredString(params, "identifier");
    default:
      return true;
  }
}

bool HasEmptyVersionedSchema(shaar_bytes args_json) {
  if (!args_json.data || args_json.size == 0 ||
      args_json.size > kMaxArgumentsBytes)
    return false;
  auto parsed = base::JSONReader::Read(
      std::string_view(args_json.data, args_json.size));
  if (!parsed || !parsed->is_dict())
    return false;
  const auto& root = parsed->GetDict();
  return ExactKeys(root, {"schemaVersion", "profileID", "sessionID",
                          "windowID", "tabID"}) &&
         root.FindInt("schemaVersion") == 1 &&
         root.FindString("profileID") && !root.FindString("profileID")->empty() &&
         root.FindString("sessionID") && root.FindString("windowID") &&
         !root.FindString("windowID")->empty() && root.FindString("tabID") &&
         !root.FindString("tabID")->empty();
}

bool DecodeRequestedIdentity(shaar_bytes args_json,
                             DevToolsTargetIdentity* requested) {
  if (!requested || !args_json.data || args_json.size <= 0 ||
      args_json.size > kMaxArgumentsBytes)
    return false;
  auto parsed = base::JSONReader::Read(
      std::string_view(args_json.data, args_json.size));
  if (!parsed || !parsed->is_dict())
    return false;
  const auto& root = parsed->GetDict();
  const std::string* profile = root.FindString("profileID");
  const std::string* session = root.FindString("sessionID");
  const std::string* window = root.FindString("windowID");
  const std::string* tab = root.FindString("tabID");
  if (!profile || profile->empty() || !session || !window || window->empty() ||
      !tab || tab->empty())
    return false;
  *requested = {*profile, *session, *window, *tab};
  return true;
}

bool DecodeDockRequest(shaar_bytes args_json,
                       uint32_t* dock_side,
                       int* extent) {
  if (!args_json.data || args_json.size <= 0 || !dock_side || !extent)
    return false;
  auto parsed = base::JSONReader::Read(
      std::string_view(args_json.data, args_json.size));
  if (!parsed || !parsed->is_dict())
    return false;
  const auto& root = parsed->GetDict();
  const auto version = root.FindInt("schemaVersion");
  const auto side = root.FindInt("dockSide");
  const auto requested_extent = root.FindInt("extent");
  if (!ExactKeys(root, {"schemaVersion", "profileID", "sessionID", "windowID",
                        "tabID", "dockSide", "extent"}) ||
      !version || *version != 1 || !side || *side < SHAAR_DEVTOOLS_DOCK_RIGHT ||
      *side > SHAAR_DEVTOOLS_DOCK_UNDOCKED || !requested_extent ||
      *requested_extent < 100 || *requested_extent > 4096)
    return false;
  *dock_side = static_cast<uint32_t>(*side);
  *extent = *requested_extent;
  return true;
}

uint32_t DockSideValue(Profile* profile) {
  switch (DevToolsSettings::GetDockSide(profile)) {
    case devtools::DockSide::kRight:
      return SHAAR_DEVTOOLS_DOCK_RIGHT;
    case devtools::DockSide::kBottom:
      return SHAAR_DEVTOOLS_DOCK_BOTTOM;
    case devtools::DockSide::kLeft:
      return SHAAR_DEVTOOLS_DOCK_LEFT;
    case devtools::DockSide::kNone:
      return SHAAR_DEVTOOLS_DOCK_UNDOCKED;
  }
  return SHAAR_DEVTOOLS_DOCK_RIGHT;
}

int DockExtent(Profile* profile) {
  DevToolsSettings settings(profile);
  settings.Register("shaarDockExtent",
                    {RegisterOptions::SyncMode::kDontSync});
  const auto value = settings.Get("shaarDockExtent");
  if (!value || !value->is_string())
    return 0;
  int extent = 0;
  if (!base::StringToInt(value->GetString(), &extent) || extent < 0 ||
      extent > 4096)
    return 0;
  return extent;
}

void SetDockState(Profile* profile, uint32_t dock_side, int extent) {
  DevToolsSettings settings(profile);
  settings.Register("currentDockState",
                    {RegisterOptions::SyncMode::kDontSync});
  settings.Register("shaarDockExtent",
                    {RegisterOptions::SyncMode::kDontSync});
  const char* setting = "\"right\"";
  switch (dock_side) {
    case SHAAR_DEVTOOLS_DOCK_BOTTOM:
      setting = "\"bottom\"";
      break;
    case SHAAR_DEVTOOLS_DOCK_LEFT:
      setting = "\"left\"";
      break;
    case SHAAR_DEVTOOLS_DOCK_UNDOCKED:
      setting = "\"undocked\"";
      break;
    default:
      break;
  }
  settings.Set("currentDockState", setting);
  settings.Set("shaarDockExtent", base::NumberToString(extent));
}

class ContextDevToolsRuntime final : public DevToolsRuntimeServices {
 public:
  bool ResolveTarget(shaar_engine* engine,
                     shaar_scope scope,
                     shaar_window* window,
                     shaar_tab* tab,
                     content::WebContents* contents,
                     const DevToolsTargetIdentity& requested,
                     DevToolsTargetIdentity* identity) override {
    ShaarEngineContext& context = EngineContext();
    if (!engine || !window || !tab || !contents || !identity ||
        !context.browser_tabs || requested.window_id.empty() ||
        requested.tab_id.empty() ||
        context.browser_tabs->FindWebContents(engine, window, tab) != contents ||
        context.browser_tabs->TabID(engine, window, tab) != requested.tab_id)
      return false;

    if (scope.profile) {
      if (!context.profile_services || !requested.session_id.empty())
        return false;
      Profile* profile = context.profile_services->ResolveProfile(engine,
                                                                   scope.profile);
      if (!profile || contents->GetBrowserContext() != profile ||
          context.profile_services->ProfileID(engine, scope.profile) !=
              requested.profile_id)
        return false;
      *identity = {requested.profile_id, {}, requested.window_id,
                   requested.tab_id};
      return true;
    }

    // Private session handles are opaque and must be resolved by the owning
    // private-session service. Until that service is part of ShaarEngineContext,
    // refusing private DevTools is safer than trusting the caller's session ID.
    return false;
  }

  bool IsOperationAllowed(shaar_engine*,
                          shaar_scope scope,
                          content::WebContents* contents,
                          shaar_operation operation,
                          int capability) override {
    if (!scope.profile || scope.private_session || !contents ||
        (operation != SHAAR_OP_DEVTOOLS_CALL &&
         operation != SHAAR_OP_DEVTOOLS_UI_SHOW &&
         operation != SHAAR_OP_DEVTOOLS_UI_CLOSE &&
         operation != SHAAR_OP_DEVTOOLS_UI_STATE &&
         operation != SHAAR_OP_DEVTOOLS_UI_SET_DOCK) ||
        (operation == SHAAR_OP_DEVTOOLS_CALL && capability != kInspector &&
         capability != kDeveloper))
      return false;
    Profile* profile = Profile::FromBrowserContext(contents->GetBrowserContext());
    return profile && !profile->IsOffTheRecord() &&
           DevToolsWindow::AllowDevToolsFor(profile, contents);
  }
};

DevToolsRuntimeServices& ContextRuntime() {
  static base::NoDestructor<ContextDevToolsRuntime> runtime;
  return *runtime;
}

using PendingKey = std::pair<shaar_engine*, shaar_request_id>;
class ProtocolClient;
std::map<PendingKey, ProtocolClient*>* PendingRequests() {
  static base::NoDestructor<std::map<PendingKey, ProtocolClient*>> requests;
  return requests.get();
}

class ProtocolClient final : public content::DevToolsAgentHostClient,
                             public content::WebContentsObserver {
 public:
  ProtocolClient(scoped_refptr<content::DevToolsAgentHost> host,
                 content::WebContents* contents,
                 ReplyContext request,
                 std::function<bool()> target_is_current)
      : content::WebContentsObserver(contents),
        host_(std::move(host)),
        request_(request),
        target_is_current_(std::move(target_is_current)) {}

  bool Start(const std::string& protocol_request) {
    if (!host_->AttachClient(this))
      return false;
    attached_ = true;
    (*PendingRequests())[PendingKey(request_.engine, request_.request_id)] = this;
    timer_.Start(FROM_HERE, base::Seconds(15), this,
                 &ProtocolClient::OnTimeout);
    host_->DispatchProtocolMessage(
        this, base::as_byte_span(protocol_request));
    return true;
  }

  void DispatchProtocolMessage(content::DevToolsAgentHost*,
                               base::span<const uint8_t> message) override {
    const std::string_view input(reinterpret_cast<const char*>(message.data()),
                                 message.size());
    auto parsed = base::JSONReader::Read(input);
    if (!parsed || !parsed->is_dict()) {
      Finish(SHAAR_CHROMIUM_ERROR, {}, "invalid protocol response");
      return;
    }
    const base::Value::Dict& dict = parsed->GetDict();
    const auto response_id = dict.FindInt("id");
    if (!response_id || *response_id != static_cast<int>(request_.request_id))
      return;
    if (!target_is_current_ || !target_is_current_()) {
      Finish(SHAAR_NOT_FOUND, {}, "DevTools target changed before response");
      return;
    }
    if (dict.Find("error")) {
      Finish(SHAAR_CHROMIUM_ERROR, {}, "protocol command failed");
      return;
    }
    const base::Value::Dict* result = dict.FindDict("result");
    if (!result) {
      Finish(SHAAR_CHROMIUM_ERROR, {}, "protocol response has no result");
      return;
    }
    base::Value::Dict wrapped;
    wrapped.Set("schemaVersion", 1);
    wrapped.Set("result", result->Clone());
    std::string output;
    base::JSONWriter::Write(base::Value(std::move(wrapped)), &output);
    Finish(SHAAR_OK, std::move(output), {});
  }

  void AgentHostClosed(content::DevToolsAgentHost*) override {
    attached_ = false;
    Finish(SHAAR_NOT_FOUND, {}, "DevTools target closed");
  }

  void DidFinishNavigation(content::NavigationHandle* navigation) override {
    if (navigation->HasCommitted() && navigation->IsInPrimaryMainFrame())
      Finish(SHAAR_CANCELLED, {}, "DevTools request canceled by navigation");
  }

  void WebContentsDestroyed() override {
    Finish(SHAAR_NOT_FOUND, {}, "DevTools target closed");
  }

  void Cancel() {
    Finish(SHAAR_CANCELLED, {}, "DevTools request canceled");
  }

 private:
  void OnTimeout() {
    Finish(SHAAR_NOT_READY, {}, "DevTools protocol request timed out");
  }

  void Finish(shaar_error_code code, std::string payload,
              std::string message) {
    if (finished_)
      return;
    finished_ = true;
    PendingRequests()->erase(PendingKey(request_.engine, request_.request_id));
    if (attached_) {
      attached_ = false;
      host_->DetachClient(this);
    }
    Reply(request_, code, std::move(payload), std::move(message));
    delete this;
  }

  scoped_refptr<content::DevToolsAgentHost> host_;
  ReplyContext request_;
  std::function<bool()> target_is_current_;
  base::OneShotTimer timer_;
  bool attached_ = false;
  bool finished_ = false;
};

shaar_error_code DecodeOperation(shaar_operation operation,
                                 shaar_bytes args_json,
                                 shaar_devtools_capability* capability,
                                 shaar_devtools_command* command,
                                 base::Value::Dict* params,
                                 std::string* reason) {
  if (!args_json.data || args_json.size == 0 || args_json.size > kMaxArgumentsBytes) {
    *reason = "invalid DevTools arguments";
    return SHAAR_INVALID_ARGUMENT;
  }
  auto parsed = base::JSONReader::Read(
      std::string_view(args_json.data, args_json.size));
  if (!parsed || !parsed->is_dict()) {
    *reason = "invalid DevTools JSON";
    return SHAAR_INVALID_ARGUMENT;
  }
  const auto& root = parsed->GetDict();
  const bool command_schema =
      ExactKeys(root, {"schemaVersion", "capability", "command", "params"}) ||
      ExactKeys(root, {"schemaVersion", "capability", "command", "params",
                       "profileID", "sessionID", "windowID", "tabID"});
  if (operation != SHAAR_OP_DEVTOOLS_CALL || !command_schema ||
      root.FindInt("schemaVersion") != 1 ||
      !root.FindInt("capability") || !root.FindInt("command") ||
      !root.FindDict("params")) {
    *reason = "invalid DevTools call schema";
    return SHAAR_INVALID_ARGUMENT;
  }
  const int cap = *root.FindInt("capability");
  const int id = *root.FindInt("command");
  if ((cap != kInspector && cap != kDeveloper) || id < 1 || id > 43) {
    *reason = "unknown DevTools capability or command";
    return SHAAR_INVALID_ARGUMENT;
  }
  *capability = static_cast<shaar_devtools_capability>(cap);
  *command = static_cast<shaar_devtools_command>(id);
  if (!ProtocolMethod(*capability, *command)) {
    *reason = "DevTools command is not allowed for this capability";
    return SHAAR_UNSUPPORTED_CAPABILITY;
  }
  if (!ValidateParams(*command, *root.FindDict("params"))) {
    *reason = "DevTools command parameters are invalid";
    return SHAAR_INVALID_ARGUMENT;
  }
  if (!HasRequiredFields(*command, *root.FindDict("params"))) {
    *reason = "DevTools command is missing required parameters";
    return SHAAR_INVALID_ARGUMENT;
  }
  *params = root.FindDict("params")->Clone();
  return SHAAR_OK;
}

}  // namespace

const char* ProtocolMethod(shaar_devtools_capability capability,
                           shaar_devtools_command command) {
  for (const auto& entry : kCommands) {
    if (entry.command != command)
      continue;
    if ((capability == SHAAR_DEVTOOLS_CAPABILITY_INSPECTOR && entry.inspector) ||
        (capability == SHAAR_DEVTOOLS_CAPABILITY_DEVELOPER && entry.developer))
      return entry.method;
  }
  return nullptr;
}

bool IsValidTargetIdentity(shaar_scope scope,
                           std::string_view registered_tab_id,
                           const DevToolsTargetIdentity& identity) {
  if ((scope.profile == nullptr) == (scope.private_session == nullptr) ||
      identity.profile_id.empty() || identity.window_id.empty() ||
      identity.tab_id.empty() || identity.tab_id != registered_tab_id)
    return false;
  if (identity.profile_id.find('\0') != std::string::npos ||
      identity.session_id.find('\0') != std::string::npos ||
      identity.window_id.find('\0') != std::string::npos ||
      identity.tab_id.find('\0') != std::string::npos)
    return false;
  return scope.private_session ? !identity.session_id.empty()
                               : identity.session_id.empty();
}

bool PolicyAllowsOperation(DevToolsRuntimeServices* runtime,
                           shaar_engine* engine,
                           shaar_scope scope,
                           content::WebContents* contents,
                           shaar_operation operation,
                           int capability) {
  if (!runtime || !engine || !contents)
    return false;
  switch (operation) {
    case SHAAR_OP_DEVTOOLS_CALL:
    case SHAAR_OP_DEVTOOLS_UI_SHOW:
    case SHAAR_OP_DEVTOOLS_UI_CLOSE:
    case SHAAR_OP_DEVTOOLS_UI_STATE:
    case SHAAR_OP_DEVTOOLS_UI_SET_DOCK:
      break;
    case SHAAR_OP_DEVTOOLS_CONTROL_ENABLE:
    case SHAAR_OP_DEVTOOLS_CONTROL_DISABLE:
    case SHAAR_OP_DEVTOOLS_CONTROL_STATUS:
    default:
      return false;
  }
  if ((operation == SHAAR_OP_DEVTOOLS_CALL && capability != kInspector &&
       capability != kDeveloper) ||
      (operation != SHAAR_OP_DEVTOOLS_CALL && capability != 0))
    return false;
  return runtime->IsOperationAllowed(engine, scope, contents, operation,
                                     capability);
}

shaar_error_code CancelDevToolsRequest(shaar_engine* engine,
                                       shaar_request_id request_id,
                                       shaar_error* error) {
  auto found = PendingRequests()->find(PendingKey(engine, request_id));
  if (found == PendingRequests()->end())
    return Fail(error, SHAAR_NOT_FOUND, "DevTools request is not pending");
  found->second->Cancel();
  return SHAAR_OK;
}

void InstallContextRuntimeServices() {
  SetDevToolsRuntimeServices(&ContextRuntime());
}

shaar_error_code EncodeProtocolRequest(shaar_bytes args_json,
                                       shaar_request_id request_id,
                                       std::string* request_json,
                                       std::string* reason) {
  if (!request_json || !reason || request_id == 0 ||
      request_id > static_cast<uint64_t>(INT_MAX))
    return SHAAR_INVALID_ARGUMENT;
  shaar_devtools_capability capability;
  shaar_devtools_command command;
  base::Value::Dict params;
  const auto status = DecodeOperation(SHAAR_OP_DEVTOOLS_CALL, args_json,
                                      &capability, &command, &params, reason);
  if (status != SHAAR_OK)
    return status;
  base::Value::Dict protocol;
  protocol.Set("id", static_cast<int64_t>(request_id));
  protocol.Set("method", ProtocolMethod(capability, command));
  protocol.Set("params", std::move(params));
  if (!base::JSONWriter::Write(base::Value(std::move(protocol)), request_json)) {
    *reason = "could not serialize DevTools command";
    return SHAAR_INVALID_ARGUMENT;
  }
  return SHAAR_OK;
}

void EmitFrontendStateEvent(shaar_engine* engine,
                            const DevToolsTargetIdentity& identity,
                            bool open,
                            uint32_t dock_side,
                            int extent) {
  if (identity.profile_id.empty() || identity.window_id.empty() ||
      identity.tab_id.empty())
    return;
  char payload[sizeof(kFrontendStateEvent) + 32];
  const int length = std::snprintf(payload, sizeof(payload), kFrontendStateEvent,
                                   open ? "true" : "false", dock_side,
                                   extent);
  if (length <= 0 || static_cast<size_t>(length) >= sizeof(payload))
    return;
  const shaar_bytes profile{identity.profile_id.data(), identity.profile_id.size()};
  const shaar_bytes session{identity.session_id.data(), identity.session_id.size()};
  const shaar_bytes window{identity.window_id.data(), identity.window_id.size()};
  const shaar_bytes tab{identity.tab_id.data(), identity.tab_id.size()};
  const shaar_bytes body{payload, static_cast<size_t>(length)};
  EmitEvent(engine, SHAAR_EVENT_DEVTOOLS, profile, session, window, tab, body);
}

shaar_error_code HandleDevToolsOperation(
    shaar::ShaarEngineContext* context,
    shaar_engine* engine,
    shaar_scope scope,
    shaar_window* window,
    shaar_tab* tab,
    shaar_operation operation,
    shaar_bytes args_json,
    shaar_request_id request_id,
    shaar_reply_fn reply,
    void* reply_context,
    shaar_error* error) {
  if (!context || !context->browser_tabs || !engine || !window || !tab ||
      !reply || !request_id)
    return Fail(error, SHAAR_INVALID_ARGUMENT, "missing DevTools owner");
  content::WebContents* contents =
      context->browser_tabs->FindWebContents(engine, window, tab);
  if (!contents)
    return Fail(error, SHAAR_NOT_FOUND, "DevTools target is not available");

  // The window/tab registry establishes the exact owner pair. Regular-profile
  // scopes are additionally checked against the resolved Chromium Profile.
  if (scope.size < sizeof(shaar_scope) ||
      (scope.profile == nullptr) == (scope.private_session == nullptr))
    return Fail(error, SHAAR_INVALID_ARGUMENT, "invalid DevTools scope");
  if (scope.profile) {
    Profile* profile = context->profile_services
                           ? context->profile_services->ResolveProfile(engine,
                                                                        scope.profile)
                           : nullptr;
    if (!profile)
      return Fail(error, SHAAR_NOT_FOUND, "DevTools profile is unavailable");
    if (contents->GetBrowserContext() != profile)
      return Fail(error, SHAAR_WRONG_PROFILE, "DevTools tab is outside profile scope");
  } else {
    if (!context->devtools_runtime)
      return Fail(error, SHAAR_NOT_READY,
                  "DevTools runtime services are unavailable");
    Profile* target_profile =
        contents->GetBrowserContext()
            ? Profile::FromBrowserContext(contents->GetBrowserContext())
            : nullptr;
    if (!target_profile || !target_profile->IsOffTheRecord())
      return Fail(error, SHAAR_WRONG_SESSION,
                  "DevTools tab is outside private scope");
  }

  if (!context->devtools_runtime)
    return Fail(error, SHAAR_NOT_READY,
                "DevTools runtime services are unavailable");
  DevToolsTargetIdentity requested;
  if (!DecodeRequestedIdentity(args_json, &requested))
    return Fail(error, SHAAR_INVALID_ARGUMENT,
                "DevTools target identity is invalid");
  DevToolsTargetIdentity identity;
  if (!context->devtools_runtime->ResolveTarget(engine, scope, window, tab,
                                                contents, requested, &identity))
    return Fail(error, scope.private_session ? SHAAR_WRONG_SESSION
                                             : SHAAR_WRONG_PROFILE,
                "DevTools target is outside the requested scope");
  if (!IsValidTargetIdentity(
          scope, context->browser_tabs->TabID(engine, window, tab), identity))
    return Fail(error, SHAAR_WRONG_SESSION,
                "DevTools target identity is incomplete or inconsistent");
  if (scope.profile && context->profile_services &&
      identity.profile_id != context->profile_services->ProfileID(engine,
                                                                  scope.profile))
    return Fail(error, SHAAR_WRONG_PROFILE,
                "DevTools profile identity does not match the requested scope");

  int capability = 0;
  if (operation == SHAAR_OP_DEVTOOLS_CALL) {
    shaar_devtools_capability parsed_capability;
    shaar_devtools_command parsed_command;
    base::Value::Dict params;
    std::string reason;
    const shaar_error_code decode_status = DecodeOperation(
        operation, args_json, &parsed_capability, &parsed_command, &params,
        &reason);
    if (decode_status != SHAAR_OK)
      return Fail(error, decode_status, reason.c_str());
    capability = static_cast<int>(parsed_capability);
  }
  if (!PolicyAllowsOperation(context->devtools_runtime, engine, scope,
                              contents, operation, capability))
    return Fail(error, SHAAR_POLICY_BLOCKED,
                "DevTools operation is blocked by runtime policy");

  const ReplyContext request{engine, request_id, reply, reply_context};
  if (operation == SHAAR_OP_DEVTOOLS_CALL) {
    std::string protocol_request;
    std::string reason;
    const shaar_error_code status =
        EncodeProtocolRequest(args_json, request_id, &protocol_request, &reason);
    if (status != SHAAR_OK)
      return Fail(error, status, reason.c_str());
    auto host = content::DevToolsAgentHost::GetOrCreateForTab(contents);
    if (!host || host->GetWebContents() != contents)
      return Fail(error, SHAAR_NOT_READY, "DevTools protocol target is unavailable");
    auto target_is_current = [context, engine, scope, window, tab, contents,
                              requested, identity]() {
      DevToolsTargetIdentity current;
      return context->devtools_runtime &&
             context->devtools_runtime->ResolveTarget(
                 engine, scope, window, tab, contents, requested, &current) &&
             current.profile_id == identity.profile_id &&
             current.session_id == identity.session_id &&
             current.window_id == identity.window_id &&
             current.tab_id == identity.tab_id;
    };
    auto* client = new ProtocolClient(std::move(host), contents, request,
                                      std::move(target_is_current));
    if (!client->Start(protocol_request)) {
      delete client;
      return Fail(error, SHAAR_NOT_READY, "DevTools protocol attach was denied");
    }
    return SHAAR_OK;
  }

  if (operation == SHAAR_OP_DEVTOOLS_UI_SHOW ||
      operation == SHAAR_OP_DEVTOOLS_UI_CLOSE ||
      operation == SHAAR_OP_DEVTOOLS_UI_STATE ||
      operation == SHAAR_OP_DEVTOOLS_CONTROL_ENABLE ||
      operation == SHAAR_OP_DEVTOOLS_CONTROL_DISABLE ||
      operation == SHAAR_OP_DEVTOOLS_CONTROL_STATUS) {
    if (!HasEmptyVersionedSchema(args_json))
      return Fail(error, SHAAR_INVALID_ARGUMENT,
                  "invalid DevTools operation schema");
  }
  uint32_t requested_dock_side = 0;
  int requested_extent = 0;
  if (operation == SHAAR_OP_DEVTOOLS_UI_SET_DOCK &&
      !DecodeDockRequest(args_json, &requested_dock_side, &requested_extent))
    return Fail(error, SHAAR_INVALID_ARGUMENT,
                "invalid DevTools dock schema");

  Profile* profile = scope.profile && context->profile_services
                         ? context->profile_services->ResolveProfile(
                               engine, scope.profile)
                         : nullptr;
  if (!profile)
    return Fail(error, SHAAR_WRONG_PROFILE,
                "DevTools UI requires a regular profile");

  const bool frontend_was_open =
      DevToolsWindow::GetInstanceForInspectedWebContents(contents) != nullptr;
  const uint32_t old_dock_side = DockSideValue(profile);
  const int old_extent = DockExtent(profile);
  if (operation == SHAAR_OP_DEVTOOLS_UI_SHOW) {
    if (old_dock_side == SHAAR_DEVTOOLS_DOCK_UNDOCKED)
      SetDockState(profile, SHAAR_DEVTOOLS_DOCK_RIGHT, old_extent);
    DevToolsWindow::OpenDevToolsWindow(contents, DevToolsOpenedByAction::kUnknown);
    if (auto* devtools = DevToolsWindow::GetInstanceForInspectedWebContents(contents))
      devtools->SetIsDocked(true);
  } else if (operation == SHAAR_OP_DEVTOOLS_UI_CLOSE) {
    if (auto* devtools = DevToolsWindow::GetInstanceForInspectedWebContents(contents))
      devtools->Close(DevToolsClosedByAction::kUnknown);
  } else if (operation == SHAAR_OP_DEVTOOLS_UI_STATE) {
    const bool open =
        DevToolsWindow::GetInstanceForInspectedWebContents(contents) != nullptr;
    const uint32_t dock_side = DockSideValue(profile);
    const int extent = DockExtent(profile);
    char json[128];
    const int length = std::snprintf(
        json, sizeof(json),
        "{\"schemaVersion\":1,\"open\":%s,\"dockSide\":%u,\"extent\":%d}",
        open ? "true" : "false", dock_side, extent);
    if (length <= 0 || static_cast<size_t>(length) >= sizeof(json))
      return Fail(error, SHAAR_CHROMIUM_ERROR,
                  "could not serialize DevTools state");
    std::string payload(json, static_cast<size_t>(length));
    Reply(request, SHAAR_OK, std::move(payload));
    return SHAAR_OK;
  } else if (operation == SHAAR_OP_DEVTOOLS_UI_SET_DOCK) {
    SetDockState(profile, requested_dock_side, requested_extent);
    if (auto* devtools = DevToolsWindow::GetInstanceForInspectedWebContents(contents))
      devtools->SetIsDocked(requested_dock_side != SHAAR_DEVTOOLS_DOCK_UNDOCKED);
  } else if (operation == SHAAR_OP_DEVTOOLS_CONTROL_ENABLE ||
             operation == SHAAR_OP_DEVTOOLS_CONTROL_DISABLE ||
             operation == SHAAR_OP_DEVTOOLS_CONTROL_STATUS) {
    // Shaar does not expose remote debugging until the tab-bound auth and
    // docking hooks are available. Chromium's global remote server is never
    // started by these operations.
    return Fail(error, SHAAR_UNSUPPORTED_CAPABILITY,
                "DevTools remote control or docking is not available");
  } else {
    return Fail(error, SHAAR_INVALID_ARGUMENT, "unknown DevTools operation");
  }
  const bool frontend_is_open =
      DevToolsWindow::GetInstanceForInspectedWebContents(contents) != nullptr;
  const uint32_t current_dock_side = DockSideValue(profile);
  const int current_extent = DockExtent(profile);
  if ((operation == SHAAR_OP_DEVTOOLS_UI_SET_DOCK &&
       (old_dock_side != current_dock_side || old_extent != current_extent ||
        frontend_was_open != frontend_is_open)) ||
      ((operation == SHAAR_OP_DEVTOOLS_UI_SHOW ||
        operation == SHAAR_OP_DEVTOOLS_UI_CLOSE) &&
       (frontend_was_open != frontend_is_open ||
        old_dock_side != current_dock_side || old_extent != current_extent))) {
    EmitFrontendStateEvent(engine, identity,
                           frontend_is_open, current_dock_side,
                           current_extent);
  }
  if (operation == SHAAR_OP_DEVTOOLS_UI_SET_DOCK) {
    char json[128];
    const int length = std::snprintf(
        json, sizeof(json),
        "{\"schemaVersion\":1,\"open\":%s,\"dockSide\":%u,\"extent\":%d}",
        frontend_is_open ? "true" : "false", current_dock_side,
        current_extent);
    if (length <= 0 || static_cast<size_t>(length) >= sizeof(json))
      return Fail(error, SHAAR_CHROMIUM_ERROR,
                  "could not serialize DevTools state");
    Reply(request, SHAAR_OK, std::string(json, static_cast<size_t>(length)));
    return SHAAR_OK;
  }
  Reply(request, SHAAR_OK, "{\"schemaVersion\":1}");
  return SHAAR_OK;
}

namespace {
bool ResolveFrontendTarget(shaar_engine* engine,
                           shaar_scope scope,
                           shaar_window* window,
                           shaar_tab* tab,
                           shaar_bytes profile_id,
                           shaar_bytes session_id,
                           shaar_bytes window_id,
                           shaar_bytes tab_id,
                           content::WebContents** contents_out,
                           DevToolsWindow** devtools_out) {
  if (!engine || scope.size < sizeof(shaar_scope) || !window || !tab ||
      (scope.profile == nullptr) == (scope.private_session == nullptr) ||
      !profile_id.data || !profile_id.size || profile_id.size > 256 ||
      !window_id.data || !window_id.size || window_id.size > 256 ||
      !tab_id.data || !tab_id.size || tab_id.size > 256 ||
      session_id.size > 256 ||
      (session_id.size && !session_id.data) || !contents_out || !devtools_out)
    return false;
  ShaarEngineContext& context = EngineContext();
  if (!context.browser_tabs || !context.devtools_runtime)
    return false;
  content::WebContents* contents =
      context.browser_tabs->FindWebContents(engine, window, tab);
  if (!contents)
    return false;
  DevToolsTargetIdentity requested{
      std::string(profile_id.data, profile_id.size),
      std::string(session_id.data ? session_id.data : "", session_id.size),
      std::string(window_id.data, window_id.size),
      std::string(tab_id.data, tab_id.size)};
  DevToolsTargetIdentity resolved;
  if (!context.devtools_runtime->ResolveTarget(
          engine, scope, window, tab, contents, requested, &resolved) ||
      !IsValidTargetIdentity(scope,
                             context.browser_tabs->TabID(engine, window, tab),
                             resolved) ||
      !PolicyAllowsOperation(context.devtools_runtime, engine, scope, contents,
                             SHAAR_OP_DEVTOOLS_UI_STATE, 0))
    return false;
  auto* devtools = DevToolsWindow::GetInstanceForInspectedWebContents(contents);
  if (!devtools || !devtools->IsDocked())
    return false;
  *contents_out = contents;
  *devtools_out = devtools;
  return true;
}
}  // namespace

}  // namespace shaar::devtools

extern "C" void* shaar_devtools_frontend_view(
    shaar_engine* engine,
    shaar_scope scope,
    shaar_window* window,
    shaar_tab* tab,
    shaar_bytes profile_id,
    shaar_bytes session_id,
    shaar_bytes window_id,
    shaar_bytes tab_id) {
  content::WebContents* inspected = nullptr;
  DevToolsWindow* devtools = nullptr;
  if (!shaar::devtools::ResolveFrontendTarget(
          engine, scope, window, tab, profile_id, session_id, window_id, tab_id,
          &inspected, &devtools))
    return nullptr;
  DevToolsContentsResizingStrategy strategy;
  content::WebContents* frontend =
      DevToolsWindow::GetInTabWebContents(inspected, &strategy);
  return frontend ? static_cast<void*>(frontend->GetNativeView()) : nullptr;
}

extern "C" shaar_error_code shaar_devtools_set_frontend_bounds(
    shaar_engine* engine,
    shaar_scope scope,
    shaar_window* window,
    shaar_tab* tab,
    shaar_bytes profile_id,
    shaar_bytes session_id,
    shaar_bytes window_id,
    shaar_bytes tab_id,
    int width,
    int height) {
  content::WebContents* inspected = nullptr;
  DevToolsWindow* devtools = nullptr;
  if (!shaar::devtools::ResolveFrontendTarget(
          engine, scope, window, tab, profile_id, session_id, window_id, tab_id,
          &inspected, &devtools))
    return SHAAR_NOT_FOUND;
  if (width < 0 || height < 0 || width > 8192 || height > 8192)
    return SHAAR_INVALID_ARGUMENT;
  devtools->SetInspectedPageBounds(gfx::Rect(0, 0, width, height));
  Profile* profile = Profile::FromBrowserContext(inspected->GetBrowserContext());
  if (!profile)
    return SHAAR_NOT_FOUND;
  const uint32_t dock_side = DockSideValue(profile);
  const int extent = std::min(
      dock_side == SHAAR_DEVTOOLS_DOCK_BOTTOM ? height : width, 4096);
  SetDockState(profile, dock_side, extent);
  const shaar::devtools::DevToolsTargetIdentity identity{
      std::string(profile_id.data, profile_id.size),
      std::string(session_id.data ? session_id.data : "", session_id.size),
      std::string(window_id.data, window_id.size),
      std::string(tab_id.data, tab_id.size)};
  shaar::devtools::EmitFrontendStateEvent(engine, identity, true, dock_side,
                                          extent);
  return SHAAR_OK;
}
