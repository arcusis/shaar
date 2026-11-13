// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#include "chrome/browser/shaar/devtools/shaar_devtools.h"
#include "chrome/browser/shaar/devtools/shaar_agent_bridge.h"
#include "chrome/browser/shaar/devtools/shaar_devtools_panel.h"
#include "chrome/browser/shaar/devtools/shaar_devtools_viewports.h"
#include "chrome/browser/devtools/devtools_settings.h"
#include "chrome/browser/shaar/extensions/shaar_extensions.h"
#include "chrome/browser/shaar/windows_tabs/shaar_windows_tabs.h"

#include <stddef.h>
#include <stdint.h>
#include <limits.h>

#include <cstdio>
#include <algorithm>
#include <cstdlib>
#include <cstring>
#include <initializer_list>
#include <deque>
#include <map>
#include <set>
#include <optional>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

#include "base/base64.h"
#include "base/functional/bind.h"
#include "base/functional/callback_helpers.h"
#include "base/containers/span.h"
#include "base/json/json_reader.h"
#include "base/json/json_writer.h"
#include "base/strings/utf_string_conversions.h"
#include "base/memory/weak_ptr.h"
#include "base/no_destructor.h"
#include "base/task/sequenced_task_runner.h"
#include "base/memory/ref_counted.h"
#include "base/time/time.h"
#include "base/timer/timer.h"
#include "chrome/browser/devtools/devtools_window.h"
#include "chrome/browser/devtools/devtools_ui_bindings.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/shaar/engine/shaar_engine_context.h"
#include "chrome/browser/shaar/engine/shaar_event_bridge.h"
#include "chrome/browser/shaar/lifecycle/shaar_lifecycle.h"
#include "chrome/browser/shaar/windows_tabs/shaar_page_view_binding.h"
#include "chrome/common/pref_names.h"
#include "components/prefs/pref_service.h"
#include "base/values.h"
#include "content/browser/renderer_host/render_widget_host_impl.h"
#include "content/public/browser/devtools_agent_host.h"
#include "content/public/browser/navigation_controller.h"
#include "content/public/browser/render_frame_host.h"
#include "content/public/browser/web_contents.h"
#include "content/public/browser/render_widget_host_view.h"
#include "content/public/browser/render_widget_host.h"
#include "third_party/blink/public/common/input/web_mouse_event.h"
#include "third_party/blink/public/common/input/web_mouse_wheel_event.h"
#include "ui/gfx/geometry/point_f.h"
#include "content/public/browser/visibility.h"
#include "content/public/common/isolated_world_ids.h"
#include "ui/gfx/codec/png_codec.h"
#include "ui/gfx/geometry/size.h"
#include "ui/gfx/image/image.h"
#include "ui/base/page_transition_types.h"
#include "url/gurl.h"

namespace shaar::devtools {
namespace {

constexpr size_t kMaxArgumentsBytes = 1024 * 1024;
constexpr int kInspector = 1;
constexpr int kDeveloper = 2;
constexpr int kPanel = 3;
constexpr base::TimeDelta kProbeCaptureTimeout = base::Seconds(12);
// Chromium drops mouse down while first-paint commit deferral is set.
// That deferral lifts only when a main frame runs after 500ms.
constexpr base::TimeDelta kProbeClickCommitDelay = base::Milliseconds(600);
constexpr base::TimeDelta kProbeClickLeaseHold = base::Milliseconds(50);

class RuntimeServices final : public DevToolsRuntimeServices {
public:
  bool ResolveTarget(shaar_engine *engine, shaar_scope scope,
                     shaar_window *window, shaar_tab *tab,
                     content::WebContents *contents,
                     DevToolsTargetIdentity *identity) override {
    auto &context = shaar::EngineContext();
    if (!engine || !window || !tab || !contents || !identity ||
        !context.browser_tabs ||
        context.browser_tabs->FindWebContents(engine, window, tab) != contents)
      return false;
    const std::string_view window_id =
        context.browser_tabs->WindowID(engine, window);
    const std::string_view tab_id =
        context.browser_tabs->TabID(engine, window, tab);
    if (window_id.empty() || tab_id.empty())
      return false;
    std::string_view profile_id;
    std::string_view session_id;
    Profile *target_profile = nullptr;
    if (scope.profile && !scope.private_session && context.profile_services) {
      target_profile =
          context.profile_services->ResolveProfile(engine, scope.profile);
      profile_id = context.profile_services->ProfileID(engine, scope.profile);
    } else if (scope.private_session && !scope.profile &&
               context.private_sessions) {
      Profile *parent = nullptr;
      context.private_sessions->Resolve(engine, scope.private_session, &parent,
                                        &target_profile, &profile_id,
                                        &session_id);
    }
    if (!target_profile || profile_id.empty() ||
        contents->GetBrowserContext() != target_profile)
      return false;
    *identity = {std::string(profile_id), std::string(session_id),
                 std::string(window_id), std::string(tab_id)};
    return true;
  }

