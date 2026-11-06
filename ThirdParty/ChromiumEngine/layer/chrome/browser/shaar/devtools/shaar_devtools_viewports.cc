// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#include "chrome/browser/shaar/devtools/shaar_devtools_viewports.h"

#include <stddef.h>
#include <algorithm>
#include <climits>
#include <cstring>
#include <initializer_list>
#include <map>
#include <memory>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

#include "base/functional/bind.h"
#include "base/json/json_reader.h"
#include "base/task/sequenced_task_runner.h"
#include "chrome/browser/shaar/engine/shaar_engine_context.h"
#include "content/public/browser/navigation_controller.h"
#include "content/public/browser/navigation_handle.h"
#include "content/public/browser/web_contents.h"
#include "content/public/browser/web_contents_observer.h"
#include "url/gurl.h"

namespace shaar::devtools {
namespace {

struct ReplyTarget {
  shaar_request_id id;
  shaar_reply_fn callback;
  void* context;
};

shaar_error_code Fail(shaar_error* error, shaar_error_code code,
                      const char* message) {
  if (error) {
    const uint32_t size = error->size;
    if (size >= offsetof(shaar_error, code) + sizeof(error->code))
      error->code = code;
    if (size >= offsetof(shaar_error, platform_code) + sizeof(error->platform_code))
      error->platform_code = 0;
    if (size >= offsetof(shaar_error, message) + sizeof(error->message))
      error->message = {message, std::strlen(message)};
  }
  return code;
}

void Deliver(ReplyTarget target, shaar_error_code code, std::string payload) {
  shaar_result result{};
  result.size = sizeof(result);
  result.request_id = target.id;
  result.error.size = sizeof(result.error);
  result.error.code = code;
  result.payload_json = {payload.data(), payload.size()};
  target.callback(target.context, &result);
}

void Reply(ReplyTarget target, std::string payload) {
  base::SequencedTaskRunner::GetCurrentDefault()->PostTask(
      FROM_HERE, base::BindOnce(&Deliver, target, SHAAR_OK, std::move(payload)));
}

bool HasKeys(const base::DictValue& args,
             std::initializer_list<std::string_view> expected) {
  if (args.size() != expected.size())
    return false;
  for (const auto item : args)
    if (std::find(expected.begin(), expected.end(), item.first) == expected.end())
      return false;
  return true;
}

bool IsPageURL(const GURL& url) {
  return url.is_valid() &&
         (url.SchemeIs("http") || url.SchemeIs("https") || url.SchemeIsFile()) &&
         !url.has_username() && !url.has_password();
}

bool ValidPreset(std::string_view name, int width, int height) {
  return (name == "iphone15Pro" && width == 393 && height == 852) ||
         (name == "pixel8" && width == 412 && height == 915) ||
         (name == "desktop" && width == 1280 && height == 800);
}

struct Viewport {
  int id;
  std::string preset;
  std::unique_ptr<content::WebContents> contents;
};

class ViewportSession final : public content::WebContentsObserver {
 public:
  ViewportSession(shaar_engine* engine, content::WebContents* source,
                  DevToolsTargetIdentity identity, int lease_id)
      : content::WebContentsObserver(source), engine_(engine), source_(source),
        identity_(std::move(identity)), lease_id_(lease_id) {}

  bool Matches(shaar_engine* engine, const DevToolsTargetIdentity& identity,
               int lease_id) const {
    return engine_ == engine && lease_id_ == lease_id &&
           identity_.profile_id == identity.profile_id &&
           identity_.session_id == identity.session_id &&
           identity_.window_id == identity.window_id &&
           identity_.tab_id == identity.tab_id;
  }

  shaar_engine* engine() const { return engine_; }
  int lease_id() const { return lease_id_; }
  size_t count() const { return viewports_.size(); }

  int Add(std::string preset, int width, int height) {
    if (viewports_.size() >= 4 || next_viewport_id_ == INT_MAX ||
        !ValidPreset(preset, width, height))
      return 0;
    const GURL url = source_->GetLastCommittedURL();
    if (!IsPageURL(url))
      return 0;
    auto child = content::WebContents::Create(
        content::WebContents::CreateParams(source_->GetBrowserContext()));
    if (!child)
      return 0;
    content::NavigationController::LoadURLParams params(url);
    child->GetController().LoadURLWithParams(params);
    const int id = next_viewport_id_++;
    viewports_.push_back({id, std::move(preset), std::move(child)});
    return id;
  }

  bool Remove(int viewport_id) {
    if (viewports_.size() <= 1)
      return false;
    const auto old_size = viewports_.size();
    std::erase_if(viewports_, [viewport_id](const Viewport& viewport) {
      return viewport.id == viewport_id;
    });
    return viewports_.size() != old_size;
  }

  void WebContentsDestroyed() override { CloseViewportLeaseForTab(source_); }
  void DidFinishNavigation(content::NavigationHandle* navigation) override {
    if (navigation->HasCommitted() && navigation->IsInPrimaryMainFrame() &&
        !navigation->IsSameDocument())
      CloseViewportLeaseForTab(source_);
  }

