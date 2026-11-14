// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#include "chrome/browser/shaar/permissions/shaar_permission_prompt.h"

#include <algorithm>
#include <map>
#include <string>
#include <utility>
#include <vector>

#include "base/functional/bind.h"
#include "base/json/json_writer.h"
#include "base/memory/weak_ptr.h"
#include "base/no_destructor.h"
#include "base/task/sequenced_task_runner.h"
#include "base/time/time.h"
#include "base/values.h"
#include "chrome/browser/shaar/engine/shaar_event_bridge.h"
#include "chrome/browser/shaar/lifecycle/shaar_lifecycle.h"
#include "chrome/browser/shaar/windows_tabs/shaar_windows_tabs.h"
#include "components/content_settings/core/common/content_settings_types.h"
#include "components/permissions/permission_request.h"
#include "components/permissions/permission_uma_constants.h"
#include "components/permissions/request_type.h"
#include "components/permissions/resolvers/permission_prompt_options.h"
#include "content/public/browser/browser_context.h"
#include "content/public/browser/navigation_handle.h"
#include "content/public/browser/render_frame_host.h"
#include "content/public/browser/web_contents.h"
#include "content/public/browser/web_contents_observer.h"
#include "url/gurl.h"
#include "url/origin.h"

namespace shaar::permissions {
namespace {

struct PendingPermission {
  shaar_engine* engine = nullptr;
  content::WebContents* contents = nullptr;
  shaar_window* window = nullptr;
  shaar_tab* tab = nullptr;
  std::string profile_id;
  std::string window_id;
  std::string tab_id;
  GURL page_url;
  GURL origin;
  std::vector<std::string> shown_kinds;
  std::size_t shown_request_count = 0;
  bool one_time = false;
  bool private_profile = false;
  bool protocol_handler = false;
  std::string frame_token;
  int64_t navigation_id = 0;
  base::WeakPtr<::permissions::PermissionPrompt::Delegate> delegate;
};

using PendingMap = std::map<std::string, PendingPermission>;

PendingMap& Pending() {
  static base::NoDestructor<PendingMap> pending;
  return *pending;
}

uint64_t& NextRequestID() {
  static uint64_t next = 0;
  return next;
}

// EmitEvent can ask the app to decide before the manager stores this prompt.
// A decision posted from that callback must wait until the view exists.
int& InstallDepth() {
  static int depth = 0;
  return depth;
}

class InstallScope {
 public:
  InstallScope() { ++InstallDepth(); }
  ~InstallScope() { --InstallDepth(); }
};

}  // namespace

std::optional<std::string_view> PermissionKindForRequestType(
    ::permissions::RequestType type) {
  if (type == ::permissions::RequestType::kCameraStream)
    return "camera";
  if (type == ::permissions::RequestType::kMicStream)
    return "microphone";
  if (type == ::permissions::RequestType::kGeolocation)
    return "location";
  if (type == ::permissions::RequestType::kNotifications)
    return "notifications";
  if (type == ::permissions::RequestType::kClipboard)
    return "clipboard";
  if (type == ::permissions::RequestType::kMidiSysex)
    return "midi";
  if (type == ::permissions::RequestType::kMultipleDownloads)
    return "multipleDownloads";
  if (type == ::permissions::RequestType::kWindowManagement)
    return "windowManagement";
  if (type == ::permissions::RequestType::kLocalFonts)
    return "localFonts";
  if (type == ::permissions::RequestType::kStorageAccess)
    return "storageAccess";
  if (type == ::permissions::RequestType::kRegisterProtocolHandler)
    return "protocolHandler";
  return std::nullopt;
}

namespace {

std::optional<std::string_view> KindFor(
    const ::permissions::PermissionRequest& request) {
  const std::optional<::permissions::RequestType> type =
      request.request_type_if_present();
  return type ? PermissionKindForRequestType(*type) : std::nullopt;
}

bool OneTimeGrant(const std::vector<std::string>& kinds) {
  if (kinds.empty())
    return false;
  for (const std::string_view kind : kinds) {
    if (kind != "camera" && kind != "microphone")
      return false;
  }
  return true;
}

std::vector<std::string> KindsFor(
    ::permissions::PermissionPrompt::Delegate* delegate);

::PromptOptions OptionsFor(
    ::permissions::PermissionPrompt::Delegate* delegate) {
  if (!delegate)
    return std::monostate{};
  const auto& requests = delegate->Requests();
  if (requests.empty() || !requests.front())
    return std::monostate{};
  if (requests.front()->GetContentSettingsType() !=
      ContentSettingsType::GEOLOCATION_WITH_OPTIONS)
    return std::monostate{};
  return ::GeolocationPromptOptions{
      delegate->GetInitialGeolocationAccuracySelection()};
}

std::optional<content::GlobalRenderFrameHostId> SharedFrameID(
    ::permissions::PermissionPrompt::Delegate* delegate) {
  if (!delegate)
    return std::nullopt;
  std::optional<content::GlobalRenderFrameHostId> shared;
  for (const auto& request : delegate->Requests()) {
    if (!request)
      return std::nullopt;
    const content::GlobalRenderFrameHostId& id =
        request->get_requesting_frame_id();
    if (!shared)
      shared = id;
    else if (id != *shared)
      return std::nullopt;
  }
  return shared;
}

FrameSnapshot SnapshotFor(content::WebContents* contents,
                          content::RenderFrameHost* frame) {
  FrameSnapshot live;
  if (!contents || !frame)
    return live;
  live.token = frame->GetFrameToken().ToString();
  live.active = frame->IsActive();
  live.same_contents =
      content::WebContents::FromRenderFrameHost(frame) == contents;
  live.navigation_id = frame->GetNavigationId();
  return live;
}

bool FrameMatches(const PendingPermission& pending) {
  const std::optional<content::GlobalRenderFrameHostId> id =
      SharedFrameID(pending.delegate.get());
  content::RenderFrameHost* frame = nullptr;
  if (id)
    frame = content::RenderFrameHost::FromID(*id);
  const FrameSnapshot stored{pending.frame_token, true, true,
                             pending.navigation_id};
  return FrameStillBound(stored, SnapshotFor(pending.contents, frame));
}

bool IsCurrent(const PendingPermission& pending) {
  if (!lifecycle::EngineIsReady(pending.engine) || !pending.contents ||
      !pending.delegate)
    return false;
  const auto identity = windows_tabs::Registry().FindSelectedRegularTab(
      pending.engine, pending.contents);
  return identity && identity->window == pending.window &&
         identity->tab == pending.tab &&
         identity->profile_id == pending.profile_id &&
         identity->window_id == pending.window_id &&
         identity->tab_id == pending.tab_id &&
         pending.contents->GetLastCommittedURL() == pending.page_url &&
         pending.delegate->GetRequestingOrigin() == pending.origin &&
         FrameMatches(pending);
}

void EmitDismissFor(const PendingPermission& pending,
                    const std::string& request_id) {
  if (!lifecycle::EngineIsReady(pending.engine))
    return;
  base::DictValue payload;
  payload.Set("schemaVersion", 1);
  payload.Set("kind", "websitePermissionDismissed");
  payload.Set("id", request_id);
  std::string json;
  if (!base::JSONWriter::Write(payload, &json))
    return;
  shaar::EmitEvent(pending.engine, SHAAR_EVENT_PERMISSION,
                   {pending.profile_id.data(), pending.profile_id.size()}, {},
                   {pending.window_id.data(), pending.window_id.size()},
                   {pending.tab_id.data(), pending.tab_id.size()},
                   {json.data(), json.size()});
}

void Decide(PendingPermission pending, bool allowed) {
  auto delegate = pending.delegate;
  if (!delegate)
    return;
  if (allowed) {
    const auto& requests = delegate->Requests();
    const bool request_count_matches =
        ShownRequestCountMatches(pending.shown_request_count, requests.size());
    const bool kinds_match =
        ShownPermissionsMatch(pending.shown_kinds, KindsFor(delegate.get()));
    if (!request_count_matches || !kinds_match)
      allowed = false;
  }
  const ::PromptOptions options = OptionsFor(delegate.get());
  DecideGrant(delegate.get(), allowed, IsCurrent(pending),
              pending.private_profile, pending.one_time,
              pending.protocol_handler, options);
}

void DenyPending(std::string request_id) {
  auto found = Pending().find(request_id);
  if (found == Pending().end())
    return;
  PendingPermission pending = std::move(found->second);
  Pending().erase(found);
  Decide(std::move(pending), false);
}

void Expire(std::string request_id) {
  auto found = Pending().find(request_id);
  if (found == Pending().end())
    return;
  PendingPermission pending = std::move(found->second);
  Pending().erase(found);
  EmitDismissFor(pending, request_id);
  Decide(std::move(pending), false);
}

// Watches the asking frame. A same-URL reload or a detached frame reuses the
// dismiss path so Allow cannot reach a frame that is already gone.
class FrameWatcher : public content::WebContentsObserver {
 public:
  FrameWatcher(content::WebContents* contents,
               std::string request_id,
               FrameSnapshot stored)
      : content::WebContentsObserver(contents),
        request_id_(std::move(request_id)),
        stored_(std::move(stored)) {}

