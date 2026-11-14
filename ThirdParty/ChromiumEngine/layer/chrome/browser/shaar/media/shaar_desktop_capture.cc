// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#include "chrome/browser/shaar/media/shaar_desktop_capture.h"

#include <charconv>
#include <map>
#include <memory>
#include <set>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

#include "base/functional/bind.h"
#include "base/json/json_writer.h"
#include "base/no_destructor.h"
#include "base/strings/string_number_conversions.h"
#include "base/task/sequenced_task_runner.h"
#include "base/time/time.h"
#include "base/uuid.h"
#include "base/values.h"
#include "chrome/browser/shaar/engine/shaar_event_bridge.h"
#include "chrome/browser/shaar/lifecycle/shaar_lifecycle.h"
#include "chrome/browser/shaar/windows_tabs/shaar_windows_tabs.h"
#include "content/public/browser/media_stream_request.h"
#include "content/public/browser/render_frame_host.h"
#include "content/public/browser/web_contents.h"
#include "content/public/browser/web_contents_media_capture_id.h"
#include "url/origin.h"

namespace shaar::desktop_capture {
namespace {

using DoneCallback = DesktopMediaPicker::DoneCallback;
using PickerResult = DesktopMediaPicker::DoneCallbackArgumentType;
using CaptureError = blink::mojom::MediaStreamRequestResult;

struct PendingCapture {
  shaar_engine* engine;
  shaar_window* window;
  shaar_tab* tab;
  content::WebContents* contents;
  std::string profile_id;
  std::string window_id;
  std::string tab_id;
  GURL page_url;
  url::Origin origin;
  std::string frame_id;
  int process_id;
  int frame_routing_id;
  int64_t navigation_id;
  std::set<std::string> source_types;
  DoneCallback callback;
};

using PendingMap = std::map<std::string, PendingCapture>;

PendingMap& Pending() {
  static base::NoDestructor<PendingMap> pending;
  return *pending;
}

void Finish(std::string_view prompt_id, PickerResult result) {
  auto found = Pending().find(std::string(prompt_id));
  if (found == Pending().end()) {
    return;
  }
  DoneCallback callback = std::move(found->second.callback);
  Pending().erase(found);
  std::move(callback).Run(std::move(result));
}

void NotifyDismissal(const PendingCapture& pending, std::string_view prompt_id) {
  if (!lifecycle::EngineIsReady(pending.engine)) {
    return;
  }
  base::DictValue payload;
  payload.Set("schemaVersion", 1);
  payload.Set("kind", "desktopCaptureDismissed");
  payload.Set("id", prompt_id);
  std::string json;
  if (!base::JSONWriter::Write(payload, &json)) {
    return;
  }
  shaar::EmitEvent(
      pending.engine, SHAAR_EVENT_PERMISSION,
      {pending.profile_id.data(), pending.profile_id.size()}, {},
      {pending.window_id.data(), pending.window_id.size()},
      {pending.tab_id.data(), pending.tab_id.size()},
      {json.data(), json.size()});
}

void Cancel(std::string prompt_id) {
  auto found = Pending().find(prompt_id);
  if (found == Pending().end()) {
    return;
  }
  NotifyDismissal(found->second, prompt_id);
  Finish(prompt_id, base::unexpected(CaptureError::PERMISSION_DENIED_BY_USER));
}

bool IsCurrent(const PendingCapture& pending) {
  if (!lifecycle::EngineIsReady(pending.engine)) {
    return false;
  }
  auto identity = windows_tabs::Registry().FindSelectedRegularTab(
      pending.engine, pending.contents);
  content::RenderFrameHost* frame = content::RenderFrameHost::FromID(
      pending.process_id, pending.frame_routing_id);
  return identity && identity->window == pending.window &&
         identity->tab == pending.tab &&
         identity->profile_id == pending.profile_id &&
         identity->window_id == pending.window_id &&
         identity->tab_id == pending.tab_id &&
         pending.contents->GetLastCommittedURL() == pending.page_url && frame &&
         frame->IsActive() &&
         frame->GetNavigationId() == pending.navigation_id &&
         frame->GetLastCommittedOrigin() == pending.origin &&
         frame->GetFrameToken().ToString() == pending.frame_id &&
         content::WebContents::FromRenderFrameHost(frame) == pending.contents;
}

std::string SourceType(DesktopMediaList::Type type) {
  switch (type) {
    case DesktopMediaList::Type::kScreen:
      return "screen";
    case DesktopMediaList::Type::kWindow:
      return "window";
    case DesktopMediaList::Type::kWebContents:
    case DesktopMediaList::Type::kCurrentTab:
      return "tab";
    case DesktopMediaList::Type::kNone:
      return {};
  }
  return {};
}

bool ParseSourceToken(std::string_view token,
                      std::string* type,
                      std::string* value) {
  const size_t first = token.find(':');
  const size_t second = first == std::string_view::npos
                            ? std::string_view::npos
                            : token.find(':', first + 1);
  if (first == std::string_view::npos || second == std::string_view::npos ||
      token.find(':', second + 1) != std::string_view::npos ||
      token.substr(second + 1) != "0") {
    return false;
  }
  *type = std::string(token.substr(0, first));
  *value = std::string(token.substr(first + 1, second - first - 1));
  if (*type == "tab") {
    base::Uuid uuid = base::Uuid::ParseCaseInsensitive(*value);
    if (!uuid.is_valid()) {
      return false;
    }
    return true;
  }
  uint32_t native_id = 0;
  const std::string_view digits = *value;
  const auto [end, error] =
      std::from_chars(digits.data(), digits.data() + digits.size(), native_id);
  return (*type == "screen" || *type == "window") && error == std::errc() &&
         end == digits.data() + digits.size() && native_id > 0 &&
         std::to_string(native_id) == digits;
}

bool MakeMediaID(PendingCapture& pending,
                 std::string_view token,
                 content::DesktopMediaID* media_id) {
  std::string type;
  std::string value;
  if (!ParseSourceToken(token, &type, &value) ||
      !pending.source_types.contains(type)) {
    return false;
  }
  if (type == "screen" || type == "window") {
    uint32_t native_id = 0;
    if (!base::StringToUint(value, &native_id) || native_id == 0) {
      return false;
    }
    media_id->type = type == "screen" ? content::DesktopMediaID::TYPE_SCREEN
                                      : content::DesktopMediaID::TYPE_WINDOW;
    media_id->id = native_id;
    return true;
  }

  content::WebContents* target =
      windows_tabs::Registry().FindWebContentsByID(pending.engine, value);
  content::RenderFrameHost* main_frame =
      target ? target->GetPrimaryMainFrame() : nullptr;
  if (!main_frame ||
      target->GetBrowserContext() != pending.contents->GetBrowserContext()) {
    return false;
  }
  media_id->type = content::DesktopMediaID::TYPE_WEB_CONTENTS;
  media_id->web_contents_id = content::WebContentsMediaCaptureId(
      main_frame->GetProcess()->GetID(), main_frame->GetRoutingID());
  return true;
}

class ShaarDesktopMediaPicker final : public DesktopMediaPicker {
 public:
  explicit ShaarDesktopMediaPicker(const content::MediaStreamRequest& request)
      : process_id_(request.render_process_id),
        frame_id_(request.render_frame_id) {}