 private:
  shaar_engine* engine_;
  content::WebContents* source_;
  DevToolsTargetIdentity identity_;
  int lease_id_;
  int next_viewport_id_ = 1;
  std::vector<Viewport> viewports_;
};

std::map<content::WebContents*, std::unique_ptr<ViewportSession>>& Leases() {
  static auto* leases =
      new std::map<content::WebContents*, std::unique_ptr<ViewportSession>>;
  return *leases;
}

int& NextLeaseID() {
  static int next = 1;
  return next;
}

}  // namespace

void CloseViewportLeaseForTab(content::WebContents* contents) {
  Leases().erase(contents);
}

void CloseViewportLeasesForEngine(shaar_engine* engine) {
  for (auto it = Leases().begin(); it != Leases().end();) {
    if (it->second->engine() == engine)
      it = Leases().erase(it);
    else
      ++it;
  }
}

shaar_error_code HandleViewportOperation(
    ShaarEngineContext* context, shaar_engine* engine, shaar_scope scope,
    shaar_window* window, shaar_tab* tab, content::WebContents* contents,
    const DevToolsTargetIdentity& identity, shaar_operation operation,
    shaar_bytes args_json, shaar_request_id request_id, shaar_reply_fn reply,
    void* reply_context, shaar_error* error) {
  (void)scope;
  if (!context || !context->browser_tabs || !engine || !contents || !reply ||
      !request_id || !args_json.data || !args_json.size || args_json.size > 1024 ||
      context->browser_tabs->FindWebContents(engine, window, tab) != contents)
    return Fail(error, SHAAR_INVALID_ARGUMENT, "invalid viewport owner");
  auto parsed = base::JSONReader::Read(
      std::string_view(args_json.data, args_json.size), base::JSON_PARSE_RFC);
  if (!parsed || !parsed->is_dict() ||
      parsed->GetDict().FindInt("schemaVersion") != 1)
    return Fail(error, SHAAR_INVALID_ARGUMENT, "invalid viewport schema");
  const auto& args = parsed->GetDict();
  const ReplyTarget target{request_id, reply, reply_context};
  auto found = Leases().find(contents);
  ViewportSession* lease = found == Leases().end() ? nullptr : found->second.get();
  if (operation == SHAAR_OP_DEVTOOLS_VIEWPORT_OPEN) {
    if (!HasKeys(args, {"schemaVersion"}))
      return Fail(error, SHAAR_INVALID_ARGUMENT, "invalid viewport open schema");
    if (lease && !lease->Matches(engine, identity, lease->lease_id()))
      return Fail(error, SHAAR_CONFLICT, "viewport target already leased");
    if (!lease) {
      if (NextLeaseID() == INT_MAX || !IsPageURL(contents->GetLastCommittedURL()))
        return Fail(error, SHAAR_NOT_READY, "viewport target unavailable");
      const int id = NextLeaseID()++;
      auto session = std::make_unique<ViewportSession>(engine, contents, identity, id);
      lease = session.get();
      Leases().emplace(contents, std::move(session));
    }
    Reply(target, "{\"schemaVersion\":1,\"leaseID\":" +
                      std::to_string(lease->lease_id()) + "}");
    return SHAAR_OK;
  }
  const auto lease_id = args.FindInt("leaseID");
  if (!lease_id || *lease_id <= 0)
    return Fail(error, SHAAR_INVALID_ARGUMENT, "invalid viewport lease ID");
  if (!lease || !lease->Matches(engine, identity, *lease_id))
    return Fail(error, SHAAR_NOT_FOUND, "viewport lease not found");
  if (operation == SHAAR_OP_DEVTOOLS_VIEWPORT_CLOSE) {
    if (!HasKeys(args, {"schemaVersion", "leaseID"}))
      return Fail(error, SHAAR_INVALID_ARGUMENT, "invalid viewport close schema");
    Leases().erase(found);
    Reply(target, R"({"schemaVersion":1})");
    return SHAAR_OK;
  }
  if (operation == SHAAR_OP_DEVTOOLS_VIEWPORT_ADD) {
    if (!HasKeys(args, {"schemaVersion", "leaseID", "preset", "width", "height"}))
      return Fail(error, SHAAR_INVALID_ARGUMENT, "invalid viewport add schema");
    const std::string* preset = args.FindString("preset");
    const auto width = args.FindInt("width");
    const auto height = args.FindInt("height");
    if (!preset || !width || !height || !ValidPreset(*preset, *width, *height))
      return Fail(error, SHAAR_INVALID_ARGUMENT, "invalid viewport preset");
    if (lease->count() >= 4)
      return Fail(error, SHAAR_CONFLICT, "viewport limit reached");
    const int viewport_id = lease->Add(*preset, *width, *height);
    if (!viewport_id)
      return Fail(error, SHAAR_NOT_READY, "viewport could not start");
    Reply(target, "{\"schemaVersion\":1,\"viewportID\":" +
                      std::to_string(viewport_id) + "}");
    return SHAAR_OK;
  }
  if (operation == SHAAR_OP_DEVTOOLS_VIEWPORT_REMOVE) {
    if (!HasKeys(args, {"schemaVersion", "leaseID", "viewportID"}))
      return Fail(error, SHAAR_INVALID_ARGUMENT, "invalid viewport remove schema");
    const auto viewport_id = args.FindInt("viewportID");
    if (!viewport_id || *viewport_id <= 0 || !lease->Remove(*viewport_id))
      return Fail(error, SHAAR_INVALID_ARGUMENT, "viewport cannot be removed");
    Reply(target, R"({"schemaVersion":1})");
    return SHAAR_OK;
  }
  return Fail(error, SHAAR_INVALID_ARGUMENT, "unknown viewport operation");
}

}  // namespace shaar::devtools