  bool IsOperationAllowed(shaar_engine *engine, shaar_scope scope,
                          content::WebContents *contents,
                          shaar_operation operation, int capability) override {
    if (!engine || !contents ||
        ((scope.profile != nullptr) == (scope.private_session != nullptr)))
      return false;
    if (scope.private_session &&
        (operation == SHAAR_OP_DEVTOOLS_CONTROL_ENABLE ||
         operation == SHAAR_OP_DEVTOOLS_CONTROL_DISABLE))
      return false;
    return operation != SHAAR_OP_DEVTOOLS_CALL || capability == kInspector ||
           capability == kDeveloper || capability == kPanel;
  }
};

RuntimeServices g_runtime_services;
constexpr char kFrontendStateEvent[] =
    "{\"schemaVersion\":1,\"kind\":\"frontendState\",\"open\":%s}";

struct CommandEntry {
  shaar_devtools_command command;
  const char* method;
  bool inspector;
  bool developer;
};

constexpr CommandEntry kCommands[] = {
    {SHAAR_DEVTOOLS_RUNTIME_EVALUATE, "Runtime.evaluate", true, true},
    {SHAAR_DEVTOOLS_RUNTIME_RELEASE_OBJECT, "Runtime.releaseObject", true,
     true},
    {SHAAR_DEVTOOLS_RUNTIME_GET_PROPERTIES, "Runtime.getProperties", true,
     true},
    {SHAAR_DEVTOOLS_RUNTIME_RELEASE_OBJECT_GROUP, "Runtime.releaseObjectGroup",
     true, true},
    {SHAAR_DEVTOOLS_DOM_ENABLE, "DOM.enable", true, false},
    {SHAAR_DEVTOOLS_DOM_GET_DOCUMENT, "DOM.getDocument", true, false},
    {SHAAR_DEVTOOLS_DOM_REQUEST_NODE, "DOM.requestNode", true, false},
    {SHAAR_DEVTOOLS_DOM_GET_BOX_MODEL, "DOM.getBoxModel", true, false},
    {SHAAR_DEVTOOLS_CSS_ENABLE, "CSS.enable", true, false},
    {SHAAR_DEVTOOLS_CSS_GET_PLATFORM_FONTS_FOR_NODE,
     "CSS.getPlatformFontsForNode", true, false},
    {SHAAR_DEVTOOLS_CSS_GET_BACKGROUND_COLORS, "CSS.getBackgroundColors", true,
     false},
    {SHAAR_DEVTOOLS_CSS_GET_MATCHED_STYLES_FOR_NODE,
     "CSS.getMatchedStylesForNode", true, false},
    {SHAAR_DEVTOOLS_CSS_GET_COMPUTED_STYLE_FOR_NODE,
     "CSS.getComputedStyleForNode", true, false},
    {SHAAR_DEVTOOLS_CSS_GET_STYLESHEET_TEXT, "CSS.getStyleSheetText", true,
     false},
    {SHAAR_DEVTOOLS_PAGE_ENABLE, "Page.enable", true, true},
    {SHAAR_DEVTOOLS_PAGE_GET_RESOURCE_TREE, "Page.getResourceTree", true, true},
    {SHAAR_DEVTOOLS_PAGE_GET_RESOURCE_CONTENT, "Page.getResourceContent", true,
     false},
    {SHAAR_DEVTOOLS_PAGE_CAPTURE_SCREENSHOT, "Page.captureScreenshot", true,
     true},
    {SHAAR_DEVTOOLS_OVERLAY_ENABLE, "Overlay.enable", true, false},
    {SHAAR_DEVTOOLS_OVERLAY_DISABLE, "Overlay.disable", true, false},
    {SHAAR_DEVTOOLS_OVERLAY_SET_SHOW_GRID_OVERLAYS,
     "Overlay.setShowGridOverlays", true, false},
    {SHAAR_DEVTOOLS_OVERLAY_SET_SHOW_FLEX_OVERLAYS,
     "Overlay.setShowFlexOverlays", true, false},
    {SHAAR_DEVTOOLS_OVERLAY_GET_GRID_HIGHLIGHT_OBJECTS_FOR_TEST,
     "Overlay.getGridHighlightObjectsForTest", true, false},
    {SHAAR_DEVTOOLS_DOM_DESCRIBE_NODE, "DOM.describeNode", true, false},
    {SHAAR_DEVTOOLS_ACCESSIBILITY_GET_PARTIAL_AX_TREE,
     "Accessibility.getPartialAXTree", true, false},
    {SHAAR_DEVTOOLS_EMULATION_SET_DEVICE_METRICS_OVERRIDE,
     "Emulation.setDeviceMetricsOverride", false, true},
    {SHAAR_DEVTOOLS_EMULATION_CLEAR_DEVICE_METRICS_OVERRIDE,
     "Emulation.clearDeviceMetricsOverride", false, true},
    {SHAAR_DEVTOOLS_NETWORK_ENABLE, "Network.enable", false, true},
    {SHAAR_DEVTOOLS_NETWORK_EMULATE_NETWORK_CONDITIONS,
     "Network.emulateNetworkConditions", false, true},
    {SHAAR_DEVTOOLS_EMULATION_SET_CPU_THROTTLING_RATE,
     "Emulation.setCPUThrottlingRate", false, true},
    {SHAAR_DEVTOOLS_EMULATION_SET_GEOLOCATION_OVERRIDE,
     "Emulation.setGeolocationOverride", false, true},
    {SHAAR_DEVTOOLS_EMULATION_CLEAR_GEOLOCATION_OVERRIDE,
     "Emulation.clearGeolocationOverride", false, true},
    {SHAAR_DEVTOOLS_EMULATION_SET_TIMEZONE_OVERRIDE,
     "Emulation.setTimezoneOverride", false, true},
    {SHAAR_DEVTOOLS_EMULATION_SET_LOCALE_OVERRIDE,
     "Emulation.setLocaleOverride", false, true},
    {SHAAR_DEVTOOLS_EMULATION_SET_USER_AGENT_OVERRIDE,
     "Emulation.setUserAgentOverride", false, true},
    {SHAAR_DEVTOOLS_EMULATION_SET_EMULATED_MEDIA, "Emulation.setEmulatedMedia",
     false, true},
    {SHAAR_DEVTOOLS_PERFORMANCE_ENABLE, "Performance.enable", false, true},
    {SHAAR_DEVTOOLS_PERFORMANCE_GET_METRICS, "Performance.getMetrics", false,
     true},
    {SHAAR_DEVTOOLS_PAGE_ADD_SCRIPT_TO_EVALUATE_ON_NEW_DOCUMENT,
     "Page.addScriptToEvaluateOnNewDocument", false, true},
    {SHAAR_DEVTOOLS_PAGE_REMOVE_SCRIPT_TO_EVALUATE_ON_NEW_DOCUMENT,
     "Page.removeScriptToEvaluateOnNewDocument", false, true},
    {SHAAR_DEVTOOLS_NETWORK_GET_COOKIES, "Network.getCookies", false, true},
    {SHAAR_DEVTOOLS_NETWORK_SET_COOKIE, "Network.setCookie", false, true},
    {SHAAR_DEVTOOLS_NETWORK_DELETE_COOKIES, "Network.deleteCookies", false,
     true},
    {SHAAR_DEVTOOLS_EMULATION_SET_SAFE_AREA_INSETS_OVERRIDE,
     "Emulation.setSafeAreaInsetsOverride", false, true},
    {SHAAR_DEVTOOLS_PAGE_HANDLE_JAVASCRIPT_DIALOG,
     "Page.handleJavaScriptDialog", false, true},
};

struct ReplyContext {
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

class ProbeCaptureRequest final
    : public base::RefCountedThreadSafe<ProbeCaptureRequest> {
 public:
  explicit ProbeCaptureRequest(ReplyContext reply) : reply_(reply) {}

  void Start(content::WebContents* contents) {
    contents_ = contents->GetWeakPtr();
    auto* view = contents->GetRenderWidgetHostView();
    if (!view) {
      Finish({}, "renderer view is unavailable");
      return;
    }
    // Keep the native window ordered out while briefly making the page visible
    // to Chromium. A first shown transition is needed to produce a frame in a
    // window that has never been ordered in. The scoped lease restores the
    // original page visibility on success, failure, and timeout.
    capturer_ = StartHiddenProbeCapture(contents);
    if (!capturer_) {
      Finish({}, "renderer visibility probe already active");
      return;
    }
    // Visibility observers may replace the renderer view or close the tab.
    auto* live_contents = contents_.get();
    if (!live_contents) {
      Finish({}, "renderer tab closed during capture");
      return;
    }
    view = live_contents->GetRenderWidgetHostView();
    auto* widget = view ? content::RenderWidgetHostImpl::From(
                              view->GetRenderWidgetHost())
                        : nullptr;
    if (!widget) {
      Finish({}, "renderer widget is unavailable");
      return;
    }
    timer_.Start(FROM_HERE, kProbeCaptureTimeout,
                 base::BindOnce(&ProbeCaptureRequest::OnTimeout,
                                base::WrapRefCounted(this)));
    // Chromium's snapshot path forces a renderer redraw before copying from
    // the surface. CopyFromSurface issued immediately after the capture lease
    // can wait for a frame that has not yet been submitted.
    widget->GetSnapshotFromBrowser(
        base::BindOnce(
            [](scoped_refptr<ProbeCaptureRequest> request,
               const gfx::Image& image) {
              std::vector<unsigned char> png;
              if (!image.IsEmpty()) {
                auto encoded = gfx::PNGCodec::EncodeBGRASkBitmap(
                    image.AsBitmap(), /*discard_transparency=*/false);
                if (encoded)
                  png = std::move(*encoded);
              }
              request->OnCopy(std::move(png));
            },
            base::WrapRefCounted(this)),
        /*from_surface=*/true);
  }

 private:
  friend class base::RefCountedThreadSafe<ProbeCaptureRequest>;
  ~ProbeCaptureRequest() = default;

  void OnTimeout() { Finish({}, "renderer capture timed out"); }
  void OnCopy(std::vector<unsigned char> png) {
    Finish(std::move(png), "renderer returned no PNG capture");
  }
  void Finish(std::vector<unsigned char> png, const char* failure) {
    if (finished_)
      return;
    finished_ = true;
    timer_.Stop();
    capturer_.RunAndReset();
    if (png.empty()) {
      Reply(reply_, SHAAR_NOT_READY, {}, failure);
      return;
    }
    base::DictValue result;
    result.Set("data", base::Base64Encode(base::as_byte_span(png)));
    base::DictValue envelope;
    envelope.Set("schemaVersion", 1);
    envelope.Set("result", std::move(result));
    std::string payload;
    if (!base::JSONWriter::Write(base::Value(std::move(envelope)), &payload)) {
      Reply(reply_, SHAAR_CHROMIUM_ERROR, {}, "could not encode renderer capture");
      return;
    }
    Reply(reply_, SHAAR_OK, std::move(payload));
  }

  ReplyContext reply_;
  base::WeakPtr<content::WebContents> contents_;
  base::ScopedClosureRunner capturer_;
  base::OneShotTimer timer_;
  bool finished_ = false;
};

content::RenderWidgetHostImpl* ProbeWidget(content::WebContents* contents) {
  if (!contents)
    return nullptr;
  auto* view = contents->GetRenderWidgetHostView();
  if (!view || !view->GetRenderWidgetHost())
    return nullptr;
  auto* widget =
      content::RenderWidgetHostImpl::From(view->GetRenderWidgetHost());
  if (!widget || !widget->input_router())
    return nullptr;
  return widget;
}

bool ProbeClickInsideView(content::WebContents* contents, int x, int y) {
  if (!contents)
    return false;
  auto* view = contents->GetRenderWidgetHostView();
  if (!view)
    return false;
  const gfx::Size size = view->GetViewBounds().size();
  return x < size.width() && y < size.height();
}

void DispatchTrustedClick(content::RenderWidgetHost* widget, int x, int y) {
  const gfx::PointF point(x, y);
  const base::TimeTicks now = base::TimeTicks::Now();
  widget->ForwardMouseEvent(blink::WebMouseEvent(
      blink::WebInputEvent::Type::kMouseMove, point, point,
      blink::WebPointerProperties::Button::kNoButton, 0,
      blink::WebInputEvent::kNoModifiers, now));
  widget->ForwardMouseEvent(blink::WebMouseEvent(
      blink::WebInputEvent::Type::kMouseDown, point, point,
      blink::WebPointerProperties::Button::kLeft, 1,
      blink::WebInputEvent::kLeftButtonDown, now));
  widget->ForwardMouseEvent(blink::WebMouseEvent(
      blink::WebInputEvent::Type::kMouseUp, point, point,
      blink::WebPointerProperties::Button::kLeft, 1,
      blink::WebInputEvent::kNoModifiers, now));
}

void DispatchTrustedScroll(content::RenderWidgetHost* widget, int x, int y) {
  const gfx::PointF point(x, y);
  blink::WebMouseWheelEvent event(blink::WebInputEvent::Type::kMouseWheel,
                                  blink::WebInputEvent::kNoModifiers,
                                  base::TimeTicks::Now());
  event.SetPositionInWidget(point);
  event.SetPositionInScreen(point);
  event.delta_y = -600;
  event.wheel_ticks_y = -5;
  event.phase = blink::WebMouseWheelEvent::kPhaseBegan;
  event.event_action = blink::WebMouseWheelEvent::EventAction::kScrollVertical;
  widget->ForwardWheelEvent(event);
  event.delta_y = 0;
  event.wheel_ticks_y = 0;
  event.phase = blink::WebMouseWheelEvent::kPhaseEnded;
  widget->ForwardWheelEvent(event);
}

// A never-shown page does not composite, so paint-holding commit deferral
// stays set and the renderer drops mouse down. Show the renderer without
// ordering its window, wait out the deadline, force one frame, then click.
class ProbeTrustedInput final
    : public base::RefCountedThreadSafe<ProbeTrustedInput> {
 public:
  ProbeTrustedInput(ReplyContext reply,
                    int x,
                    int y,
                    std::string element_id,
                    bool scroll = false)
      : reply_(reply), x_(x), y_(y), element_id_(std::move(element_id)),
        scroll_(scroll) {}

  void Start(content::WebContents* contents) {
    contents_ = contents->GetWeakPtr();
    capturer_ = StartHiddenProbeCapture(contents);
    if (!capturer_ || !Activate()) {
      Fail();
      return;
    }
    timer_.Start(FROM_HERE, kProbeCaptureTimeout,
                 base::BindOnce(&ProbeTrustedInput::OnTimeout,
                                base::WrapRefCounted(this)));
    base::SequencedTaskRunner::GetCurrentDefault()->PostDelayedTask(
        FROM_HERE,
        base::BindOnce(&ProbeTrustedInput::ForceFrame,
                       base::WrapRefCounted(this)),
        kProbeClickCommitDelay);
  }

 private:
  friend class base::RefCountedThreadSafe<ProbeTrustedInput>;
  ~ProbeTrustedInput() = default;

  content::RenderWidgetHostImpl* Activate() {
    auto* contents = contents_.get();
    auto* widget = ProbeWidget(contents);
    if (!widget || !ProbeClickInsideView(contents, x_, y_))
      return nullptr;
    widget->input_router()->MakeActive();
    return widget;
  }

  void ForceFrame() {
    if (finished_)
      return;
    auto* widget = Activate();
    if (!widget) {
      Fail();
      return;
    }
    widget->GetSnapshotFromBrowser(
        base::BindOnce(&ProbeTrustedInput::OnFrame,
                       base::WrapRefCounted(this)),
        /*from_surface=*/true);
  }

  void OnFrame(const gfx::Image&) {
    if (finished_)
      return;
    auto* contents = contents_.get();
    if (!contents || !Activate()) {
      Fail();
      return;
    }
    if (element_id_.empty()) {
      Dispatch(x_, y_);
      return;
    }
    auto* frame = contents->GetPrimaryMainFrame();
    if (!frame) {
      Fail();
      return;
    }
    const std::string script =
        "(()=>{const e=document.getElementById('" + element_id_ +
        "');if(!e)return null;const r=e.getBoundingClientRect();return "
        "{x:Math.round(r.left+r.width/2),y:Math.round(r.top+r.height/2)};})()";
    frame->ExecuteJavaScriptForTests(
        base::UTF8ToUTF16(script),
        base::BindOnce(&ProbeTrustedInput::OnElementPoint,
                       base::WrapRefCounted(this)),
        content::ISOLATED_WORLD_ID_GLOBAL);
  }

  void OnElementPoint(base::Value result) {
    if (finished_)
      return;
    const base::DictValue* point = result.GetIfDict();
    const std::optional<int> x = point ? point->FindInt("x") : std::nullopt;
    const std::optional<int> y = point ? point->FindInt("y") : std::nullopt;
    auto* contents = contents_.get();
    auto* view = contents ? contents->GetRenderWidgetHostView() : nullptr;
    if (!x || !y || *x < 0 || *y < 0 || !view ||
        *x >= view->GetViewBounds().width() ||
        *y >= view->GetViewBounds().height() || !Activate()) {
      Fail();
      return;
    }
    Dispatch(*x, *y);
  }

  void Dispatch(int x, int y) {
    auto* widget = Activate();
    if (!widget) {
      Fail();
      return;
    }
    if (scroll_)
      DispatchTrustedScroll(widget, x, y);
    else
      DispatchTrustedClick(widget, x, y);
    finished_ = true;
    timer_.Stop();
    Reply(reply_, SHAAR_OK, R"({"schemaVersion":1,"submitted":true})");
    base::SequencedTaskRunner::GetCurrentDefault()->PostDelayedTask(
        FROM_HERE,
        base::BindOnce(&ProbeTrustedInput::ReleaseLease,
                       base::WrapRefCounted(this)),
        kProbeClickLeaseHold);
  }

  void OnTimeout() { Fail(); }

  void Fail() {
    if (finished_)
      return;
    finished_ = true;
    timer_.Stop();
    capturer_.RunAndReset();
    Reply(reply_, SHAAR_NOT_READY, {}, "trusted input could not be sent");
  }

  void ReleaseLease() { capturer_.RunAndReset(); }

  ReplyContext reply_;
  int x_;
  int y_;
  std::string element_id_;
  bool scroll_;
  base::WeakPtr<content::WebContents> contents_;
  base::ScopedClosureRunner capturer_;
  base::OneShotTimer timer_;
  bool finished_ = false;
};

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

bool ExactKeys(const base::DictValue& dict,
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

bool ParamsHaveOnly(const base::DictValue& params,
                    std::initializer_list<std::string_view> keys) {
  return ExactKeys(params, keys);
}

bool ValidateParams(shaar_devtools_command command,
                    const base::DictValue& params) {
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
    case SHAAR_DEVTOOLS_EMULATION_SET_SAFE_AREA_INSETS_OVERRIDE: {
      if (!ParamsHaveOnly(params, {"insets"}))
        return false;
      const auto* insets = params.FindDict("insets");
      if (!insets || insets->size() > 8)
        return false;
      for (const auto item : *insets) {
        if (item.first != "top" && item.first != "right" &&
            item.first != "bottom" && item.first != "left" &&
            item.first != "topMax" && item.first != "rightMax" &&
            item.first != "bottomMax" && item.first != "leftMax")
          return false;
        if (!item.second.is_int() || item.second.GetInt() < 0 ||
            item.second.GetInt() > 200)
          return false;
      }
      return true;
    }
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
    case SHAAR_DEVTOOLS_PAGE_HANDLE_JAVASCRIPT_DIALOG:
      return ParamsHaveOnly(params, {"accept", "promptText"});
    case SHAAR_DEVTOOLS_NETWORK_GET_COOKIES:
      return ParamsHaveOnly(params, {"urls"});
    case SHAAR_DEVTOOLS_NETWORK_SET_COOKIE:
      return ParamsHaveOnly(
          params, {"name", "value", "url", "domain", "path", "secure",
                   "httpOnly", "sameSite", "expires", "priority", "sameParty",
                   "sourceScheme", "sourcePort", "partitionKey"});
    case SHAAR_DEVTOOLS_NETWORK_DELETE_COOKIES:
      return ParamsHaveOnly(params,
                            {"name", "url", "domain", "path", "partitionKey"});
  }
  return false;
}

bool HasRequiredString(const base::DictValue& params,
                       std::string_view key) {
  const std::string* value = params.FindString(key);
  return value && !value->empty();
}

bool HasRequiredInteger(const base::DictValue& params,
                        std::string_view key) {
  return params.FindInt(key).has_value();
}

bool HasRequiredBoolean(const base::DictValue& params,
                        std::string_view key) {
  return params.FindBool(key).has_value();
}

bool HasNumericValue(const base::DictValue& params,
                     std::string_view key) {
  const base::Value* value = params.Find(key);
  return value && (value->is_int() || value->is_double());
}

bool HasRequiredFields(shaar_devtools_command command,
                       const base::DictValue& params) {
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
    case SHAAR_DEVTOOLS_EMULATION_SET_SAFE_AREA_INSETS_OVERRIDE:
      return params.FindDict("insets") != nullptr;
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
    case SHAAR_DEVTOOLS_PAGE_HANDLE_JAVASCRIPT_DIALOG:
      return HasRequiredBoolean(params, "accept");
    case SHAAR_DEVTOOLS_NETWORK_GET_COOKIES:
      return !params.Find("urls") || params.FindList("urls") != nullptr;
    case SHAAR_DEVTOOLS_NETWORK_SET_COOKIE:
      return HasRequiredString(params, "name") &&
             params.FindString("value") != nullptr &&
             (HasRequiredString(params, "url") ||
              HasRequiredString(params, "domain"));
    case SHAAR_DEVTOOLS_NETWORK_DELETE_COOKIES:
      return HasRequiredString(params, "name") &&
             (HasRequiredString(params, "url") ||
              HasRequiredString(params, "domain"));
    default:
      return true;
  }
}

bool HasEmptyVersionedSchema(shaar_bytes args_json) {
  if (!args_json.data || args_json.size == 0 ||
      args_json.size > kMaxArgumentsBytes)
    return false;
  auto parsed = base::JSONReader::Read(
      std::string_view(args_json.data, args_json.size), base::JSON_PARSE_RFC);
  if (!parsed || !parsed->is_dict())
    return false;
  const auto& root = parsed->GetDict();
  return ExactKeys(root, {"schemaVersion"}) &&
         root.FindInt("schemaVersion") == 1;
}

// A target keeps its domains and remote object/node IDs for the lifetime of the
// inspected tab. HandleDevToolsOperation still validates scope and capability
// before every submission; this map is not an authorization cache.
class ProtocolClient;
auto& ProtocolClients() {
  static base::NoDestructor<std::map<content::DevToolsAgentHost*, ProtocolClient*>> clients;
  return *clients;
}

class ProtocolClient final : public content::DevToolsAgentHostClient {
 public:
  explicit ProtocolClient(scoped_refptr<content::DevToolsAgentHost> host)
      : host_(std::move(host)) {}

