// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#include "chrome/browser/shaar/private_sessions/shaar_private_trackers.h"

#include <algorithm>
#include <limits>
#include <utility>

#include "base/functional/bind.h"
#include "base/memory/self_deleting.h"
#include "base/strings/string_util.h"
#include "chrome/browser/profiles/profile.h"
#include "content/public/browser/browser_context.h"
#include "mojo/public/cpp/base/big_buffer.h"
#include "mojo/public/cpp/bindings/receiver.h"
#include "mojo/public/cpp/bindings/remote.h"
#include "net/base/isolation_info.h"
#include "net/base/net_errors.h"
#include "net/base/registry_controlled_domains/registry_controlled_domain.h"
#include "net/url_request/redirect_info.h"
#include "services/network/public/cpp/resource_request.h"
#include "services/network/public/cpp/self_deleting_url_loader_factory.h"
#include "services/network/public/cpp/url_loader_completion_status.h"
#include "services/network/public/cpp/url_loader_factory_builder.h"
#include "services/network/public/mojom/early_hints.mojom.h"
#include "services/network/public/mojom/url_loader.mojom.h"
#include "services/network/public/mojom/url_response_head.mojom.h"

namespace shaar {
namespace {

bool ValidDomain(const std::string &domain) {
  if (domain.empty() || domain.size() > 253 ||
      domain.find('.') == std::string::npos)
    return false;
  const GURL url("https://" + domain + "/");
  if (!url.is_valid() || url.HostIsIPAddress() || url.host() != domain)
    return false;
  size_t start = 0;
  while (start < domain.size()) {
    const size_t dot = domain.find('.', start);
    const std::string_view label(
        domain.data() + start,
        (dot == std::string::npos ? domain.size() : dot) - start);
    if (label.empty() || label.size() > 63 || label.front() == '-' ||
        label.back() == '-' ||
        !std::all_of(label.begin(), label.end(), [](char c) {
          return base::IsAsciiAlphaNumeric(c) || c == '-';
        }))
      return false;
    if (dot == std::string::npos)
      return true;
    start = dot + 1;
  }
  return false;
}

bool ValidOrigin(const std::string &origin) {
  const GURL url(origin);
  if (!url.is_valid() || !url.SchemeIsHTTPOrHTTPS() || url.has_username() ||
      url.has_password() || url.has_query() || url.has_ref())
    return false;
  std::string canonical = url::Origin::Create(url).GetURL().spec();
  if (!canonical.empty() && canonical.back() == '/')
    canonical.pop_back();
  return origin == canonical || origin == canonical + "/";
}

bool Matches(const std::set<std::string, std::less<>> &domains,
             std::string_view host) {
  while (!host.empty() && host.back() == '.')
    host.remove_suffix(1);
  while (!host.empty()) {
    if (domains.contains(host))
      return true;
    const size_t dot = host.find('.');
    if (dot == std::string_view::npos)
      break;
    host.remove_prefix(dot + 1);
  }
  return false;
}

class ProtectedRequest final : public network::mojom::URLLoader,
                               public network::mojom::URLLoaderClient,
                               public base::SelfDeleting {
public:
  ProtectedRequest(mojo::PendingReceiver<network::mojom::URLLoader> receiver,
                   mojo::PendingRemote<network::mojom::URLLoaderClient> client,
                   base::WeakPtr<Profile> profile,
                   std::optional<url::Origin> top_origin, bool main_frame,
                   base::SelfDeletingPassKey key)
      : base::SelfDeleting(key), receiver_(this, std::move(receiver)),
        client_(std::move(client)), profile_(std::move(profile)),
        top_origin_(std::move(top_origin)), main_frame_(main_frame),
        upstream_client_(this) {
    receiver_.set_disconnect_handler(
        base::BindOnce(&ProtectedRequest::Disconnect, base::Unretained(this)));
    client_.set_disconnect_handler(
        base::BindOnce(&ProtectedRequest::Disconnect, base::Unretained(this)));
  }

  void Start(network::mojom::URLLoaderFactory *factory, int32_t request_id,
             uint32_t options, const network::ResourceRequest &request,
             const net::MutableNetworkTrafficAnnotationTag &annotation) {
    if (main_frame_)
      top_origin_ = url::Origin::Create(request.url);
    if (Blocked(request.url)) {
      Finish(network::URLLoaderCompletionStatus(net::ERR_BLOCKED_BY_CLIENT));
      return;
    }
    // Bind the remote before installing its disconnect handler. A live tab can
    // issue a request while its private window is closing, and Mojo requires a
    // bound remote here even if the upstream factory is about to disconnect.
    auto upstream_receiver = upstream_loader_.BindNewPipeAndPassReceiver();
    auto upstream_client = upstream_client_.BindNewPipeAndPassRemote();
    // The loader command pipe may close while response/body/completion messages
    // are still queued on the independent client pipe. Treating that closure as
    // ERR_ABORTED truncates successful private navigations. A disconnect on the
    // response receiver is ordered after its messages, including OnComplete.
    upstream_client_.set_disconnect_handler(base::BindOnce(
        &ProtectedRequest::UpstreamDisconnected, base::Unretained(this)));
    factory->CreateLoaderAndStart(
        std::move(upstream_receiver), request_id, options,
        request, std::move(upstream_client), annotation);
  }

  void FollowRedirect(network::HttpRequestHeadersUpdateParams headers,
                      const std::optional<GURL> &new_url) override {
    if (main_frame_ && new_url)
      top_origin_ = url::Origin::Create(*new_url);
    if (new_url && Blocked(*new_url)) {
      Finish(network::URLLoaderCompletionStatus(net::ERR_BLOCKED_BY_CLIENT));
      return;
    }
    upstream_loader_->FollowRedirect(std::move(headers), new_url);
  }
  void SetPriority(net::RequestPriority priority,
                   int32_t intra_priority_value) override {
    upstream_loader_->SetPriority(priority, intra_priority_value);
  }
  void OnReceiveEarlyHints(network::mojom::EarlyHintsPtr hints) override {
    client_->OnReceiveEarlyHints(std::move(hints));
  }
  void
  OnReceiveResponse(network::mojom::URLResponseHeadPtr head,
                    mojo::ScopedDataPipeConsumerHandle body,
                    std::optional<mojo_base::BigBuffer> metadata) override {
    client_->OnReceiveResponse(std::move(head), std::move(body),
                               std::move(metadata));
  }
  void OnReceiveRedirect(const net::RedirectInfo &redirect,
                         network::mojom::URLResponseHeadPtr head) override {
    if (main_frame_)
      top_origin_ = url::Origin::Create(redirect.new_url);
    if (Blocked(redirect.new_url)) {
      Finish(network::URLLoaderCompletionStatus(net::ERR_BLOCKED_BY_CLIENT));
      return;
    }
    client_->OnReceiveRedirect(redirect, std::move(head));
  }
  void OnUploadProgress(int64_t current, int64_t total,
                        OnUploadProgressCallback callback) override {
    client_->OnUploadProgress(current, total, std::move(callback));
  }
  void OnTransferSizeUpdated(int32_t diff) override {
    client_->OnTransferSizeUpdated(diff);
  }
  void OnComplete(const network::URLLoaderCompletionStatus &status) override {
    Finish(status);
  }

private:
  ~ProtectedRequest() override = default;
  bool Blocked(const GURL &url) {
    return !profile_ ||
           TrackerProtection().ShouldBlock(profile_.get(), url, top_origin_);
  }
  void Disconnect() { delete this; }
  void UpstreamDisconnected() {
    Finish(network::URLLoaderCompletionStatus(net::ERR_ABORTED));
  }
  void Finish(const network::URLLoaderCompletionStatus &status) {
    client_->OnComplete(status);
    delete this;
  }

  mojo::Receiver<network::mojom::URLLoader> receiver_;
  mojo::Remote<network::mojom::URLLoaderClient> client_;
  base::WeakPtr<Profile> profile_;
  std::optional<url::Origin> top_origin_;
  bool main_frame_;
  mojo::Receiver<network::mojom::URLLoaderClient> upstream_client_;
  mojo::Remote<network::mojom::URLLoader> upstream_loader_;
};

class ProtectedFactory final : public network::SelfDeletingURLLoaderFactory {
public:
  ProtectedFactory(
      mojo::PendingReceiver<network::mojom::URLLoaderFactory> receiver,
      mojo::PendingRemote<network::mojom::URLLoaderFactory> upstream,
      base::WeakPtr<Profile> profile, std::optional<url::Origin> top_origin,
      bool main_frame, base::SelfDeletingPassKey key)
      : network::SelfDeletingURLLoaderFactory(std::move(receiver), key),
        upstream_(std::move(upstream)), profile_(std::move(profile)),
        top_origin_(std::move(top_origin)), main_frame_(main_frame) {
    upstream_.set_disconnect_handler(
        base::BindOnce(&ProtectedFactory::Disconnect, base::Unretained(this)));
  }
  void CreateLoaderAndStart(
      mojo::PendingReceiver<network::mojom::URLLoader> receiver,
      int32_t request_id, uint32_t options,
      const network::ResourceRequest &request,
      mojo::PendingRemote<network::mojom::URLLoaderClient> client,
      const net::MutableNetworkTrafficAnnotationTag &annotation) override {
    auto *protected_request = base::MakeSelfDeleting<ProtectedRequest>(
        std::move(receiver), std::move(client), profile_, top_origin_,
        main_frame_);
    protected_request->Start(upstream_.get(), request_id, options, request,
                             annotation);
  }

private:
  ~ProtectedFactory() override = default;
  void Disconnect() { DisconnectReceiversAndDestroy(); }
  mojo::Remote<network::mojom::URLLoaderFactory> upstream_;
  base::WeakPtr<Profile> profile_;
  std::optional<url::Origin> top_origin_;
  bool main_frame_;
};

} // namespace

bool ValidPrivateTrackerOrigin(const std::string &origin) {
  return ValidOrigin(origin);
}

shaar_error_code
PrivateTrackerProtection::SetRules(Profile *parent, const std::string &revision,
                                   const std::vector<std::string> &domains) {
  if (!parent || parent->IsOffTheRecord())
    return SHAAR_WRONG_PROFILE;
  if (revision.empty() || revision.size() > 200 || domains.empty() ||
      domains.size() > 100000 ||
      !std::all_of(revision.begin(), revision.end(),
                   [](char c) {
                     return base::IsAsciiAlphaNumeric(c) || c == '-' ||
                            c == '_';
                   }) ||
      !std::all_of(domains.begin(), domains.end(), ValidDomain))
    return SHAAR_INVALID_ARGUMENT;
  std::set<std::string, std::less<>> parsed(domains.begin(), domains.end());
  if (parsed.size() != domains.size())
    return SHAAR_INVALID_ARGUMENT;
  auto found = rules_.find(parent);
  if (found != rules_.end()) {
    return found->second.revision == revision && found->second.domains == parsed
               ? SHAAR_OK
               : SHAAR_CONFLICT;
  }
  rules_.emplace(parent, Rules{revision, std::move(parsed)});
  return SHAAR_OK;
}

shaar_error_code
PrivateTrackerProtection::SetAllowance(Profile *otr, const std::string &origin,
                                       bool allow) {
  if (!otr || !otr->IsOffTheRecord())
    return SHAAR_WRONG_PROFILE;
  if (!ValidOrigin(origin))
    return SHAAR_INVALID_ARGUMENT;
  std::string key = url::Origin::Create(GURL(origin)).Serialize();
  auto &state = private_states_[otr];
  if (allow)
    state.allowed_origins.insert(std::move(key));
  else
    state.allowed_origins.erase(key);
  return SHAAR_OK;
}

bool PrivateTrackerProtection::Allowance(Profile *otr,
                                         const std::string &origin) const {
  if (!otr || !otr->IsOffTheRecord() || !ValidOrigin(origin))
    return false;
  auto found = private_states_.find(otr);
  return found != private_states_.end() &&
         found->second.allowed_origins.contains(
             url::Origin::Create(GURL(origin)).Serialize());
}

PrivateTrackerProtection::StatusInfo
PrivateTrackerProtection::Status(Profile *otr) const {
  StatusInfo status;
  if (!otr || !otr->IsOffTheRecord())
    return status;
  auto rules = rules_.find(otr->GetOriginalProfile());
  if (rules == rules_.end())
    return status;
  status.revision = rules->second.revision;
  status.domain_count = static_cast<int>(rules->second.domains.size());
  status.enabled = true;
  auto state = private_states_.find(otr);
  if (state != private_states_.end())
    status.blocked_requests = state->second.blocked_requests;
  return status;
}

bool PrivateTrackerProtection::ShouldBlock(
    Profile *profile, const GURL &url,
    const std::optional<url::Origin> &top_origin) {
  if (!profile || !profile->IsOffTheRecord())
    return false;
  if (!url.SchemeIsHTTPOrHTTPS() && !url.SchemeIsWSOrWSS())
    return false;
  auto rules = rules_.find(profile->GetOriginalProfile());
  if (rules == rules_.end())
    return true;
  if (!Matches(rules->second.domains, url.host()))
    return false;
  if (top_origin && !top_origin->opaque()) {
    auto state = private_states_.find(profile);
    if ((state != private_states_.end() &&
         state->second.allowed_origins.contains(top_origin->Serialize())) ||
        net::registry_controlled_domains::SameDomainOrHost(
            url, *top_origin,
            net::registry_controlled_domains::INCLUDE_PRIVATE_REGISTRIES))
      return false;
  }
  auto &count = private_states_[profile].blocked_requests;
  if (count < std::numeric_limits<int>::max())
    ++count;
  return true;
}

void PrivateTrackerProtection::RemoveProfile(Profile *profile) {
  rules_.erase(profile);
  private_states_.erase(profile);
}

PrivateTrackerProtection &TrackerProtection() {
  static PrivateTrackerProtection protection;
  return protection;
}

void InstallPrivateTrackerFactory(content::BrowserContext *context,
                                  const net::IsolationInfo &isolation,
                                  network::URLLoaderFactoryBuilder &builder) {
  if (!context || !context->IsOffTheRecord())
    return;
  auto *profile = Profile::FromBrowserContext(context);
  auto [receiver, upstream] = builder.Append();
  base::MakeSelfDeleting<ProtectedFactory>(
      std::move(receiver), std::move(upstream), profile->GetWeakPtr(),
      isolation.top_frame_origin(),
      isolation.request_type() == net::IsolationInfo::RequestType::kMainFrame);
}

bool ShouldBlockPrivateTracker(content::BrowserContext *context,
                               const GURL &url,
                               const std::optional<url::Origin> &top_origin) {
  return context && context->IsOffTheRecord() &&
         TrackerProtection().ShouldBlock(Profile::FromBrowserContext(context),
                                         url, top_origin);
}

} // namespace shaar