  ShaarDesktopMediaPicker(const ShaarDesktopMediaPicker&) = delete;
  ShaarDesktopMediaPicker& operator=(const ShaarDesktopMediaPicker&) = delete;
  ~ShaarDesktopMediaPicker() override = default;

  void Show(const Params&,
            std::vector<std::unique_ptr<DesktopMediaList>> source_lists,
            DoneCallback done_callback) override {
    content::RenderFrameHost* frame =
        content::RenderFrameHost::FromID(process_id_, frame_id_);
    content::WebContents* contents =
        frame ? content::WebContents::FromRenderFrameHost(frame) : nullptr;
    shaar_engine* engine = lifecycle::ActiveEngine();
    auto identity =
        windows_tabs::Registry().FindSelectedRegularTab(engine, contents);
    if (!engine || !contents || !identity || !frame || !frame->IsActive() ||
        !frame->HasTransientUserActivation()) {
      std::move(done_callback)
          .Run(base::unexpected(CaptureError::NO_TRANSIENT_ACTIVATION));
      return;
    }

    const GURL page_url = contents->GetLastCommittedURL();
    const url::Origin origin = frame->GetLastCommittedOrigin();
    std::set<std::string> source_types;
    for (const auto& source_list : source_lists) {
      const std::string type = SourceType(source_list->GetMediaListType());
      if (!type.empty()) {
        source_types.insert(type);
      }
    }
    if (!page_url.SchemeIsHTTPOrHTTPS() ||
        !origin.GetURL().SchemeIsHTTPOrHTTPS() || source_types.empty() ||
        Pending().size() >= 32) {
      std::move(done_callback)
          .Run(base::unexpected(CaptureError::PERMISSION_DENIED));
      return;
    }

    const std::string prompt_id =
        base::Uuid::GenerateRandomV4().AsLowercaseString();
    const std::string frame_token = frame->GetFrameToken().ToString();
    base::DictValue payload;
    payload.Set("schemaVersion", 1);
    payload.Set("kind", "desktopCaptureRequested");
    payload.Set("id", prompt_id);
    payload.Set("pageURL", page_url.spec());
    payload.Set("origin", origin.GetURL().spec());
    payload.Set("frameID", frame_token);
    base::ListValue types;
    for (const auto& type : source_types) {
      types.Append(type);
    }
    payload.Set("sourceTypes", std::move(types));
    std::string json;
    if (!base::JSONWriter::Write(payload, &json)) {
      std::move(done_callback)
          .Run(base::unexpected(CaptureError::PERMISSION_DENIED));
      return;
    }

    Pending().emplace(
        prompt_id,
        PendingCapture{engine, identity->window, identity->tab, contents,
                       identity->profile_id, identity->window_id,
                       identity->tab_id, page_url, origin, frame_token,
                       process_id_, frame_id_, frame->GetNavigationId(),
                       std::move(source_types), std::move(done_callback)});
    base::SequencedTaskRunner::GetCurrentDefault()->PostDelayedTask(
        FROM_HERE, base::BindOnce(&Cancel, prompt_id), base::Minutes(2));
    const shaar_error_code result = shaar::EmitEvent(
        engine, SHAAR_EVENT_PERMISSION,
        {identity->profile_id.data(), identity->profile_id.size()}, {},
        {identity->window_id.data(), identity->window_id.size()},
        {identity->tab_id.data(), identity->tab_id.size()},
        {json.data(), json.size()});
    if (result != SHAAR_OK) {
      Cancel(prompt_id);
    }
  }