  bool Attach() {
    attached_ = host_->AttachClient(this);
    return attached_;
  }

  ~ProtocolClient() override {
    if (attached_)
      host_->DetachClient(this);
  }

  bool Submit(ReplyContext request, const std::string& json,
              std::string main_frame_id, base::ScopedClosureRunner visibility_lease) {
    auto parsed = base::JSONReader::Read(json, base::JSON_PARSE_RFC);
    if (!parsed || !parsed->is_dict() ||
        parsed->GetDict().FindInt("id") != static_cast<int>(request.request_id))
      return false;
    if (visibility_lease && !pending_.empty())
      return false;
    pending_.push_back({request, json, std::move(main_frame_id),
                        std::move(visibility_lease)});
    if (!active_)
      StartNext();
    return true;
  }

  void DispatchProtocolMessage(content::DevToolsAgentHost*,
                               base::span<const uint8_t> message) override {
    const std::string_view input(reinterpret_cast<const char*>(message.data()),
                                 message.size());
    auto parsed = base::JSONReader::Read(input, base::JSON_PARSE_RFC);
    if (!parsed || !parsed->is_dict()) {
      if (active_)
        Finish(SHAAR_CHROMIUM_ERROR, {}, "invalid protocol response");
      return;
    }
    const auto& dict = parsed->GetDict();
    const auto* method = dict.FindString("method");
    if (method) {
      if (*method == "Runtime.executionContextsCleared") {
        contexts_.clear();
      } else if (*method == "Runtime.executionContextDestroyed") {
        const auto* params = dict.FindDict("params");
        const auto id = params ? params->FindInt("executionContextId") : std::nullopt;
        if (id)
          std::erase_if(contexts_, [id](const auto& item) { return item.second == *id; });
      } else if (*method == "Runtime.executionContextCreated") {
        const auto* params = dict.FindDict("params");
        const auto* context = params ? params->FindDict("context") : nullptr;
        const auto* aux = context ? context->FindDict("auxData") : nullptr;
        const auto* frame = aux ? aux->FindString("frameId") : nullptr;
        const auto id = context ? context->FindInt("id") : std::nullopt;
        if (frame && id && aux->FindBool("isDefault").value_or(false)) {
          contexts_[*frame] = *id;
          MaybeEvaluate();
        }
      }
      return;
    }
    if (!active_)
      return;
    if (dict.FindInt("id") == -1) {
      if (dict.FindDict("error") && awaiting_context_)
        Finish(SHAAR_CHROMIUM_ERROR, {}, "Runtime.enable failed");
      return;
    }
    if (dict.FindInt("id") != static_cast<int>(pending_.front().request.request_id))
      return;
    if (const auto* error = dict.FindDict("error")) {
      const auto* detail = error->FindString("message");
      Finish(SHAAR_CHROMIUM_ERROR, {},
             detail && !detail->empty() ? *detail : "protocol command failed");
      return;
    }
    const auto* result = dict.FindDict("result");
    if (!result) {
      Finish(SHAAR_CHROMIUM_ERROR, {}, "protocol response has no result");
      return;
    }
    base::DictValue wrapped;
    wrapped.Set("schemaVersion", 1);
    wrapped.Set("result", result->Clone());
    std::string output;
    base::JSONWriter::Write(base::Value(std::move(wrapped)), &output);
    Finish(SHAAR_OK, std::move(output), {});
  }

