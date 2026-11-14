// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.

#include "chrome/browser/shaar/find/shaar_page_zoom.h"
#include "chrome/browser/shaar/find/shaar_find.h"

#include <algorithm>
#include <cmath>
#include <iterator>
#include <string>
#include <string_view>

#include "base/functional/bind.h"
#include "base/json/json_reader.h"
#include "base/json/json_writer.h"
#include "base/location.h"
#include "base/memory/raw_ptr.h"
#include "base/task/sequenced_task_runner.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/shaar/engine/shaar_event_bridge.h"
#include "chrome/browser/ui/browser.h"
#include "chrome/browser/ui/tabs/tab_strip_model.h"
#include "components/zoom/page_zoom.h"
#include "components/zoom/zoom_controller.h"
#include "components/zoom/zoom_observer.h"
#include "content/public/browser/host_zoom_map.h"
#include "content/public/browser/web_contents.h"
#include "third_party/blink/public/common/page/page_zoom.h"

namespace {

constexpr char kZoomObserverKey[] = "shaar.page.zoom.observer";

void ReplyZoom(shaar_reply_fn reply, void *context, shaar_request_id id,
               shaar_error_code code, double level) {
  base::SequencedTaskRunner::GetCurrentDefault()->PostTask(
      FROM_HERE, base::BindOnce(
                     [](shaar_reply_fn callback, void *callback_context,
                        shaar_request_id request, shaar_error_code status,
                        double zoom_level) {
                       base::Value::Dict payload;
                       payload.Set("kind", "pageZoom");
                       payload.Set("schemaVersion", 1);
                       payload.Set("zoomLevel", zoom_level);
                       payload.Set("zoomFactor",
                                   blink::ZoomLevelToZoomFactor(zoom_level));
                       std::string json;
                       base::JSONWriter::Write(payload, &json);
                       shaar_result result = {};
                       result.size = sizeof(result);
                       result.request_id = request;
                       result.error.size = sizeof(result.error);
                       result.error.code = status;
                       result.payload_json = {json.data(), json.size()};
                       callback(callback_context, &result);
                     },
                     reply, context, id, code, level));
}

bool ParseZoomAction(shaar_bytes bytes, std::string *action,
                     double *zoom_level) {
  if (!action || !zoom_level || !bytes.data || bytes.size == 0 ||
      bytes.size > 256)
    return false;
  auto value = base::JSONReader::Read(std::string_view(bytes.data, bytes.size),
                                      base::JSON_PARSE_RFC);
  if (!value || !value->is_dict())
    return false;
  const auto &dict = value->GetDict();
  const std::string *requested = dict.FindString("action");
  if (dict.FindInt("schemaVersion") != 1 || !requested ||
      (*requested != "get" && *requested != "set" && *requested != "in" &&
       *requested != "out" && *requested != "reset"))
    return false;
  if (*requested == "set") {
    const base::Value *raw_level = dict.Find("zoomLevel");
    if (dict.size() != 3 || !raw_level ||
        (!raw_level->is_int() && !raw_level->is_double()))
      return false;
    *zoom_level =
        raw_level->is_int() ? raw_level->GetInt() : raw_level->GetDouble();
    if (!std::isfinite(*zoom_level))
      return false;
    const double factor = blink::ZoomLevelToZoomFactor(*zoom_level);
    if (factor < blink::kMinimumBrowserZoomFactor ||
        factor > blink::kMaximumBrowserZoomFactor)
      return false;
  } else if (dict.size() != 2) {
    return false;
  }
  *action = *requested;
  return true;
}

void EmitZoom(shaar_engine *engine, std::string_view profile,
              std::string_view session, std::string_view window,
              std::string_view tab, double level) {
  base::Value::Dict payload;
  payload.Set("kind", "changed");
  payload.Set("schemaVersion", 1);
  payload.Set("zoomLevel", level);
  payload.Set("zoomFactor", blink::ZoomLevelToZoomFactor(level));
  std::string json;
  if (!base::JSONWriter::Write(payload, &json))
    return;
  shaar::EmitEvent(engine, SHAAR_EVENT_ZOOM, {profile.data(), profile.size()},
                   {session.data(), session.size()},
                   {window.data(), window.size()}, {tab.data(), tab.size()},
                   {json.data(), json.size()});
}

class PageZoomObserver final : public base::SupportsUserData::Data,
                               public zoom::ZoomObserver {
public:
  PageZoomObserver(shaar_engine *engine, zoom::ZoomController *controller,
                   std::string profile, std::string session, std::string window,
                   std::string tab)
      : engine_(engine), controller_(controller), profile_(std::move(profile)),
        session_(std::move(session)), window_(std::move(window)),
        tab_(std::move(tab)) {
    controller_->AddObserver(this);
  }
  ~PageZoomObserver() override {
    if (controller_)
      controller_->RemoveObserver(this);
  }
  void OnZoomChanged(
      const zoom::ZoomController::ZoomChangedEventData &change) override {
    if (shaar::EngineIsLive(engine_))
      EmitZoom(engine_, profile_, session_, window_, tab_,
               change.new_zoom_level);
  }
  void OnZoomControllerDestroyed(zoom::ZoomController *controller) override {
    if (controller_ == controller)
      controller_ = nullptr;
  }

private:
  raw_ptr<shaar_engine> engine_;
  raw_ptr<zoom::ZoomController> controller_;
  std::string profile_;
  std::string session_;
  std::string window_;
  std::string tab_;
};

} // namespace