  // The prompt destructor dismisses a request that is still pending.
  ~FrameWatcher() override = default;

  void DidFinishNavigation(
      content::NavigationHandle* navigation_handle) override {
    if (!navigation_handle || !navigation_handle->HasCommitted())
      return;
    const FrameSnapshot live =
        SnapshotFor(web_contents(), navigation_handle->GetRenderFrameHost());
    const bool left = FrameLeftTheRequest(
        stored_, live, navigation_handle->IsSameDocument(), false);
    if (!left)
      return;
    PostExpire();
  }

  void RenderFrameDeleted(
      content::RenderFrameHost* render_frame_host) override {
    const FrameSnapshot live = SnapshotFor(web_contents(), render_frame_host);
    if (!FrameLeftTheRequest(stored_, live, false, true))
      return;
    PostExpire();
  }

 private:
  void PostExpire() {
    if (posted_)
      return;
    posted_ = true;
    base::SequencedTaskRunner::GetCurrentDefault()->PostTask(
        FROM_HERE, base::BindOnce(&Expire, request_id_));
  }

  std::string request_id_;
  FrameSnapshot stored_;
  bool posted_ = false;
};

void DenyDelegate(
    base::WeakPtr<::permissions::PermissionPrompt::Delegate> delegate) {
  if (!delegate)
    return;
  delegate->Deny(OptionsFor(delegate.get()));
}

class ShaarPermissionPrompt : public ::permissions::PermissionPrompt {
 public:
  ShaarPermissionPrompt(content::WebContents* contents,
                        ::permissions::PermissionPrompt::Delegate* delegate,
                        std::vector<std::string> kinds)
      : one_time_(OneTimeGrant(kinds)) {
    InstallScope installing;
    if (!Bind(contents, delegate, std::move(kinds)) && delegate) {
      base::SequencedTaskRunner::GetCurrentDefault()->PostTask(
          FROM_HERE, base::BindOnce(&DenyDelegate, delegate->GetWeakPtr()));
    }
  }