  void AgentHostClosed(content::DevToolsAgentHost*) override {
    attached_ = false;
    Close();
  }

  void Close() {
    if (closing_)
      return;
    closing_ = true;
    ProtocolClients().erase(host_.get());
    auto pending = std::move(pending_);
    for (auto& request : pending) {
      request.visibility_lease.RunAndReset();
      Reply(request.request, SHAAR_NOT_FOUND, {}, "DevTools target closed");
    }
    delete this;
  }

 private:
  struct Pending {
    ReplyContext request;
    std::string json;
    std::string main_frame_id;
    base::ScopedClosureRunner visibility_lease;
  };

  void StartNext() {
    if (active_ || pending_.empty())
      return;
    active_ = true;
    auto& pending = pending_.front();
    auto parsed = base::JSONReader::Read(pending.json, base::JSON_PARSE_RFC);
    const auto& command = parsed->GetDict();
    const auto* method = command.FindString("method");
    const auto* params = command.FindDict("params");
    awaiting_context_ = method && *method == "Runtime.evaluate" && params &&
        !params->Find("contextId") && !params->Find("uniqueContextId") &&
        !pending.main_frame_id.empty();
    timer_.Start(FROM_HERE, base::Seconds(15), this, &ProtocolClient::OnTimeout);
    if (awaiting_context_) {
      if (contexts_.contains(pending.main_frame_id)) {
        MaybeEvaluate();
      } else {
        const std::string enable = R"({"id":-1,"method":"Runtime.enable"})";
        host_->DispatchProtocolMessage(this, base::as_byte_span(enable));
      }
    } else {
      // Copy: a synchronous response may remove the pending entry.
      const std::string json = pending.json;
      host_->DispatchProtocolMessage(this, base::as_byte_span(json));
    }
  }

  void MaybeEvaluate() {
    if (!active_ || !awaiting_context_)
      return;
    auto& pending = pending_.front();
    const auto context = contexts_.find(pending.main_frame_id);
    if (context == contexts_.end())
      return;
    auto command = base::JSONReader::Read(pending.json, base::JSON_PARSE_RFC);
    command->GetDict().FindDict("params")->Set("contextId", context->second);
    std::string json;
    base::JSONWriter::Write(*command, &json);
    awaiting_context_ = false;
    host_->DispatchProtocolMessage(this, base::as_byte_span(json));
  }

  void OnTimeout() {
    Finish(SHAAR_NOT_READY, {}, awaiting_context_
               ? "main frame execution context timed out"
               : "DevTools protocol request timed out");
  }

  void Finish(shaar_error_code code, std::string payload, std::string message) {
    timer_.Stop();
    const ReplyContext request = pending_.front().request;
    auto lease = std::move(pending_.front().visibility_lease);
    pending_.pop_front();
    active_ = false;
    awaiting_context_ = false;
    auto weak = weak_factory_.GetWeakPtr();
    lease.RunAndReset();
    Reply(request, code, std::move(payload), std::move(message));
    if (!weak)
      return;
    base::SequencedTaskRunner::GetCurrentDefault()->PostTask(
        FROM_HERE, base::BindOnce(&ProtocolClient::StartNext,
                                  weak_factory_.GetWeakPtr()));
  }