double shaar::page_zoom::NextPresetZoomLevel(double current_level,
                                             int direction) {
  if (direction != -1 && direction != 1)
    return current_level;
  const auto levels = zoom::PageZoom::PresetZoomLevels(current_level);
  if (levels.empty())
    return current_level;
  auto current = std::min_element(
      levels.begin(), levels.end(), [current_level](double a, double b) {
        return std::abs(a - current_level) < std::abs(b - current_level);
      });
  auto index = std::distance(levels.begin(), current);
  index = std::clamp(index + direction, decltype(index)(0),
                     decltype(index)(levels.size() - 1));
  return levels[index];
}

shaar_error_code HandlePageZoomOperation(
    shaar::ShaarEngineContext *context, shaar_engine *engine, shaar_scope scope,
    shaar_window *window, shaar_tab *tab, shaar_operation operation,
    shaar_bytes args_json, shaar_request_id request_id, shaar_reply_fn reply,
    void *reply_context, shaar_error *) {
  if (!context || !context->browser_tabs || !engine || !window || !tab ||
      operation != SHAAR_OP_TAB_ZOOM || !request_id || !reply)
    return SHAAR_INVALID_ARGUMENT;
  std::string action;
  double requested_level = 0;
  if (!ParseZoomAction(args_json, &action, &requested_level))
    return SHAAR_INVALID_ARGUMENT;
  content::WebContents *contents =
      context->browser_tabs->FindWebContents(engine, window, tab);
  Browser *browser = context->browser_tabs->FindBrowser(engine, window);
  if (!contents || !browser)
    return SHAAR_NOT_FOUND;
  if (browser->tab_strip_model()->GetActiveWebContents() != contents)
    return SHAAR_CONFLICT;

  std::string_view profile_id;
  std::string_view session_id;
  if (scope.profile && !scope.private_session) {
    Profile *profile =
        context->profile_services
            ? context->profile_services->ResolveProfile(engine, scope.profile)
            : nullptr;
    profile_id =
        context->profile_services
            ? context->profile_services->ProfileID(engine, scope.profile)
            : std::string_view();
    if (!profile || profile_id.empty())
      return SHAAR_NOT_FOUND;
    if (contents->GetBrowserContext() != profile)
      return SHAAR_WRONG_PROFILE;
  } else if (scope.private_session && !scope.profile) {
    Profile *parent = nullptr, *otr = nullptr;
    if (!context->private_sessions ||
        !context->private_sessions->Resolve(engine, scope.private_session,
                                            &parent, &otr, &profile_id,
                                            &session_id))
      return SHAAR_WRONG_SESSION;
    if (!otr || contents->GetBrowserContext() != otr)
      return SHAAR_WRONG_SESSION;
  } else {
    return SHAAR_INVALID_ARGUMENT;
  }

  zoom::ZoomController *controller =
      zoom::ZoomController::FromWebContents(contents);
  if (!controller)
    controller = zoom::ZoomController::CreateForWebContents(contents);
  if (!controller)
    return SHAAR_NOT_READY;
  if (!contents->GetUserData(
          reinterpret_cast<const void *>(kZoomObserverKey))) {
    contents->SetUserData(
        reinterpret_cast<const void *>(kZoomObserverKey),
        std::make_unique<PageZoomObserver>(
            engine, controller, std::string(profile_id),
            std::string(session_id),
            std::string(context->browser_tabs->WindowID(engine, window)),
            std::string(context->browser_tabs->TabID(engine, window, tab))));
  }
  const double current = controller->GetZoomLevel();
  double next = current;
  if (action == "get") {
    ReplyZoom(reply, reply_context, request_id, SHAAR_OK, current);
    return SHAAR_OK;
  } else if (action == "set") {
    next = requested_level;
    controller->SetZoomMode(zoom::ZoomController::ZOOM_MODE_DEFAULT);
    if (!controller->SetZoomLevel(next))
      return SHAAR_CHROMIUM_ERROR;
  } else if (action == "reset") {
    controller->SetZoomMode(zoom::ZoomController::ZOOM_MODE_DEFAULT);
    next = controller->GetDefaultZoomLevel();
    if (!controller->SetZoomLevel(next))
      return SHAAR_CHROMIUM_ERROR;
  } else {
    next =
        shaar::page_zoom::NextPresetZoomLevel(current, action == "in" ? 1 : -1);
    controller->SetZoomMode(zoom::ZoomController::ZOOM_MODE_DEFAULT);
    if (!controller->SetZoomLevel(next))
      return SHAAR_CHROMIUM_ERROR;
  }
  ReplyZoom(reply, reply_context, request_id, SHAAR_OK, next);
  return SHAAR_OK;
}