  ~ShaarPermissionPrompt() override {
    frame_watcher_.reset();
    if (id_.empty())
      return;
    auto found = Pending().find(id_);
    if (found == Pending().end())
      return;
    PendingPermission pending = std::move(found->second);
    Pending().erase(found);
    EmitDismissFor(pending, id_);
  }

  bool UpdateAnchor() override { return true; }

  TabSwitchingBehavior GetTabSwitchingBehavior() override {
    return TabSwitchingBehavior::kKeepPromptAlive;
  }

  ::permissions::PermissionPromptDisposition GetPromptDisposition()
      const override {
    return ::permissions::PermissionPromptDisposition::CUSTOM_MODAL_DIALOG;
  }

  bool IsAskPrompt() const override { return true; }

  std::optional<gfx::Rect> GetViewBoundsInScreen() const override {
    return std::nullopt;
  }

  std::vector<::permissions::ElementAnchoredBubbleVariant> GetPromptVariants()
      const override {
    return {};
  }

  std::optional<::permissions::feature_params::PermissionElementPromptPosition>
  GetPromptPosition() const override {
    return std::nullopt;
  }

 private:
  bool Bind(content::WebContents* contents,
            ::permissions::PermissionPrompt::Delegate* delegate,
            std::vector<std::string> kinds) {
    shaar_engine* engine = lifecycle::ActiveEngine();
    const auto identity =
        windows_tabs::Registry().FindSelectedRegularTab(engine, contents);
    const GURL page_url = contents ? contents->GetLastCommittedURL() : GURL();
    const GURL origin = delegate ? delegate->GetRequestingOrigin() : GURL();
    content::BrowserContext* context =
        contents ? contents->GetBrowserContext() : nullptr;
    const std::optional<content::GlobalRenderFrameHostId> frame_id =
        SharedFrameID(delegate);
    content::RenderFrameHost* frame =
        frame_id ? content::RenderFrameHost::FromID(*frame_id) : nullptr;
    const FrameSnapshot frame_snapshot = SnapshotFor(contents, frame);
    if (!lifecycle::EngineIsReady(engine) || !contents || !delegate ||
        !context || !identity || identity->profile_id.empty() ||
        identity->window_id.empty() || identity->tab_id.empty() ||
        !page_url.SchemeIsHTTPOrHTTPS() || !origin.SchemeIsHTTPOrHTTPS() ||
        !FrameStillBound(frame_snapshot, frame_snapshot) ||
        Pending().size() >= 32)
      return false;

    const std::string id = "permission-" + std::to_string(++NextRequestID());
    if (id.size() > 128)
      return false;
    bool protocol_handler = false;
    for (const std::string& kind : kinds) {
      if (kind == "protocolHandler")
        protocol_handler = true;
    }
    const bool private_profile = context->IsOffTheRecord();
    const GURL reported_origin = url::Origin::Create(origin).GetURL();
    base::DictValue payload;
    payload.Set("schemaVersion", 1);
    payload.Set("kind", "websitePermissionRequested");
    payload.Set("id", id);
    payload.Set("pageURL", page_url.spec());
    payload.Set("origin", reported_origin.spec());
    payload.Set("frameID", frame_snapshot.token);
    base::ListValue permissions;
    for (const std::string& kind : kinds)
      permissions.Append(kind);
    payload.Set("permissions", std::move(permissions));
    std::string json;
    if (!base::JSONWriter::Write(payload, &json))
      return false;

    id_ = id;
    PendingPermission pending;
    pending.engine = engine;
    pending.contents = contents;
    pending.window = identity->window;
    pending.tab = identity->tab;
    pending.profile_id = identity->profile_id;
    pending.window_id = identity->window_id;
    pending.tab_id = identity->tab_id;
    pending.page_url = page_url;
    pending.origin = origin;
    pending.shown_kinds = std::move(kinds);
    pending.shown_request_count = delegate->Requests().size();
    pending.one_time = one_time_;
    pending.private_profile = private_profile;
    pending.protocol_handler = protocol_handler;
    pending.frame_token = frame_snapshot.token;
    pending.navigation_id = frame_snapshot.navigation_id;
    pending.delegate = delegate->GetWeakPtr();
    Pending().emplace(id, std::move(pending));
    frame_watcher_ =
        std::make_unique<FrameWatcher>(contents, id, frame_snapshot);
    const shaar_error_code emitted = shaar::EmitEvent(
        engine, SHAAR_EVENT_PERMISSION,
        {identity->profile_id.data(), identity->profile_id.size()}, {},
        {identity->window_id.data(), identity->window_id.size()},
        {identity->tab_id.data(), identity->tab_id.size()},
        {json.data(), json.size()});
    if (emitted != SHAAR_OK) {
      base::SequencedTaskRunner::GetCurrentDefault()->PostTask(
          FROM_HERE, base::BindOnce(&DenyPending, id));
      return true;
    }
    delegate->SetPromptShown();
    base::SequencedTaskRunner::GetCurrentDefault()->PostDelayedTask(
        FROM_HERE, base::BindOnce(&Expire, id), base::Minutes(2));
    return true;
  }