  scoped_refptr<content::DevToolsAgentHost> host_;
  std::deque<Pending> pending_;
  std::map<std::string, int> contexts_;
  base::OneShotTimer timer_;
  bool closing_ = false;
  bool active_ = false;
  bool awaiting_context_ = false;
  bool attached_ = false;
  base::WeakPtrFactory<ProtocolClient> weak_factory_{this};
};

shaar_error_code DecodeOperation(shaar_operation operation,
                                 shaar_bytes args_json,
                                 shaar_devtools_capability* capability,
                                 shaar_devtools_command* command,
                                 base::DictValue* params,
                                 std::string* reason) {
  if (!args_json.data || args_json.size == 0 || args_json.size > kMaxArgumentsBytes) {
    *reason = "invalid DevTools arguments";
    return SHAAR_INVALID_ARGUMENT;
  }
  auto parsed = base::JSONReader::Read(
      std::string_view(args_json.data, args_json.size), base::JSON_PARSE_RFC);
  if (!parsed || !parsed->is_dict()) {
    *reason = "invalid DevTools JSON";
    return SHAAR_INVALID_ARGUMENT;
  }
  const auto& root = parsed->GetDict();
  if (operation != SHAAR_OP_DEVTOOLS_CALL ||
      !(ExactKeys(root, {"schemaVersion", "capability", "command", "params"}) ||
        ExactKeys(root, {"schemaVersion", "capability", "command", "params",
                         "probeVisibleForRenderer"}) ||
        ExactKeys(root, {"schemaVersion", "capability", "command", "params",
                         "probeQuitDialogCancellation"})) ||
      root.FindInt("schemaVersion") != 1 ||
      !root.FindInt("capability") || !root.FindInt("command") ||
      !root.FindDict("params")) {
    *reason = "invalid DevTools call schema";
    return SHAAR_INVALID_ARGUMENT;
  }
  const int cap = *root.FindInt("capability");
  const int id = *root.FindInt("command");
  if ((cap != kInspector && cap != kDeveloper) || id < 1 || id > 45) {
    *reason = "unknown DevTools capability or command";
    return SHAAR_INVALID_ARGUMENT;
  }
  *capability = static_cast<shaar_devtools_capability>(cap);
  *command = static_cast<shaar_devtools_command>(id);
  if (!ProtocolMethod(*capability, *command)) {
    *reason = "DevTools command is not allowed for this capability";
    return SHAAR_UNSUPPORTED_CAPABILITY;
  }
  if (id == SHAAR_DEVTOOLS_PAGE_HANDLE_JAVASCRIPT_DIALOG ||
      root.contains("probeQuitDialogCancellation")) {
    const char* testing = std::getenv("SHAAR_ENGINE_TESTING");
    if (!testing || std::strcmp(testing, "1") != 0) {
      *reason = "quit dialog cancellation probe requires testing mode";
      return SHAAR_POLICY_BLOCKED;
    }
    if (id != SHAAR_DEVTOOLS_PAGE_HANDLE_JAVASCRIPT_DIALOG ||
        cap != kDeveloper ||
        root.FindBool("probeQuitDialogCancellation") != true ||
        root.FindDict("params")->size() != 1 ||
        root.FindDict("params")->FindBool("accept") != false) {
      *reason = "invalid quit dialog cancellation probe";
      return SHAAR_INVALID_ARGUMENT;
    }
  }
  if (!ValidateParams(*command, *root.FindDict("params"))) {
    *reason = "DevTools command parameters are invalid";
    return SHAAR_INVALID_ARGUMENT;
  }
  if (!HasRequiredFields(*command, *root.FindDict("params"))) {
    *reason = "DevTools command is missing required parameters";
    return SHAAR_INVALID_ARGUMENT;
  }
  if (root.contains("probeVisibleForRenderer")) {
    const char* testing = std::getenv("SHAAR_ENGINE_TESTING");
    if (!testing || std::strcmp(testing, "1") != 0) {
      *reason = "renderer visibility probe requires testing mode";
      return SHAAR_POLICY_BLOCKED;
    }
    if (root.FindBool("probeVisibleForRenderer") != true ||
        cap != kDeveloper || id != SHAAR_DEVTOOLS_RUNTIME_EVALUATE ||
        root.FindDict("params")->FindBool("awaitPromise") != true ||
        root.FindDict("params")->FindBool("returnByValue") != true) {
      *reason = "invalid renderer visibility probe";
      return SHAAR_INVALID_ARGUMENT;
    }
  }
  *params = root.FindDict("params")->Clone();
  return SHAAR_OK;
}

}  // namespace

namespace {

struct ProbeCaptureLeaseRegistry {
  uint64_t next_id = 1;
  std::map<uint64_t, base::WeakPtr<content::WebContents>> leases;
};

ProbeCaptureLeaseRegistry& GetProbeCaptureLeaseRegistry() {
  static base::NoDestructor<ProbeCaptureLeaseRegistry> registry;
  return *registry;
}

std::optional<uint64_t> RegisterProbeCaptureLease(
    content::WebContents* contents) {
  auto& registry = GetProbeCaptureLeaseRegistry();
  for (auto it = registry.leases.begin(); it != registry.leases.end();) {
    if (!it->second)
      it = registry.leases.erase(it);
    else {
      if (it->second.get() == contents)
        return std::nullopt;
      ++it;
    }
  }
  const uint64_t lease_id = registry.next_id++;
  registry.leases.emplace(lease_id, contents->GetWeakPtr());
  return lease_id;
}

void ReleaseProbeCaptureLease(uint64_t lease_id) {
  GetProbeCaptureLeaseRegistry().leases.erase(lease_id);
}

}  // namespace

base::ScopedClosureRunner StartHiddenProbeCapture(content::WebContents* contents) {
  auto lease_id = RegisterProbeCaptureLease(contents);
  if (!lease_id)
    return {};
  const content::Visibility original_visibility = contents->GetVisibility();
  auto weak_contents = contents->GetWeakPtr();
  auto capturer = contents->IncrementCapturerCount(
      gfx::Size(), /*stay_hidden=*/true, /*stay_awake=*/true,
      /*is_activity=*/false);
  // UpdateWebContentsVisibility handles the first shown transition even when
  // GetVisibility() already reports VISIBLE for a never-shown WebContents.
  if (weak_contents)
    weak_contents->UpdateWebContentsVisibility(content::Visibility::VISIBLE);
  return base::ScopedClosureRunner(base::BindOnce(
      [](uint64_t lease_id,
         base::WeakPtr<content::WebContents> weak_contents,
         content::Visibility visibility,
         base::ScopedClosureRunner capturer) {
        if (weak_contents && visibility != content::Visibility::VISIBLE &&
            weak_contents->GetVisibility() == content::Visibility::VISIBLE)
          weak_contents->UpdateWebContentsVisibility(visibility);
        capturer.RunAndReset();
        ReleaseProbeCaptureLease(lease_id);
      },
      *lease_id, std::move(weak_contents), original_visibility,
      std::move(capturer)));
}

void BindRuntimeServices() {
  shaar::SetDevToolsRuntimeServices(&g_runtime_services);
}

namespace {
struct PendingNodeFrontend {
  uint64_t id;
  Profile* profile;
  std::string url;
  scoped_refptr<content::DevToolsAgentHost> host;
};

std::vector<PendingNodeFrontend>& PendingNodeFrontends() {
  static base::NoDestructor<std::vector<PendingNodeFrontend>> pending;
  return *pending;
}
uint64_t next_pending_node_frontend_id = 0;
}  // namespace

bool RequestNodeFrontend(Profile* profile,
                         content::WebContents* source,
                         const GURL& url,
                         scoped_refptr<content::DevToolsAgentHost> host) {
  if (!profile || !host || !url.is_valid() ||
      !url.SchemeIs("devtools"))
    return false;
  auto& pending = PendingNodeFrontends();
  const uint64_t id = ++next_pending_node_frontend_id;
  pending.push_back({id, profile, url.spec(), std::move(host)});
  if (shaar::windows_tabs::RouteDevToolsOpenURL(source, profile, url)) {
    base::SequencedTaskRunner::GetCurrentDefault()->PostDelayedTask(
        FROM_HERE, base::BindOnce([](uint64_t expired_id) {
          std::erase_if(PendingNodeFrontends(),
                        [expired_id](const PendingNodeFrontend& entry) {
                          return entry.id == expired_id;
                        });
        }, id), base::Seconds(15));
    return true;
  }
  pending.pop_back();
  return false;
}

bool HasPendingNodeFrontend(Profile* profile, const GURL& url) {
  const auto& pending = PendingNodeFrontends();
  return std::ranges::any_of(pending, [&](const PendingNodeFrontend& entry) {
    return entry.profile == profile && entry.url == url.spec();
  });
}

bool OpenPendingNodeFrontend(content::WebContents* contents,
                             Profile* profile,
                             const GURL& url) {
  if (!contents || !profile)
    return false;
  auto& pending = PendingNodeFrontends();
  auto found = std::ranges::find_if(pending, [&](const PendingNodeFrontend& e) {
    return e.profile == profile && e.url == url.spec();
  });
  if (found == pending.end())
    return false;
  content::NavigationController::LoadURLParams params(url);
  params.transition_type = ui::PAGE_TRANSITION_AUTO_TOPLEVEL;
  contents->GetController().LoadURLWithParams(params);
  DevToolsUIBindings* bindings = DevToolsUIBindings::ForWebContents(contents);
  if (!bindings)
    return false;
  bindings->AttachTo(found->host);
  pending.erase(found);
  return true;
}

bool StartProtocolRequest(scoped_refptr<content::DevToolsAgentHost> host,
                          shaar_request_id request_id,
                          shaar_reply_fn reply,
                          void* reply_context,
                          const std::string& request_json,
                          std::string main_frame_id,
                          base::ScopedClosureRunner visibility_lease) {
  if (!host)
    return false;
  auto it = ProtocolClients().find(host.get());
  ProtocolClient* client = it == ProtocolClients().end() ? nullptr : it->second;
  if (!client) {
    client = new ProtocolClient(host);
    if (!client->Attach()) {
      delete client;
      return false;
    }
    ProtocolClients()[host.get()] = client;
  }
  return client->Submit({request_id, reply, reply_context}, request_json,
                         std::move(main_frame_id), std::move(visibility_lease));
}

void CloseProtocolSessionForTesting(content::DevToolsAgentHost* host) {
  const auto it = ProtocolClients().find(host);
  if (it != ProtocolClients().end())
    it->second->Close();
}

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
    case SHAAR_OP_DEVTOOLS_PANEL_OPEN:
    case SHAAR_OP_DEVTOOLS_PANEL_CLOSE:
    case SHAAR_OP_DEVTOOLS_PANEL_GET_RESPONSE_BODY:
    case SHAAR_OP_DEVTOOLS_PANEL_PHASE2_COMMAND:
    case SHAAR_OP_DEVTOOLS_PANEL_SCREENCAST:
    case SHAAR_OP_DEVTOOLS_VIEWPORT_OPEN:
    case SHAAR_OP_DEVTOOLS_VIEWPORT_CLOSE:
    case SHAAR_OP_DEVTOOLS_VIEWPORT_ADD:
    case SHAAR_OP_DEVTOOLS_VIEWPORT_REMOVE:
    case SHAAR_OP_DEVTOOLS_VIEWPORT_ACTION:
    case SHAAR_OP_DEVTOOLS_VIEWPORT_FRAME:
      break;
    case SHAAR_OP_DEVTOOLS_UI_SET_DOCK:
    case SHAAR_OP_DEVTOOLS_CONTROL_ENABLE:
    case SHAAR_OP_DEVTOOLS_CONTROL_DISABLE:
    case SHAAR_OP_DEVTOOLS_CONTROL_STATUS:
    default:
      return false;
  }
  const bool panel_operation = operation == SHAAR_OP_DEVTOOLS_PANEL_OPEN ||
      operation == SHAAR_OP_DEVTOOLS_PANEL_CLOSE ||
      operation == SHAAR_OP_DEVTOOLS_PANEL_GET_RESPONSE_BODY ||
      operation == SHAAR_OP_DEVTOOLS_PANEL_PHASE2_COMMAND ||
      operation == SHAAR_OP_DEVTOOLS_PANEL_SCREENCAST ||
      operation == SHAAR_OP_DEVTOOLS_VIEWPORT_OPEN ||
      operation == SHAAR_OP_DEVTOOLS_VIEWPORT_CLOSE ||
      operation == SHAAR_OP_DEVTOOLS_VIEWPORT_ADD ||
      operation == SHAAR_OP_DEVTOOLS_VIEWPORT_REMOVE ||
      operation == SHAAR_OP_DEVTOOLS_VIEWPORT_ACTION ||
      operation == SHAAR_OP_DEVTOOLS_VIEWPORT_FRAME;
  if ((operation == SHAAR_OP_DEVTOOLS_CALL && capability != kInspector &&
       capability != kDeveloper) ||
      (panel_operation && capability != kPanel) ||
      (!panel_operation && operation != SHAAR_OP_DEVTOOLS_CALL && capability != 0))
    return false;
  return runtime->IsOperationAllowed(engine, scope, contents, operation,
                                     capability);
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
  base::DictValue params;
  const auto status = DecodeOperation(SHAAR_OP_DEVTOOLS_CALL, args_json,
                                      &capability, &command, &params, reason);
  if (status != SHAAR_OK)
    return status;
  base::DictValue protocol;
  protocol.Set("id", static_cast<int>(request_id));
  protocol.Set("method", ProtocolMethod(capability, command));
  protocol.Set("params", std::move(params));
  if (!base::JSONWriter::Write(base::Value(std::move(protocol)), request_json)) {
    *reason = "could not serialize DevTools command";
    return SHAAR_INVALID_ARGUMENT;
  }
  return SHAAR_OK;
}

