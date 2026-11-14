// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#include "chrome/browser/shaar/webshare/shaar_webshare.h"

#include <cstdint>
#include <map>
#include <string>
#include <utility>

#include "base/functional/bind.h"
#include "base/json/json_writer.h"
#include "base/no_destructor.h"
#include "base/task/sequenced_task_runner.h"
#include "base/time/time.h"
#include "base/uuid.h"
#include "base/values.h"
#include "chrome/browser/shaar/engine/shaar_event_bridge.h"
#include "chrome/browser/shaar/lifecycle/shaar_lifecycle.h"
#include "chrome/browser/shaar/windows_tabs/shaar_windows_tabs.h"
#include "content/public/browser/render_frame_host.h"
#include "content/public/browser/web_contents.h"
#include "url/gurl.h"
#include "url/origin.h"

namespace shaar::webshare {
namespace {

struct PendingShare {
  shaar_engine *engine;
  content::WebContents *contents;
  shaar_window *window;
  shaar_tab *tab;
  std::string profile_id;
  std::string window_id;
  std::string tab_id;
  GURL page_url;
  url::Origin origin;
  int render_process_id;
  int render_frame_id;
  int64_t navigation_id;
  ShareCallback callback;
};

using PendingMap = std::map<std::string, PendingShare>;

PendingMap &Pending() {
  static base::NoDestructor<PendingMap> pending;
  return *pending;
}

bool IsWithinLimit(std::string_view value, size_t limit) {
  return value.size() <= limit;
}

void Finish(std::string_view id, blink::mojom::ShareError result) {
  auto found = Pending().find(std::string(id));
  if (found == Pending().end())
    return;
  ShareCallback callback = std::move(found->second.callback);
  Pending().erase(found);
  std::move(callback).Run(result);
}

bool IsCurrent(const PendingShare &pending) {
  if (!lifecycle::EngineIsReady(pending.engine))
    return false;
  auto identity = windows_tabs::Registry().FindSelectedRegularTab(
      pending.engine, pending.contents);
  content::RenderFrameHost *frame = content::RenderFrameHost::FromID(
      pending.render_process_id, pending.render_frame_id);
  return identity && identity->window == pending.window &&
         identity->tab == pending.tab &&
         identity->profile_id == pending.profile_id &&
         identity->window_id == pending.window_id &&
         identity->tab_id == pending.tab_id &&
         pending.contents->GetLastCommittedURL() == pending.page_url && frame &&
         frame->IsActive() &&
         frame->GetNavigationId() == pending.navigation_id &&
         content::WebContents::FromRenderFrameHost(frame) == pending.contents &&
         frame->GetLastCommittedOrigin() == pending.origin;
}

void Expire(std::string id) { Finish(id, blink::mojom::ShareError::CANCELLED); }

} // namespace

bool IsActive() { return lifecycle::ActiveEngine() != nullptr; }

bool Request(content::RenderFrameHost *frame, std::string_view title,
             std::string_view text, const GURL &share_url,
             std::vector<blink::mojom::SharedFilePtr> files,
             bool user_activated, ShareCallback callback) {
  shaar_engine *engine = lifecycle::ActiveEngine();
  if (!engine)
    return false;

  content::WebContents *contents =
      frame ? content::WebContents::FromRenderFrameHost(frame) : nullptr;
  auto identity =
      windows_tabs::Registry().FindSelectedRegularTab(engine, contents);
  const GURL page_url = contents ? contents->GetLastCommittedURL() : GURL();
  const url::Origin origin =
      frame ? frame->GetLastCommittedOrigin() : url::Origin();
  if (!frame || !contents || !identity || !user_activated ||
      !frame->IsActive() || !page_url.SchemeIsHTTPOrHTTPS() ||
      !origin.GetURL().SchemeIsHTTPOrHTTPS() || !files.empty() ||
      Pending().size() >= 32 || !IsWithinLimit(title, 2048) ||
      !IsWithinLimit(text, 4096) || !IsWithinLimit(share_url.spec(), 4096) ||
      (!share_url.is_empty() && !share_url.SchemeIsHTTPOrHTTPS())) {
    std::move(callback).Run(blink::mojom::ShareError::PERMISSION_DENIED);
    return true;
  }

  const std::string id = base::Uuid::GenerateRandomV4().AsLowercaseString();
  const std::string frame_id = frame->GetFrameToken().ToString();
  base::DictValue payload;
  payload.Set("schemaVersion", 1);
  payload.Set("kind", "webShareRequested");
  payload.Set("id", id);
  payload.Set("pageURL", page_url.spec());
  payload.Set("origin", origin.GetURL().spec());
  payload.Set("frameID", frame_id);
  payload.Set("userActivated", user_activated);
  payload.Set("title", title);
  payload.Set("text", text);
  payload.Set("url", share_url.spec());
  std::string json;
  if (!base::JSONWriter::Write(payload, &json)) {
    std::move(callback).Run(blink::mojom::ShareError::PERMISSION_DENIED);
    return true;
  }

  Pending().emplace(
      id, PendingShare{engine, contents, identity->window, identity->tab,
                       identity->profile_id, identity->window_id,
                       identity->tab_id, page_url, origin,
                       frame->GetProcess()->GetID(), frame->GetRoutingID(),
                       frame->GetNavigationId(), std::move(callback)});
  base::SequencedTaskRunner::GetCurrentDefault()->PostDelayedTask(
      FROM_HERE, base::BindOnce(&Expire, id), base::Minutes(2));
  const shaar_error_code result = shaar::EmitEvent(
      engine, SHAAR_EVENT_PERMISSION,
      {identity->profile_id.data(), identity->profile_id.size()}, {},
      {identity->window_id.data(), identity->window_id.size()},
      {identity->tab_id.data(), identity->tab_id.size()},
      {json.data(), json.size()});
  if (result != SHAAR_OK)
    Finish(id, blink::mojom::ShareError::PERMISSION_DENIED);
  return true;
}

shaar_error_code Resolve(shaar_engine *engine, std::string_view request_id,
                         bool shared) {
  auto found = Pending().find(std::string(request_id));
  if (found == Pending().end())
    return SHAAR_NOT_FOUND;
  if (found->second.engine != engine || !IsCurrent(found->second)) {
    Finish(request_id, blink::mojom::ShareError::CANCELLED);
    return SHAAR_CANCELLED;
  }
  Finish(request_id, shared ? blink::mojom::ShareError::OK
                            : blink::mojom::ShareError::CANCELLED);
  return SHAAR_OK;
}

} // namespace shaar::webshare

extern "C" SHAAR_EXPORT shaar_error_code
shaar_share_reply(const char *request_id, int shared) {
  if (!request_id || (shared != 0 && shared != 1))
    return SHAAR_INVALID_ARGUMENT;
  shaar_engine *engine = shaar::lifecycle::ActiveEngine();
  if (!engine)
    return SHAAR_NOT_READY;
  return shaar::webshare::Resolve(engine, request_id, shared == 1);
}