 private:
  int process_id_;
  int frame_id_;
};

}  // namespace

bool IsActive() {
  return lifecycle::ActiveEngine() != nullptr;
}

std::unique_ptr<DesktopMediaPicker> CreatePicker(
    const content::MediaStreamRequest& request) {
  return std::make_unique<ShaarDesktopMediaPicker>(request);
}

shaar_error_code Resolve(shaar_engine* engine,
                         shaar_window* window,
                         shaar_tab* tab,
                         std::string_view prompt_id,
                         std::string_view decision,
                         std::string_view source_token) {
  auto found = Pending().find(std::string(prompt_id));
  if (found == Pending().end()) {
    return SHAAR_NOT_FOUND;
  }
  PendingCapture& pending = found->second;
  if (pending.engine != engine || pending.window != window ||
      pending.tab != tab || !IsCurrent(pending)) {
    Cancel(std::string(prompt_id));
    return SHAAR_CANCELLED;
  }
  if (decision == "cancel") {
    Cancel(std::string(prompt_id));
    return SHAAR_OK;
  }
  if (decision != "approve" || source_token.empty()) {
    Cancel(std::string(prompt_id));
    return SHAAR_INVALID_ARGUMENT;
  }
  content::DesktopMediaID media_id;
  if (!MakeMediaID(pending, source_token, &media_id)) {
    Cancel(std::string(prompt_id));
    return SHAAR_PERMISSION_DENIED;
  }
  Finish(prompt_id, base::ok(media_id));
  return SHAAR_OK;
}

}  // namespace shaar::desktop_capture
