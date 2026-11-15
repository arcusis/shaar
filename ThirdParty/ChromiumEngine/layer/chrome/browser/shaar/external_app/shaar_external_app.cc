// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#include "chrome/browser/shaar/external_app/shaar_external_app.h"

#include <cstdint>
#include <cstdlib>
#include <map>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

#include "base/functional/bind.h"
#include "base/json/json_writer.h"
#include "base/memory/weak_ptr.h"
#include "base/no_destructor.h"
#include "base/strings/utf_string_conversions.h"
#include "base/task/sequenced_task_runner.h"
#include "base/time/time.h"
#include "base/values.h"
#include "chrome/browser/platform_util.h"
#include "chrome/browser/shaar/engine/shaar_event_bridge.h"
#include "chrome/browser/shaar/lifecycle/shaar_lifecycle.h"
#include "chrome/browser/shaar/windows_tabs/shaar_windows_tabs.h"
#include "content/public/browser/render_frame_host.h"
#include "content/public/browser/weak_document_ptr.h"
#include "content/public/browser/web_contents.h"

namespace shaar::external_app {
namespace {

struct PendingRequest {
  shaar_engine* engine;
  base::WeakPtr<content::WebContents> contents;
  content::WeakDocumentPtr document;
  shaar_window* window;
  shaar_tab* tab;
  std::string profile_id;
  std::string window_id;
  std::string tab_id;
  GURL page_url;
  GURL target_url;
};

std::map<std::string, PendingRequest>& Pending() {
  static base::NoDestructor<std::map<std::string, PendingRequest>> pending;
  return *pending;
}

std::vector<std::string>& ProbeLaunches() {
  static base::NoDestructor<std::vector<std::string>> launches;
  return *launches;
}

uint64_t& NextID() {
  static uint64_t next_id = 1;
  return next_id;
}

bool ProbeMode(shaar_engine* engine) {
  const char* testing = std::getenv("SHAAR_ENGINE_TESTING");
  return testing && std::string_view(testing) == "1" &&
         lifecycle::HasOwnedProbeRoot(engine);
}

void Dismiss(const std::string& id) {
  auto found = Pending().find(id);
  if (found == Pending().end())
    return;
  PendingRequest request = std::move(found->second);
  Pending().erase(found);
  base::DictValue payload;
  payload.Set("schemaVersion", 1);
  payload.Set("kind", "externalAppDismissed");
  payload.Set("id", id);
  std::string json;
  if (base::JSONWriter::Write(payload, &json) &&
      lifecycle::EngineIsReady(request.engine)) {
    EmitEvent(request.engine, SHAAR_EVENT_PERMISSION,
              {request.profile_id.data(), request.profile_id.size()}, {},
              {request.window_id.data(), request.window_id.size()},
              {request.tab_id.data(), request.tab_id.size()},
              {json.data(), json.size()});
  }
}

bool IsCurrent(const PendingRequest& request) {
  if (!lifecycle::EngineIsReady(request.engine) || !request.contents ||
      !request.document.AsRenderFrameHostIfValid())
    return false;
  auto current = windows_tabs::Registry().FindSelectedRegularTab(
      request.engine, request.contents.get());
  return current && current->window == request.window &&
         current->tab == request.tab &&
         current->profile_id == request.profile_id &&
         current->window_id == request.window_id &&
         current->tab_id == request.tab_id &&
         request.contents->GetLastCommittedURL() == request.page_url;
}

void Sweep(const std::string& id) {
  auto found = Pending().find(id);
  if (found == Pending().end())
    return;
  if (!IsCurrent(found->second)) {
    Dismiss(id);
    return;
  }
  base::SequencedTaskRunner::GetCurrentDefault()->PostDelayedTask(
      FROM_HERE, base::BindOnce(&Sweep, id), base::Milliseconds(100));
}

}  // namespace

bool Request(const GURL& url, content::WebContents* contents,
             const std::optional<url::Origin>& origin,
             const std::u16string& application_name) {
  shaar_engine* engine = lifecycle::ActiveEngine();
  if (!engine)
    return false;
  auto identity = windows_tabs::Registry().FindSelectedRegularTab(engine, contents);
  content::RenderFrameHost* frame =
      contents ? contents->GetPrimaryMainFrame() : nullptr;
  const GURL page_url = contents ? contents->GetLastCommittedURL() : GURL();
  if (!identity || !frame || !page_url.SchemeIsHTTPOrHTTPS() || !url.is_valid() ||
      url.spec().size() > 4096 || application_name.empty() ||
      application_name.size() > 256 || Pending().size() >= 64) {
    return true;  // Shaar owns this flow; never fall back to a native dialog.
  }

  const std::string id = "x" + std::to_string(NextID()++);
  base::DictValue payload;
  payload.Set("schemaVersion", 1);
  payload.Set("kind", "externalAppRequested");
  payload.Set("id", id);
  payload.Set("pageURL", page_url.spec());
  payload.Set("scheme", url.scheme());
  if (origin && !origin->opaque() &&
      origin->GetURL().SchemeIsHTTPOrHTTPS()) {
    payload.Set("origin", origin->GetURL().spec());
  } else {
    payload.Set("origin", base::Value());
  }
  payload.Set("app", base::UTF16ToUTF8(application_name));
  std::string json;
  if (!base::JSONWriter::Write(payload, &json))
    return true;

  Pending().emplace(id, PendingRequest{
      engine, contents->GetWeakPtr(), frame->GetWeakDocumentPtr(),
      identity->window, identity->tab,
      identity->profile_id, identity->window_id, identity->tab_id,
      page_url, url});
  const shaar_error_code status = EmitEvent(
      engine, SHAAR_EVENT_PERMISSION,
      {identity->profile_id.data(), identity->profile_id.size()}, {},
      {identity->window_id.data(), identity->window_id.size()},
      {identity->tab_id.data(), identity->tab_id.size()},
      {json.data(), json.size()});
  if (status != SHAAR_OK) {
    Dismiss(id);
  } else {
    base::SequencedTaskRunner::GetCurrentDefault()->PostDelayedTask(
        FROM_HERE, base::BindOnce(&Dismiss, id), base::Minutes(2));
    base::SequencedTaskRunner::GetCurrentDefault()->PostDelayedTask(
        FROM_HERE, base::BindOnce(&Sweep, id), base::Milliseconds(100));
  }
  return true;
}

shaar_error_code Resolve(const char* request_id, bool accepted) {
  if (!request_id)
    return SHAAR_INVALID_ARGUMENT;
  auto found = Pending().find(request_id);
  if (found == Pending().end())
    return SHAAR_NOT_FOUND;
  const PendingRequest request = found->second;
  const bool current = IsCurrent(request);
  Dismiss(request_id);  // Consume before any app launch or callback.
  if (!current)
    return SHAAR_CANCELLED;
  if (!accepted)
    return SHAAR_OK;
  if (ProbeMode(request.engine)) {
    if (ProbeLaunches().size() < 256)
      ProbeLaunches().push_back(request.target_url.spec());
  } else {
    platform_util::OpenExternal(request.target_url);
  }
  return SHAAR_OK;
}

const char* ProbeLaunchesJSON() {
  shaar_engine* engine = lifecycle::ActiveEngine();
  if (!engine || !ProbeMode(engine))
    return nullptr;
  base::ListValue entries;
  for (const std::string& url : ProbeLaunches()) {
    base::DictValue entry;
    entry.Set("url", url);
    entry.Set("remembered", false);
    entries.Append(std::move(entry));
  }
  static std::string json;
  if (!base::JSONWriter::Write(entries, &json))
    return nullptr;
  return json.c_str();
}

}  // namespace shaar::external_app

extern "C" SHAAR_EXPORT shaar_error_code shaar_external_app_reply(
    const char* request_id, int accepted) {
  if (accepted != 0 && accepted != 1)
    return SHAAR_INVALID_ARGUMENT;
  return shaar::external_app::Resolve(request_id, accepted == 1);
}

extern "C" SHAAR_EXPORT const char* shaar_external_app_probe_launches_json() {
  return shaar::external_app::ProbeLaunchesJSON();
}