bool IsProtocolPageTargetFor(content::WebContents* contents,
                             content::DevToolsAgentHost* host) {
  return contents && host &&
         host->GetType() == content::DevToolsAgentHost::kTypePage &&
         host->GetWebContents() == contents;
}
scoped_refptr<content::DevToolsAgentHost> ProtocolAgentHostFor(
    content::WebContents* contents) {
  if (!contents)
    return nullptr;
  // A tab target accepts Target/Tracing but not Runtime or Page methods.
  auto host = content::DevToolsAgentHost::GetOrCreateFor(contents);
  return IsProtocolPageTargetFor(contents, host.get()) ? host : nullptr;
}

bool ParseProbeClickArguments(shaar_bytes args_json,
                              int* x,
                              int* y,
                              std::string* element_id) {
  if (!x || !y || !element_id || !args_json.data || args_json.size == 0 ||
      args_json.size > 256)
    return false;
  auto value = base::JSONReader::Read(
      std::string_view(args_json.data, args_json.size), base::JSON_PARSE_RFC);
  if (!value || !value->is_dict() ||
      value->GetDict().FindInt("schemaVersion") != 1)
    return false;
  const auto& dict = value->GetDict();
  const std::string* requested_element = dict.FindString("elementID");
  if (requested_element && ExactKeys(dict, {"schemaVersion", "elementID"})) {
    if (requested_element->empty() || requested_element->size() > 128)
      return false;
    for (const char character : *requested_element) {
      if (!((character >= 'a' && character <= 'z') ||
            (character >= 'A' && character <= 'Z') ||
            (character >= '0' && character <= '9') || character == '_' ||
            character == '-'))
        return false;
    }
    *x = 0;
    *y = 0;
    *element_id = *requested_element;
    return true;
  }
  if (!ExactKeys(dict, {"schemaVersion", "x", "y"}))
    return false;
  auto point_x = dict.FindInt("x");
  auto point_y = dict.FindInt("y");
  if (!point_x || !point_y || *point_x < 0 || *point_y < 0 ||
      *point_x >= 8192 || *point_y >= 8192)
    return false;
  *x = *point_x;
  *y = *point_y;
  element_id->clear();
  return true;
}

bool ParseProbeScrollArguments(shaar_bytes args_json,
                               std::string* element_id) {
  int x = 0;
  int y = 0;
  return element_id &&
         ParseProbeClickArguments(args_json, &x, &y, element_id) &&
         !element_id->empty();
}

bool ParseNodeProbePort(shaar_bytes args_json, int* port) {
  if (!port || !args_json.data || args_json.size > 128)
    return false;
  auto value = base::JSONReader::Read(
      std::string_view(args_json.data, args_json.size), base::JSON_PARSE_RFC);
  if (!value || !value->is_dict() ||
      !ExactKeys(value->GetDict(), {"schemaVersion", "nodeInspectPort"}) ||
      value->GetDict().FindInt("schemaVersion") != 1)
    return false;
  auto value_port = value->GetDict().FindInt("nodeInspectPort");
  if (!value_port || *value_port < 1 || *value_port > 65535)
    return false;
  *port = *value_port;
  return true;
}

bool ParseProbePopupArguments(shaar_bytes args_json, bool evaluate,
                              std::string* popup_id, std::string* expression) {
  if (!popup_id || (evaluate && !expression) || !args_json.data ||
      args_json.size == 0 || args_json.size > 16384)
    return false;
  auto value = base::JSONReader::Read(
      std::string_view(args_json.data, args_json.size), base::JSON_PARSE_RFC);
  if (!value || !value->is_dict() ||
      value->GetDict().FindInt("schemaVersion") != 1)
    return false;
  const auto& dict = value->GetDict();
  if (evaluate ? !ExactKeys(dict, {"schemaVersion", "popupId", "expression"})
               : !ExactKeys(dict, {"schemaVersion", "popupId"}))
    return false;
  const std::string* id = dict.FindString("popupId");
  if (!id || id->size() != 36)
    return false;
  for (size_t i = 0; i < id->size(); ++i) {
    const char c = (*id)[i];
    if (i == 8 || i == 13 || i == 18 || i == 23) {
      if (c != '-') return false;
    } else if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))) {
      return false;
    }
  }
  *popup_id = *id;
  if (!evaluate)
    return true;
  const std::string* script = dict.FindString("expression");
  if (!script || script->empty() || script->size() > 8192)
    return false;
  *expression = *script;
  return true;
}

bool ProbeWindowAllowed(bool testing, bool owned_root, bool selected,
                       bool never_shown, const GURL& url) {
  return testing && owned_root && selected && never_shown &&
         url.SchemeIs("http") &&
         (url.host() == "127.0.0.1" || url.host() == "localhost");
}

