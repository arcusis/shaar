// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#include "chrome/browser/shaar/printing/shaar_print.h"

#include <map>
#include <string>
#include <utility>

#include "base/functional/bind.h"
#include "base/json/json_writer.h"
#include "base/no_destructor.h"
#include "base/strings/utf_string_conversions.h"
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

namespace shaar::printing {
namespace {

struct PendingPrint {
  shaar_engine* engine;
  content::WebContents* contents;
  shaar_window* window;
  shaar_tab* tab;
  std::string profile_id;
  std::string window_id;
  std::string tab_id;
  GURL page_url;
  url::Origin origin;
  std::string frame_id;
  int process_id;
  int routing_id;
  int64_t navigation_id;
  base::OnceCallback<void(bool)> decision;
};

using PendingMap = std::map<std::string, PendingPrint>;

PendingMap& Pending() {
  static base::NoDestructor<PendingMap> pending;
  return *pending;
}

void Finish(std::string_view request_id, bool accepted) {
  auto found = Pending().find(std::string(request_id));
  if (found == Pending().end()) {
    return;
  }
  auto decision = std::move(found->second.decision);
  Pending().erase(found);
  std::move(decision).Run(accepted);
}

void Expire(std::string request_id) {
  Finish(request_id, /*accepted=*/false);
}

bool IsCurrent(const PendingPrint& pending) {
  if (!lifecycle::EngineIsReady(pending.engine)) {
    return false;
  }
  auto identity = windows_tabs::Registry().FindSelectedRegularTab(
      pending.engine, pending.contents);
  content::RenderFrameHost* frame =
      content::RenderFrameHost::FromID(pending.process_id, pending.routing_id);
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

}  // namespace

bool IsActive() {
  return lifecycle::ActiveEngine() != nullptr;
}

void Request(content::WebContents* contents,
             content::RenderFrameHost* frame,
             base::OnceCallback<void(bool)> decision) {
  shaar_engine* engine = lifecycle::ActiveEngine();
  auto identity =
      windows_tabs::Registry().FindSelectedRegularTab(engine, contents);
  const GURL page_url = contents ? contents->GetLastCommittedURL() : GURL();
  const url::Origin origin =
      frame ? frame->GetLastCommittedOrigin() : url::Origin();
  const std::string title =
      contents ? base::UTF16ToUTF8(contents->GetTitle()) : std::string();
  if (!engine || !contents || !frame || !identity || !frame->IsActive() ||
      content::WebContents::FromRenderFrameHost(frame) != contents ||
      Pending().size() >= 32 || !page_url.is_valid() ||
      page_url.spec().size() > 4096 || origin.GetURL().spec().size() > 2048 ||
      title.size() > 2048) {
    std::move(decision).Run(false);
    return;
  }

  const std::string request_id =
      base::Uuid::GenerateRandomV4().AsLowercaseString();
  const std::string frame_id = frame->GetFrameToken().ToString();
  base::DictValue payload;
  payload.Set("schemaVersion", 1);
  payload.Set("kind", "printRequested");
  payload.Set("id", request_id);
  payload.Set("pageURL", page_url.spec());
  payload.Set("origin", origin.GetURL().spec());
  payload.Set("frameID", frame_id);
  payload.Set("title", title);
  std::string json;
  if (!base::JSONWriter::Write(payload, &json)) {
    std::move(decision).Run(false);
    return;
  }

  Pending().emplace(
      request_id,
      PendingPrint{engine, contents, identity->window, identity->tab,
                   identity->profile_id, identity->window_id, identity->tab_id,
                   page_url, origin, frame_id, frame->GetProcess()->GetID(),
                   frame->GetRoutingID(), frame->GetNavigationId(),
                   std::move(decision)});
  base::SequencedTaskRunner::GetCurrentDefault()->PostDelayedTask(
      FROM_HERE, base::BindOnce(&Expire, request_id), base::Minutes(2));
  const shaar_error_code result = shaar::EmitEvent(
      engine, SHAAR_EVENT_PERMISSION,
      {identity->profile_id.data(), identity->profile_id.size()}, {},
      {identity->window_id.data(), identity->window_id.size()},
      {identity->tab_id.data(), identity->tab_id.size()},
      {json.data(), json.size()});
  if (result != SHAAR_OK) {
    Finish(request_id, /*accepted=*/false);
  }
}

shaar_error_code Resolve(shaar_engine* engine,
                         std::string_view request_id,
                         bool accepted) {
  auto found = Pending().find(std::string(request_id));
  if (found == Pending().end()) {
    return SHAAR_NOT_FOUND;
  }
  if (found->second.engine != engine || !IsCurrent(found->second)) {
    Finish(request_id, /*accepted=*/false);
    return SHAAR_CANCELLED;
  }
  Finish(request_id, accepted);
  return SHAAR_OK;
}

}  // namespace shaar::printing

extern "C" SHAAR_EXPORT shaar_error_code
shaar_print_reply(const char* request_id, int accepted) {
  if (!request_id || (accepted != 0 && accepted != 1)) {
    return SHAAR_INVALID_ARGUMENT;
  }
  shaar_engine* engine = shaar::lifecycle::ActiveEngine();
  if (!engine) {
    return SHAAR_NOT_READY;
  }
  return shaar::printing::Resolve(engine, request_id, accepted == 1);
}