  std::string id_;
  bool one_time_ = false;
  std::unique_ptr<FrameWatcher> frame_watcher_;
};

std::vector<std::string> KindsFor(
    ::permissions::PermissionPrompt::Delegate* delegate) {
  std::vector<std::string> kinds;
  if (!delegate)
    return kinds;
  for (const auto& request : delegate->Requests()) {
    if (!request)
      return {};
    const std::optional<std::string_view> kind = KindFor(*request);
    if (!kind)
      return {};
    if (std::find(kinds.begin(), kinds.end(), *kind) == kinds.end())
      kinds.emplace_back(*kind);
  }
  std::sort(kinds.begin(), kinds.end());
  return kinds;
}

}  // namespace

GrantPersistence DecideGrant(
    ::permissions::PermissionPrompt::Delegate* delegate,
    bool allowed,
    bool current,
    bool private_profile,
    bool one_time,
    bool protocol_handler,
    const ::PromptOptions& options) {
  if (!delegate)
    return GrantPersistence::kDeny;
  const GrantPersistence persistence =
      PersistenceFor(allowed, current, private_profile, one_time,
                     protocol_handler);
  switch (persistence) {
    case GrantPersistence::kDeny:
      delegate->Deny(options);
      break;
    case GrantPersistence::kThisVisit:
      delegate->AcceptThisTime(options);
      break;
    case GrantPersistence::kPrivateProtocol:
    case GrantPersistence::kProfile:
      delegate->Accept(options);
      break;
  }
  return persistence;
}

std::unique_ptr<::permissions::PermissionPrompt> CreateEmbedderPrompt(
    content::WebContents* contents,
    ::permissions::PermissionPrompt::Delegate* delegate) {
  if (!contents || !delegate)
    return nullptr;
  const std::vector<std::string> kinds = KindsFor(delegate);
  if (kinds.empty())
    return nullptr;
  return std::make_unique<ShaarPermissionPrompt>(contents, delegate, kinds);
}

std::optional<bool> ResolveWebsitePermission(shaar_engine* engine,
                                             content::WebContents* contents,
                                             std::string_view request_id,
                                             bool accepted) {
  auto found = Pending().find(std::string(request_id));
  if (found == Pending().end())
    return std::nullopt;
  PendingPermission pending = std::move(found->second);
  Pending().erase(found);
  const bool allowed = accepted && pending.engine == engine &&
                       pending.contents == contents && IsCurrent(pending);
  if (InstallDepth() > 0) {
    base::SequencedTaskRunner::GetCurrentDefault()->PostTask(
        FROM_HERE, base::BindOnce(&Decide, std::move(pending), allowed));
    return allowed;
  }
  Decide(std::move(pending), allowed);
  return allowed;
}

}  // namespace shaar::permissions