void EmitFrontendStateEvent(shaar_engine* engine,
                            const DevToolsTargetIdentity& identity,
                            bool open) {
  if (identity.profile_id.empty() || identity.window_id.empty() ||
      identity.tab_id.empty())
    return;
  char payload[sizeof(kFrontendStateEvent) + 8];
  const int length = std::snprintf(payload, sizeof(payload), kFrontendStateEvent,
                                   open ? "true" : "false");
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
  DevToolsTargetIdentity identity;
  if (!context->devtools_runtime->ResolveTarget(engine, scope, window, tab,
                                                contents, &identity))
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

  if (operation == SHAAR_OP_PROBE_NODE_LIVE) {
    const char* testing = std::getenv("SHAAR_ENGINE_TESTING");
    const bool selected = context->browser_tabs->IsSelectedWebContents(
        engine, window, tab, contents);
    if (!ProbeWindowAllowed(testing && std::strcmp(testing, "1") == 0,
                           shaar::lifecycle::HasOwnedProbeRoot(engine), selected,
                           shaar::windows_tabs::HasNeverShownPageHost(window, contents),
                           contents->GetLastCommittedURL()) || !scope.profile ||
        scope.private_session)
      return Fail(error, SHAAR_POLICY_BLOCKED, "Node inspector probe is unavailable");
    int port = 0;
    if (!ParseNodeProbePort(args_json, &port))
      return Fail(error, SHAAR_INVALID_ARGUMENT, "invalid Node inspector port");
    Profile* profile = Profile::FromBrowserContext(contents->GetBrowserContext());
    base::ListValue locations;
    locations.Append("127.0.0.1:" + std::to_string(port));
    profile->GetPrefs()->SetBoolean(prefs::kDevToolsDiscoverTCPTargetsEnabled,
                                    true);
    profile->GetPrefs()->SetList(prefs::kDevToolsTCPDiscoveryConfig,
                                 std::move(locations));
    DevToolsWindow::OpenNodeFrontendWindow(
        profile, DevToolsOpenedByAction::kOpenForNodeFromAnotherTarget, contents);
    Reply({request_id, reply, reply_context}, SHAAR_OK,
          R"({"schemaVersion":1,"submitted":true})");
    return SHAAR_OK;
  }
  if (operation == SHAAR_OP_PROBE_TRUSTED_CLICK ||
      operation == SHAAR_OP_PROBE_TRUSTED_SCROLL) {
    const char* testing = std::getenv("SHAAR_ENGINE_TESTING");
    const bool selected = context->browser_tabs->IsSelectedWebContents(
        engine, window, tab, contents);
    if (!ProbeWindowAllowed(testing && std::strcmp(testing, "1") == 0,
                           shaar::lifecycle::HasOwnedProbeRoot(engine), selected,
                           shaar::windows_tabs::HasNeverShownPageHost(window, contents),
                           contents->GetLastCommittedURL()) || !scope.profile ||
        scope.private_session)
      return Fail(error, SHAAR_POLICY_BLOCKED, "trusted input probe is unavailable");
    int x = 0;
    int y = 0;
    std::string element_id;
    const bool scroll = operation == SHAAR_OP_PROBE_TRUSTED_SCROLL;
    const bool parsed = scroll
        ? ParseProbeScrollArguments(args_json, &element_id)
        : ParseProbeClickArguments(args_json, &x, &y, &element_id);
    if (!parsed)
      return Fail(error, SHAAR_INVALID_ARGUMENT,
                  scroll ? "invalid trusted scroll element"
                         : "invalid trusted click point");
    auto* view = contents->GetRenderWidgetHostView();
    if (!view || !view->GetRenderWidgetHost() ||
        (element_id.empty() &&
         (x >= view->GetViewBounds().width() || y >= view->GetViewBounds().height())))
      return Fail(error, SHAAR_NOT_READY, "trusted input viewport unavailable");
    base::MakeRefCounted<ProbeTrustedInput>(
        ReplyContext{request_id, reply, reply_context}, x, y,
        std::move(element_id), scroll)
        ->Start(contents);
    return SHAAR_OK;
  }
  if (operation == SHAAR_OP_PROBE_POPUP_EVALUATE ||
      operation == SHAAR_OP_PROBE_POPUP_CAPTURE) {
    const char* testing = std::getenv("SHAAR_ENGINE_TESTING");
    const bool selected = context->browser_tabs->IsSelectedWebContents(
        engine, window, tab, contents);
    const bool evaluate = operation == SHAAR_OP_PROBE_POPUP_EVALUATE;
    if (!ProbeWindowAllowed(testing && std::strcmp(testing, "1") == 0,
                            shaar::lifecycle::HasOwnedProbeRoot(engine), selected,
                            shaar::windows_tabs::HasNeverShownPageHost(window, contents),
                            contents->GetLastCommittedURL()) || !scope.profile ||
        scope.private_session)
      return Fail(error, SHAAR_POLICY_BLOCKED, "popup probe is unavailable");
    if (request_id > static_cast<uint64_t>(INT_MAX))
      return Fail(error, SHAAR_INVALID_ARGUMENT, "invalid popup probe request");
    std::string popup_id;
    std::string expression;
    if (!ParseProbePopupArguments(args_json, evaluate, &popup_id,
                                  evaluate ? &expression : nullptr))
      return Fail(error, SHAAR_INVALID_ARGUMENT, "invalid popup probe arguments");
    content::WebContents* popup = shaar::extensions_host::ProbePopupContents(
        engine, scope.profile, window, tab, popup_id);
    if (!popup)
      return Fail(error, SHAAR_NOT_FOUND, "popup probe target is unavailable");
    if (!evaluate) {
      base::MakeRefCounted<ProbeCaptureRequest>(
          ReplyContext{request_id, reply, reply_context})->Start(popup);
      return SHAAR_OK;
    }
    auto* frame = popup->GetPrimaryMainFrame();
    if (!frame)
      return Fail(error, SHAAR_NOT_READY, "popup probe frame is unavailable");
    base::DictValue params;
    params.Set("expression", expression);
    params.Set("returnByValue", true);
    base::DictValue protocol;
    protocol.Set("id", static_cast<int>(request_id));
    protocol.Set("method", "Runtime.evaluate");
    protocol.Set("params", std::move(params));
    std::string request_json;
    if (!base::JSONWriter::Write(base::Value(std::move(protocol)), &request_json))
      return Fail(error, SHAAR_CHROMIUM_ERROR, "could not serialize popup probe");
    if (!StartProtocolRequest(ProtocolAgentHostFor(popup), request_id, reply,
                              reply_context, request_json,
                              frame->GetDevToolsFrameToken().ToString(), {}))
      return Fail(error, SHAAR_NOT_READY, "popup probe attach was denied");
    return SHAAR_OK;
  }
  if (operation >= SHAAR_OP_PROBE_DEVTOOLS_OPEN_URL &&
      operation <= SHAAR_OP_PROBE_DEVTOOLS_FRONTEND_ATTACHED) {
    const char* testing = std::getenv("SHAAR_ENGINE_TESTING");
    if (!testing || std::strcmp(testing, "1") != 0 ||
        !shaar::lifecycle::HasOwnedProbeRoot(engine))
      return Fail(error, SHAAR_POLICY_BLOCKED,
                  "DevTools route probe requires testing mode and owned probe root");
    if (!context->browser_tabs->IsSelectedWebContents(engine, window, tab,
                                                        contents))
      return Fail(error, SHAAR_NOT_READY,
                  "DevTools route probe requires selected tab");
    const ReplyContext probe_reply{request_id, reply, reply_context};
    if (operation == SHAAR_OP_PROBE_DEVTOOLS_FRONTEND_ATTACHED) {
      if (!HasEmptyVersionedSchema(args_json))
        return Fail(error, SHAAR_INVALID_ARGUMENT,
                    "invalid frontend attachment probe schema");
      auto* bindings = DevToolsUIBindings::ForWebContents(contents);
      const bool attached = bindings && bindings->agent_host();
      Reply(probe_reply, SHAAR_OK,
            attached ? R"({"schemaVersion":1,"attached":true})"
                     : R"({"schemaVersion":1,"attached":false})");
      return SHAAR_OK;
    }
    if (!HasEmptyVersionedSchema(args_json) &&
        operation == SHAAR_OP_PROBE_NODE_FRONTEND)
      return Fail(error, SHAAR_INVALID_ARGUMENT,
                  "invalid Node frontend probe schema");
    auto* devtools = DevToolsWindow::GetInstanceForInspectedWebContents(contents);
    if (!devtools)
      return Fail(error, SHAAR_NOT_READY, "DevTools frontend is not open");
    if (operation == SHAAR_OP_PROBE_NODE_FRONTEND) {
      DevToolsWindow::OpenNodeFrontendWindow(
          Profile::FromBrowserContext(contents->GetBrowserContext()),
          DevToolsOpenedByAction::kOpenForNodeFromAnotherTarget, contents);
    } else {
      auto envelope = base::JSONReader::Read(
          std::string_view(args_json.data, args_json.size), base::JSON_PARSE_RFC);
      const base::DictValue* dict = envelope && envelope->is_dict()
                                        ? &envelope->GetDict() : nullptr;
      const std::string* requested = dict ? dict->FindString("url") : nullptr;
      if (!dict || dict->FindInt("schemaVersion") != 1 || !requested ||
          *requested != "https://github.com/ChromeDevTools/chrome-devtools-mcp")
        return Fail(error, SHAAR_INVALID_ARGUMENT,
                    "invalid DevTools URL probe schema");
      auto* bindings = DevToolsUIBindings::ForWebContents(
          devtools->GetDevToolsWebContents());
      if (!bindings)
        return Fail(error, SHAAR_NOT_READY,
                    "DevTools frontend bindings are unavailable");
      bindings->ShaarProbeOpenInNewTab(*requested);
    }
    Reply(probe_reply, SHAAR_OK, R"({"schemaVersion":1,"submitted":true})");
    return SHAAR_OK;
  }

  if (operation == SHAAR_OP_DEVTOOLS_CONTROL_ENABLE ||
      operation == SHAAR_OP_DEVTOOLS_CONTROL_DISABLE ||
      operation == SHAAR_OP_DEVTOOLS_CONTROL_STATUS) {
    if (!HasEmptyVersionedSchema(args_json))
      return Fail(error, SHAAR_INVALID_ARGUMENT,
                  "invalid agent bridge operation schema");
    return agent_bridge::HandleOperation(
        engine, scope, window, tab, contents, identity, operation, request_id,
        reply, reply_context, error);
  }

  if (operation == SHAAR_OP_DEVTOOLS_PANEL_OPEN ||
      operation == SHAAR_OP_DEVTOOLS_PANEL_CLOSE ||
      operation == SHAAR_OP_DEVTOOLS_PANEL_SCREENCAST ||
      operation == SHAAR_OP_DEVTOOLS_PANEL_GET_RESPONSE_BODY ||
      operation == SHAAR_OP_DEVTOOLS_PANEL_PHASE2_COMMAND) {
    if (!PolicyAllowsOperation(context->devtools_runtime, engine, scope,
                               contents, operation, kPanel))
      return Fail(error, SHAAR_POLICY_BLOCKED, "DevTools panel is blocked");
    return HandlePanelOperation(context, engine, scope, window, tab, contents,
                                identity, operation, args_json, request_id,
                                reply, reply_context, error);
  }
  if (operation == SHAAR_OP_DEVTOOLS_VIEWPORT_OPEN ||
      operation == SHAAR_OP_DEVTOOLS_VIEWPORT_CLOSE ||
      operation == SHAAR_OP_DEVTOOLS_VIEWPORT_ADD ||
      operation == SHAAR_OP_DEVTOOLS_VIEWPORT_REMOVE ||
      operation == SHAAR_OP_DEVTOOLS_VIEWPORT_ACTION ||
      operation == SHAAR_OP_DEVTOOLS_VIEWPORT_FRAME) {
    if (!PolicyAllowsOperation(context->devtools_runtime, engine, scope,
                               contents, operation, kPanel))
      return Fail(error, SHAAR_POLICY_BLOCKED, "DevTools Viewports is blocked");
    return HandleViewportOperation(context, engine, scope, window, tab, contents,
                                   identity, operation, args_json, request_id,
                                   reply, reply_context, error);
  }
  if (operation >= SHAAR_OP_PROBE_DEVTOOLS_OPEN_URL &&
      operation <= SHAAR_OP_PROBE_DEVTOOLS_FRONTEND_ATTACHED) {
    const char* testing = std::getenv("SHAAR_ENGINE_TESTING");
    if (!testing || std::strcmp(testing, "1") != 0 ||
        !shaar::lifecycle::HasOwnedProbeRoot(engine))
      return Fail(error, SHAAR_POLICY_BLOCKED,
                  "DevTools route probe requires testing mode and owned probe root");
    if (!context->browser_tabs->IsSelectedWebContents(engine, window, tab,
                                                        contents))
      return Fail(error, SHAAR_NOT_READY,
                  "DevTools route probe requires selected tab");
    const ReplyContext probe_reply{request_id, reply, reply_context};
    if (operation == SHAAR_OP_PROBE_DEVTOOLS_FRONTEND_ATTACHED) {
      if (!HasEmptyVersionedSchema(args_json))
        return Fail(error, SHAAR_INVALID_ARGUMENT,
                    "invalid frontend attachment probe schema");
      auto* bindings = DevToolsUIBindings::ForWebContents(contents);
      const bool attached = bindings && bindings->agent_host();
      Reply(probe_reply, SHAAR_OK,
            attached ? R"({"schemaVersion":1,"attached":true})"
                     : R"({"schemaVersion":1,"attached":false})");
      return SHAAR_OK;
    }
    if (!HasEmptyVersionedSchema(args_json) &&
        operation == SHAAR_OP_PROBE_NODE_FRONTEND)
      return Fail(error, SHAAR_INVALID_ARGUMENT,
                  "invalid Node frontend probe schema");
    auto* devtools = DevToolsWindow::GetInstanceForInspectedWebContents(contents);
    if (!devtools)
      return Fail(error, SHAAR_NOT_READY, "DevTools frontend is not open");
    if (operation == SHAAR_OP_PROBE_NODE_FRONTEND) {
      DevToolsWindow::OpenNodeFrontendWindow(
          Profile::FromBrowserContext(contents->GetBrowserContext()),
          DevToolsOpenedByAction::kOpenForNodeFromAnotherTarget, contents);
    } else {
      auto envelope = base::JSONReader::Read(
          std::string_view(args_json.data, args_json.size), base::JSON_PARSE_RFC);
      const base::DictValue* dict = envelope && envelope->is_dict()
                                        ? &envelope->GetDict() : nullptr;
      const std::string* requested = dict ? dict->FindString("url") : nullptr;
      if (!dict || dict->FindInt("schemaVersion") != 1 || !requested ||
          *requested != "https://github.com/ChromeDevTools/chrome-devtools-mcp")
        return Fail(error, SHAAR_INVALID_ARGUMENT,
                    "invalid DevTools URL probe schema");
      auto* bindings = DevToolsUIBindings::ForWebContents(
          devtools->GetDevToolsWebContents());
      if (!bindings)
        return Fail(error, SHAAR_NOT_READY,
                    "DevTools frontend bindings are unavailable");
      bindings->ShaarProbeOpenInNewTab(*requested);
    }
    Reply(probe_reply, SHAAR_OK, R"({"schemaVersion":1,"submitted":true})");
    return SHAAR_OK;
  }

  if (operation == SHAAR_OP_PROBE_CAPTURE_TAB) {
    if (!HasEmptyVersionedSchema(args_json))
      return Fail(error, SHAAR_INVALID_ARGUMENT, "invalid capture probe schema");
    const char* testing = std::getenv("SHAAR_ENGINE_TESTING");
    if (!testing || std::strcmp(testing, "1") != 0 ||
        !shaar::lifecycle::HasOwnedProbeRoot(engine))
      return Fail(error, SHAAR_POLICY_BLOCKED,
                  "capture probe requires testing mode and owned probe root");
    if (!context->browser_tabs->IsSelectedWebContents(engine, window, tab,
                                                        contents))
      return Fail(error, SHAAR_NOT_READY, "capture probe requires selected tab");
    base::MakeRefCounted<ProbeCaptureRequest>(
        ReplyContext{request_id, reply, reply_context})->Start(contents);
    return SHAAR_OK;
  }

  int capability = 0;
  shaar_devtools_command parsed_command = SHAAR_DEVTOOLS_RUNTIME_EVALUATE;
  if (operation == SHAAR_OP_DEVTOOLS_CALL) {
    auto envelope = args_json.data
        ? base::JSONReader::Read(std::string_view(args_json.data, args_json.size),
                                 base::JSON_PARSE_RFC)
        : std::nullopt;
    const base::DictValue* root = envelope && envelope->is_dict()
                                      ? &envelope->GetDict() : nullptr;
    if (root && (root->contains("probeQuitDialogCancellation") ||
                 root->contains("probeVisibleForRenderer")) &&
        !shaar::lifecycle::HasOwnedProbeRoot(engine))
      return Fail(error, SHAAR_POLICY_BLOCKED,
                  "DevTools test command requires an owned probe root");
    shaar_devtools_capability parsed_capability;
    base::DictValue params;
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

  const ReplyContext request{request_id, reply, reply_context};
  if (operation == SHAAR_OP_DEVTOOLS_CALL) {
    std::string protocol_request;
    std::string reason;
    const shaar_error_code status =
        EncodeProtocolRequest(args_json, request_id, &protocol_request, &reason);
    if (status != SHAAR_OK)
      return Fail(error, status, reason.c_str());
    auto host = ProtocolAgentHostFor(contents);
    if (!host)
      return Fail(error, SHAAR_NOT_READY, "DevTools protocol target is unavailable");
    std::string main_frame_id;
    if (parsed_command == SHAAR_DEVTOOLS_RUNTIME_EVALUATE) {
      auto* frame = contents->GetPrimaryMainFrame();
      if (!frame)
        return Fail(error, SHAAR_NOT_READY,
                    "DevTools main frame is unavailable");
      main_frame_id = frame->GetDevToolsFrameToken().ToString();
    }
    base::ScopedClosureRunner visibility_lease;
    auto envelope = base::JSONReader::Read(
        std::string_view(args_json.data, args_json.size), base::JSON_PARSE_RFC);
    if (envelope->GetDict().contains("probeVisibleForRenderer")) {
      const auto& url = contents->GetLastCommittedURL();
      if (!scope.private_session || !url.SchemeIs("http") ||
          url.host() != "127.0.0.1" ||
          !context->browser_tabs->IsSelectedWebContents(engine, window, tab, contents) ||
          !windows_tabs::HasHiddenNativeWindow(contents))
        return Fail(error, SHAAR_POLICY_BLOCKED, "visibility probe requires selected hidden private loopback tab");
      auto weak_contents = contents->GetWeakPtr();
      visibility_lease = StartHiddenProbeCapture(contents);
      if (!visibility_lease)
        return Fail(error, SHAAR_NOT_READY, "renderer visibility probe already active");
      if (!weak_contents ||
          context->browser_tabs->FindWebContents(engine, window, tab) != weak_contents.get() ||
          !context->browser_tabs->IsSelectedWebContents(engine, window, tab, weak_contents.get()) ||
          !windows_tabs::HasHiddenNativeWindow(weak_contents.get()) ||
          !weak_contents->GetPrimaryMainFrame() ||
          weak_contents->GetPrimaryMainFrame()->GetDevToolsFrameToken().ToString() != main_frame_id)
        return Fail(error, SHAAR_NOT_READY, "visibility probe target changed");
    }
    if (!StartProtocolRequest(std::move(host), request_id, reply,
                              reply_context, protocol_request,
                              std::move(main_frame_id),
                              std::move(visibility_lease))) {
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
  if (operation == SHAAR_OP_DEVTOOLS_UI_SET_DOCK) {
    // Docking remains unavailable until Chromium exposes Shaar's borrowed
    // frontend view and resize strategy through the shared window host.
    return Fail(error, SHAAR_UNSUPPORTED_CAPABILITY,
                "DevTools docking is not available");
  }

  const bool frontend_was_open =
      DevToolsWindow::GetInstanceForInspectedWebContents(contents) != nullptr;
  if (operation == SHAAR_OP_DEVTOOLS_UI_SHOW) {
    // Shaar owns the frontend dock, including non-primary OTR profiles.
    if (!DevToolsWindow::GetInstanceForInspectedWebContents(contents))
      DevToolsSettings(Profile::FromBrowserContext(contents->GetBrowserContext()))
          .Set("currentDockState", "\"right\"");
    DevToolsWindow::OpenDevToolsWindow(
        contents, Profile::FromBrowserContext(contents->GetBrowserContext()),
        DevToolsOpenedByAction::kUnknown, {});
    if (!DevToolsWindow::GetInstanceForInspectedWebContents(contents))
      return Fail(error, SHAAR_NOT_READY, "DevTools frontend could not open");
    windows_tabs::UpdateDockedDevTools(contents,
        DevToolsWindow::GetInstanceForInspectedWebContents(contents)->GetDevToolsWebContents());
  } else if (operation == SHAAR_OP_DEVTOOLS_UI_CLOSE) {
    if (auto* devtools =
            DevToolsWindow::GetInstanceForInspectedWebContents(contents)) {
      devtools->GetDevToolsWebContents()->ClosePage();
    }
  } else if (operation == SHAAR_OP_DEVTOOLS_UI_STATE) {
    const bool open =
        DevToolsWindow::GetInstanceForInspectedWebContents(contents) != nullptr;
    std::string payload = open
                              ? "{\"schemaVersion\":1,\"open\":true}"
                              : "{\"schemaVersion\":1,\"open\":false}";
    Reply(request, SHAAR_OK, std::move(payload));
    return SHAAR_OK;
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
  if ((operation == SHAAR_OP_DEVTOOLS_UI_SHOW ||
       operation == SHAAR_OP_DEVTOOLS_UI_CLOSE) &&
      frontend_was_open !=
          (DevToolsWindow::GetInstanceForInspectedWebContents(contents) != nullptr)) {
    const bool open =
        DevToolsWindow::GetInstanceForInspectedWebContents(contents) != nullptr;
    EmitFrontendStateEvent(engine, identity, open);
  }
  Reply(request, SHAAR_OK, "{\"schemaVersion\":1}");
  return SHAAR_OK;
}

}  // namespace shaar::devtools
