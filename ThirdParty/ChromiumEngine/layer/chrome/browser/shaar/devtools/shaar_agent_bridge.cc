// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#include "chrome/browser/shaar/devtools/shaar_agent_bridge.h"

#include <algorithm>
#include <initializer_list>
#include <map>
#include <optional>
#include <set>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

#include "base/base64url.h"
#include "base/command_line.h"
#include "base/containers/span.h"
#include "base/functional/bind.h"
#include "base/json/json_reader.h"
#include "base/json/json_writer.h"
#include "base/location.h"
#include "base/values.h"
#include "base/memory/weak_ptr.h"
#include "base/rand_util.h"
#include "base/files/file_path.h"
#include "base/time/time.h"
#include "base/timer/timer.h"
#include "chrome/browser/browser_process.h"
#include "chrome/browser/shaar/devtools/shaar_devtools.h"
#include "chrome/browser/shaar/engine/shaar_event_bridge.h"
#include "chrome/common/pref_names.h"
#include "components/prefs/pref_change_registrar.h"
#include "components/prefs/pref_service.h"
#include "content/public/browser/devtools_agent_host.h"
#include "content/public/browser/devtools_agent_host_client.h"
#include "content/public/browser/devtools_socket_factory.h"
#include "content/public/browser/navigation_handle.h"
#include "content/public/browser/render_frame_host.h"
#include "content/public/browser/shaar_agent_bridge.h"
#include "content/public/browser/web_contents.h"
#include "content/public/browser/web_contents_observer.h"
#include "content/public/common/content_switches.h"
#include "net/base/net_errors.h"
#include "net/log/net_log_source.h"
#include "net/socket/tcp_server_socket.h"
#include "net/socket/server_socket.h"
#include "url/origin.h"
#include "url/gurl.h"

namespace shaar::agent_bridge {
namespace {

constexpr size_t kMaximumCommandBytes = 65536;
constexpr size_t kMaximumEventBytes = 1048576;
constexpr base::TimeDelta kGrantLifetime = base::Minutes(10);
constexpr char kBearerPrefix[] = "Bearer ";

struct PendingReply {
  shaar_request_id id = 0;
  shaar_reply_fn callback = nullptr;
  void* context = nullptr;
};

void Reply(PendingReply request, shaar_error_code code,
           const std::string& payload) {
  if (!request.callback)
    return;
  shaar_result result{};
  result.size = sizeof(result);
  result.request_id = request.id;
  result.error.size = sizeof(result.error);
  result.error.code = code;
  result.payload_json = {payload.data(), payload.size()};
  request.callback(request.context, &result);
}

shaar_error_code Fail(shaar_error_code code, const char* message,
                      shaar_error* error) {
  if (error) {
    error->code = code;
    error->message = {message, std::char_traits<char>::length(message)};
  }
  return code;
}

bool ConstantTimeEqual(std::string_view left, std::string_view right) {
  if (left.size() != right.size())
    return false;
  unsigned difference = 0;
  for (size_t index = 0; index < left.size(); ++index)
    difference |= static_cast<unsigned char>(left[index] ^ right[index]);
  return difference == 0;
}

std::string Json(const base::DictValue& value) {
  return base::WriteJson(value).value_or("{}");
}

std::string ProtocolError(int id, const char* message) {
  base::DictValue error;
  error.Set("code", -32601);
  error.Set("message", message);
  base::DictValue reply;
  reply.Set("id", id);
  reply.Set("error", std::move(error));
  return Json(reply);
}

bool HasOnlyKeys(const base::DictValue& dict,
                 std::initializer_list<std::string_view> keys) {
  for (const auto& entry : dict) {
    if (std::find(keys.begin(), keys.end(), entry.first) == keys.end())
      return false;
  }
  return true;
}

bool IsWebURL(const GURL& url) {
  return url.is_valid() && (url.SchemeIs("http") || url.SchemeIs("https")) &&
         !url.has_username() && !url.has_password();
}

class LoopbackSocketFactory final : public content::DevToolsSocketFactory {
 public:
  std::unique_ptr<net::ServerSocket> CreateForHttpServer() override {
    auto socket =
        std::make_unique<net::TCPServerSocket>(nullptr, net::NetLogSource());
    if (socket->ListenWithAddressAndPort("127.0.0.1", 0, 10) != net::OK)
      return nullptr;
    return socket;
  }

  std::unique_ptr<net::ServerSocket> CreateForTethering(
      std::string*) override {
    return nullptr;
  }
};

class ControlServer;
class AgentClient;

std::map<content::DevToolsAgentHostClient*, AgentClient*>& Clients() {
  static auto* clients =
      new std::map<content::DevToolsAgentHostClient*, AgentClient*>;
  return *clients;
}

class ControlServer final : public content::WebContentsObserver {
 public:
  static ControlServer& Get() {
    static auto* instance = new ControlServer;
    return *instance;
  }

  ControlServer() {
    g_shaar_agent_bridge_factory = &IsOurFactory;
    g_shaar_agent_bridge_accepts = &Accepts;
    g_shaar_agent_bridge_server = &ServerChanged;
    g_shaar_agent_bridge_client = &CreateClient;
    g_shaar_agent_bridge_may_attach = &MayAttach;
    g_shaar_agent_bridge_may_input = &MayInput;
  }

  bool Owns(shaar_engine* engine, shaar_scope scope, shaar_window* window,
            shaar_tab* tab, content::WebContents* contents) const {
    return enabled_ && engine_ == engine && profile_ == scope.profile &&
           window_ == window && tab_ == tab && contents_.get() == contents;
  }

  shaar_error_code Handle(shaar_engine* engine, shaar_scope scope,
                          shaar_window* window, shaar_tab* tab,
                          content::WebContents* contents,
                          const DevToolsTargetIdentity& identity,
                          shaar_operation operation, PendingReply request,
                          shaar_error* error) {
    if (scope.private_session)
      return Fail(SHAAR_PRIVATE_DISALLOWED,
                  "agent bridge is unavailable in private windows", error);
    if (!engine || !scope.profile || !window || !tab || !contents ||
        !request.id || !request.callback)
      return Fail(SHAAR_INVALID_ARGUMENT, "missing agent bridge owner", error);
    if (operation == SHAAR_OP_DEVTOOLS_CONTROL_ENABLE) {
      if (!IsWebURL(contents->GetLastCommittedURL()))
        return Fail(SHAAR_POLICY_BLOCKED, "agent bridge needs a web page", error);
      if (base::CommandLine::ForCurrentProcess()->HasSwitch(
              switches::kRemoteDebuggingPort))
        return Fail(SHAAR_CONFLICT,
                    "global remote debugging is already configured", error);
      if (!engine_ &&
          !content::DevToolsAgentHost::GetRemoteDebuggingServerAddress().empty())
        return Fail(SHAAR_CONFLICT,
                    "another remote debugging server is active", error);
      if (g_browser_process && g_browser_process->local_state() &&
          g_browser_process->local_state()->IsManagedPreference(
              prefs::kDevToolsRemoteDebuggingAllowed) &&
          !g_browser_process->local_state()->GetBoolean(
              prefs::kDevToolsRemoteDebuggingAllowed)) {
        return Fail(SHAAR_POLICY_BLOCKED, "remote debugging is managed off", error);
      }
      if (!watching_policy_ && g_browser_process &&
          g_browser_process->local_state()) {
        policy_.Init(g_browser_process->local_state());
        policy_.Add(prefs::kDevToolsRemoteDebuggingAllowed,
                    base::BindRepeating(&ControlServer::PolicyChanged,
                                        base::Unretained(this)));
        watching_policy_ = true;
      }
      Revoke();
      engine_ = engine;
      profile_ = scope.profile;
      window_ = window;
      tab_ = tab;
      contents_ = contents->GetWeakPtr();
      profile_id_ = identity.profile_id;
      window_id_ = identity.window_id;
      tab_id_ = identity.tab_id;
      Observe(contents);
      origin_ = url::Origin::Create(contents->GetLastCommittedURL());
      auto host = devtools::ProtocolAgentHostFor(contents);
      if (!host) {
        Revoke();
        return Fail(SHAAR_NOT_READY, "page target unavailable", error);
      }
      target_id_ = host->GetId();
      if (auto* frame = contents->GetPrimaryMainFrame())
        frame_id_ = frame->GetDevToolsFrameToken().ToString();
      if (frame_id_.empty()) {
        Revoke();
        return Fail(SHAAR_NOT_READY, "page frame unavailable", error);
      }
      token_ = GenerateBearerToken();
      expires_ = base::Time::Now() + kGrantLifetime;
      pending_ = request;
      auto factory = std::make_unique<LoopbackSocketFactory>();
      factory_ = factory.get();
      starting_ = true;
      content::DevToolsAgentHost::StartRemoteDebuggingServer(
          std::move(factory), base::FilePath(), base::FilePath(),
          content::DevToolsAgentHost::RemoteDebuggingServerMode::kDefault);
      return SHAAR_OK;
    }
    if (operation == SHAAR_OP_DEVTOOLS_CONTROL_DISABLE) {
      if (Owns(engine, scope, window, tab, contents))
        Revoke();
      Reply(request, SHAAR_OK, Status(false, false));
      return SHAAR_OK;
    }
    if (operation == SHAAR_OP_DEVTOOLS_CONTROL_STATUS) {
      Reply(request, SHAAR_OK,
            Status(Owns(engine, scope, window, tab, contents), false));
      return SHAAR_OK;
    }
    return Fail(SHAAR_INVALID_ARGUMENT, "unknown agent bridge operation", error);
  }

  void RevokeForEngine(shaar_engine* engine) {
    if (engine_ == engine)
      Revoke();
  }
  void RevokeForProfile(shaar_engine* engine, shaar_profile* profile) {
    if (engine_ == engine && profile_ == profile)
      Revoke();
  }
  void RevokeForWindow(shaar_engine* engine, shaar_window* window) {
    if (engine_ == engine && window_ == window)
      Revoke();
  }
  void RevokeForTab(shaar_engine* engine, shaar_tab* tab) {
    if (engine_ == engine && tab_ == tab)
      Revoke();
  }

  void WebContentsDestroyed() override { Revoke(); }

  void PolicyChanged() {
    PrefService* state = g_browser_process ? g_browser_process->local_state()
                                           : nullptr;
    if (state && state->IsManagedPreference(
                     prefs::kDevToolsRemoteDebuggingAllowed) &&
        !state->GetBoolean(prefs::kDevToolsRemoteDebuggingAllowed))
      Revoke();
  }

  void DidFinishNavigation(content::NavigationHandle* navigation) override {
    if (navigation && navigation->IsInPrimaryMainFrame() &&
        navigation->HasCommitted() && !navigation->IsSameDocument()) {
      Revoke();
    }
  }

  bool IsLive() const {
    return enabled_ && contents_ && !token_.empty() &&
           base::Time::Now() < expires_ &&
           contents_->GetPrimaryMainFrame() &&
           contents_->GetPrimaryMainFrame()->GetDevToolsFrameToken().ToString() ==
               frame_id_;
  }
  const std::string& target_id() const { return target_id_; }
  const std::string& frame_id() const { return frame_id_; }
  const url::Origin& origin() const { return origin_; }
  content::WebContents* contents() const { return contents_.get(); }

 private:
  static bool IsOurFactory(const content::DevToolsSocketFactory* factory) {
    auto& self = Get();
    return factory && factory == self.factory_ &&
           (self.starting_ || self.enabled_);
  }

  static bool Accepts(const content::DevToolsSocketFactory* factory,
                      std::string_view token) {
    auto& self = Get();
    if (factory != self.factory_ || !self.IsLive() ||
        !IsBearerToken(std::string(kBearerPrefix) + std::string(token)) ||
        !ConstantTimeEqual(token, self.token_))
      return false;
    return true;
  }

  static void ServerChanged(const content::DevToolsSocketFactory* factory,
                            std::string_view browser_path, int port,
                            size_t connections) {
    auto& self = Get();
    if (factory != self.factory_)
      return;
    if (port <= 0) {
      self.Revoke();
      return;
    }
    if (self.starting_) {
      self.starting_ = false;
      self.enabled_ = true;
      self.port_ = port;
      self.browser_path_ = browser_path;
      self.expires_timer_.Start(
          FROM_HERE, kGrantLifetime,
          base::BindOnce([] { ControlServer::Get().Revoke(); }));
      PendingReply pending = self.pending_;
      self.pending_ = {};
      Reply(pending, SHAAR_OK, self.Status(true, true));
      self.Announce();
    }
    if (self.enabled_ && self.connections_ != connections) {
      self.connections_ = connections;
      self.Announce();
    }
  }

  std::string Status(bool granted, bool include_token) const {
    base::DictValue status;
    status.Set("schemaVersion", 1);
    status.Set("enabled", granted && enabled_);
    status.Set("connectionCount", granted ? static_cast<int>(connections_) : 0);
    if (granted && enabled_) {
      status.Set("port", port_);
      status.Set("wsEndpoint", "ws://127.0.0.1:" + std::to_string(port_) +
                                   browser_path_);
      status.Set("expiresAt",
                 static_cast<double>(expires_.InMillisecondsSinceUnixEpoch()));
      if (include_token)
        status.Set("token", token_);
    }
    return Json(status);
  }

  void Announce() {
    if (!engine_)
      return;
    const std::string payload =
        "{\"schemaVersion\":1,\"kind\":\"controlStatus\",\"enabled\":" +
        std::string(enabled_ ? "true" : "false") +
        ",\"connectionCount\":" + std::to_string(connections_) + "}";
    shaar::EmitEvent(engine_, SHAAR_EVENT_DEVTOOLS,
                     {profile_id_.data(), profile_id_.size()}, {},
                     {window_id_.data(), window_id_.size()},
                     {tab_id_.data(), tab_id_.size()},
                     {payload.data(), payload.size()});
  }

  void Revoke() {
    if (!factory_ && !engine_)
      return;
    PendingReply pending = pending_;
    pending_ = {};
    const bool was_active = enabled_;
    enabled_ = false;
    starting_ = false;
    token_.clear();
    expires_timer_.Stop();
    if (factory_) {
      factory_ = nullptr;
      content::DevToolsAgentHost::StopRemoteDebuggingServer();
    }
    if (was_active)
      Announce();
    Observe(nullptr);
    engine_ = nullptr;
    profile_ = nullptr;
    window_ = nullptr;
    tab_ = nullptr;
    contents_ = nullptr;
    profile_id_.clear();
    window_id_.clear();
    tab_id_.clear();
    target_id_.clear();
    frame_id_.clear();
    browser_path_.clear();
    port_ = 0;
    connections_ = 0;
    if (pending.callback)
      Reply(pending, SHAAR_NOT_READY, "{}");
  }

  static std::unique_ptr<ShaarAgentBridgeClient> CreateClient(
      const content::DevToolsSocketFactory* factory,
      content::DevToolsAgentHostClient* client,
      content::DevToolsAgentHost* host);
  static bool MayAttach(content::DevToolsAgentHostClient* client,
                        content::DevToolsAgentHost* host);
  static bool MayInput(content::DevToolsAgentHostClient* client,
                       content::RenderFrameHost* frame);

  shaar_engine* engine_ = nullptr;
  shaar_profile* profile_ = nullptr;
  shaar_window* window_ = nullptr;
  shaar_tab* tab_ = nullptr;
  base::WeakPtr<content::WebContents> contents_;
  url::Origin origin_;
  std::string profile_id_;
  std::string window_id_;
  std::string tab_id_;
  std::string target_id_;
  std::string frame_id_;
  std::string token_;
  std::string browser_path_;
  base::Time expires_;
  base::OneShotTimer expires_timer_;
  PrefChangeRegistrar policy_;
  const content::DevToolsSocketFactory* factory_ = nullptr;
  PendingReply pending_;
  int port_ = 0;
  size_t connections_ = 0;
  bool enabled_ = false;
  bool starting_ = false;
  bool watching_policy_ = false;
};

class AgentClient final : public ShaarAgentBridgeClient {
 public:
  AgentClient(ControlServer* server, content::DevToolsAgentHostClient* root,
              content::DevToolsAgentHost* host)
      : server_(server), root_(root), host_(host) {
    Clients()[root] = this;
  }

  ~AgentClient() override { Clients().erase(root_); }

  bool AllowedHost(content::DevToolsAgentHost* host) const {
    return server_->IsLive() &&
           (host == host_ ||
            devtools::IsProtocolPageTargetFor(server_->contents(), host));
  }

  bool FilterCommand(std::string& message, std::string* reply) override {
    if (!server_->IsLive() || message.size() > kMaximumCommandBytes)
      return Deny(0, "agent grant expired", reply, true);
    auto parsed = base::JSONReader::Read(message, base::JSON_PARSE_RFC);
    if (!parsed || !parsed->is_dict())
      return Deny(0, "invalid JSON command", reply, true);
    base::DictValue& command = parsed->GetDict();
    const auto id = command.FindInt("id");
    const std::string* method = command.FindString("method");
    const std::string* session = command.FindString("sessionId");
    if (!id || *id <= 0 || !method ||
        !HasOnlyKeys(command, {"id", "method", "params", "sessionId"}) ||
        (command.contains("sessionId") && !session) ||
        (command.contains("params") && !command.FindDict("params"))) {
      return Deny(id.value_or(0), "invalid command envelope", reply, true);
    }
    const base::DictValue* params = command.FindDict("params");
    if (!session) {
      if (*method == "Target.getTargets")
        return ReplyWithTargets(*id, reply);
      if (*method == "Target.getTargetInfo")
        return ReplyWithTarget(*id, params, reply);
      if (*method == "Target.setDiscoverTargets" ||
          *method == "Target.setAutoAttach") {
        *reply = EmptyResult(*id);
        return false;
      }
      if (*method == "Target.attachToTarget" && params &&
          params->FindString("targetId") &&
          IsBoundTarget(*params->FindString("targetId"),
                        server_->target_id()) &&
          params->FindBool("flatten").value_or(false) &&
          HasOnlyKeys(*params, {"targetId", "flatten"})) {
        pending_attach_.insert(*id);
        return true;
      }
      return Deny(*id, "browser command is outside the granted tab", reply,
                  false);
    }
    if (!sessions_.contains(*session) || !AllowsPageMethod(*method))
      return Deny(*id, "page command is not allowed", reply, false);
    if (params && (params->contains("browserContextId") ||
                   params->contains("targetId")))
      return Deny(*id, "foreign target parameter", reply, false);
    if (params && params->contains("frameId")) {
      const std::string* frame_id = params->FindString("frameId");
      if (!frame_id || *frame_id != server_->frame_id())
        return Deny(*id, "foreign frame parameter", reply, false);
    }
    if (*method == "Page.navigate") {
      const std::string* url_text = params ? params->FindString("url") : nullptr;
      const GURL url(url_text ? *url_text : "");
      if (!IsWebURL(url) || url::Origin::Create(url) != server_->origin())
        return Deny(*id, "cross-site navigation revokes the grant", reply,
                    false);
    }
    return true;
  }

  bool FilterEvent(std::string& message) override {
    if (!server_->IsLive() || message.size() > kMaximumEventBytes)
      return false;
    auto parsed = base::JSONReader::Read(message, base::JSON_PARSE_RFC);
    if (!parsed || !parsed->is_dict())
      return false;
    const base::DictValue& event = parsed->GetDict();
    const std::string* session = event.FindString("sessionId");
    if (session) {
      const std::string* method = event.FindString("method");
      return sessions_.contains(*session) &&
             (!method || !method->starts_with("Target."));
    }
    const auto id = event.FindInt("id");
    if (!id || !pending_attach_.erase(*id))
      return false;
    const base::DictValue* result = event.FindDict("result");
    const std::string* attached = result ? result->FindString("sessionId") : nullptr;
    if (attached && !attached->empty())
      sessions_.insert(*attached);
    return true;
  }

  bool ShouldClose() const override { return close_ || !server_->IsLive(); }

  bool MayAttachToURL(const GURL& url, bool is_webui) override {
    return server_->IsLive() && !is_webui && IsWebURL(url) &&
           url::Origin::Create(url) == server_->origin();
  }

  bool MayAttachToRenderFrameHost(content::RenderFrameHost* frame) override {
    return server_->IsLive() && frame &&
           frame == server_->contents()->GetPrimaryMainFrame() &&
           content::WebContents::FromRenderFrameHost(frame) ==
               server_->contents();
  }

 private:
  bool Deny(int id, const char* reason, std::string* reply, bool close) {
    *reply = ProtocolError(id, reason);
    close_ = close;
    return false;
  }

  std::string EmptyResult(int id) const {
    base::DictValue result;
    base::DictValue answer;
    answer.Set("id", id);
    answer.Set("result", std::move(result));
    return Json(answer);
  }

  base::DictValue TargetInfo() const {
    base::DictValue info;
    info.Set("targetId", server_->target_id());
    info.Set("type", "page");
    info.Set("title", "Shaar tab");
    info.Set("url", server_->contents()->GetLastCommittedURL().spec());
    info.Set("attached", false);
    return info;
  }

  bool ReplyWithTargets(int id, std::string* reply) {
    base::ListValue targets;
    targets.Append(TargetInfo());
    base::DictValue result;
    result.Set("targetInfos", std::move(targets));
    base::DictValue answer;
    answer.Set("id", id);
    answer.Set("result", std::move(result));
    *reply = Json(answer);
    return false;
  }

  bool ReplyWithTarget(int id, const base::DictValue* params,
                       std::string* reply) {
    if (params && params->contains("targetId") &&
        (!params->FindString("targetId") ||
         !IsBoundTarget(*params->FindString("targetId"),
                        server_->target_id()))) {
      return Deny(id, "foreign target", reply, false);
    }
    base::DictValue result;
    result.Set("targetInfo", TargetInfo());
    base::DictValue answer;
    answer.Set("id", id);
    answer.Set("result", std::move(result));
    *reply = Json(answer);
    return false;
  }

  ControlServer* server_;
  content::DevToolsAgentHostClient* root_;
  content::DevToolsAgentHost* host_;
  std::set<int> pending_attach_;
  std::set<std::string> sessions_;
  bool close_ = false;
};

std::unique_ptr<ShaarAgentBridgeClient> ControlServer::CreateClient(
    const content::DevToolsSocketFactory* factory,
    content::DevToolsAgentHostClient* client,
    content::DevToolsAgentHost* host) {
  auto& self = Get();
  if (factory != self.factory_ || !self.IsLive() || !client || !host ||
      host->GetType() != content::DevToolsAgentHost::kTypeBrowser)
    return nullptr;
  return std::make_unique<AgentClient>(&self, client, host);
}

bool ControlServer::MayAttach(content::DevToolsAgentHostClient* client,
                              content::DevToolsAgentHost* host) {
  const auto found = Clients().find(client);
  return found == Clients().end() || found->second->AllowedHost(host);
}

bool ControlServer::MayInput(content::DevToolsAgentHostClient* client,
                             content::RenderFrameHost*) {
  return !Clients().contains(client);
}

}  // namespace

bool AllowsPageMethod(std::string_view method) {
  static constexpr std::string_view methods[] = {
      "CSS.enable", "CSS.getComputedStyleForNode", "CSS.getMatchedStylesForNode",
      "DOM.describeNode", "DOM.enable", "DOM.getBoxModel", "DOM.getDocument",
      "DOM.getOuterHTML", "DOM.querySelector", "DOM.querySelectorAll",
      "DOM.resolveNode", "Emulation.setDeviceMetricsOverride", "Log.enable",
      "Network.enable", "Network.getResponseBody", "Page.captureScreenshot",
      "Page.enable", "Page.getLayoutMetrics", "Page.navigate", "Page.reload",
      "Runtime.awaitPromise", "Runtime.callFunctionOn", "Runtime.enable",
      "Runtime.evaluate", "Runtime.getProperties", "Runtime.releaseObject",
  };
  return std::find(std::begin(methods), std::end(methods), method) !=
         std::end(methods);
}

bool IsBearerToken(std::string_view authorization) {
  if (!authorization.starts_with(kBearerPrefix) ||
      authorization.size() != sizeof(kBearerPrefix) - 1 + 43)
    return false;
  for (char ch : authorization.substr(sizeof(kBearerPrefix) - 1)) {
    if (!((ch >= 'A' && ch <= 'Z') || (ch >= 'a' && ch <= 'z') ||
          (ch >= '0' && ch <= '9') || ch == '-' || ch == '_'))
      return false;
  }
  return true;
}

bool IsBoundTarget(std::string_view requested, std::string_view granted) {
  return !requested.empty() && !granted.empty() && requested == granted;
}

std::string GenerateBearerToken() {
  const std::vector<uint8_t> secret = base::RandBytesAsVector(32);
  std::string token;
  base::Base64UrlEncode(secret,
                        base::Base64UrlEncodePolicy::OMIT_PADDING, &token);
  return token;
}

bool HasActiveGrantForTesting() {
  return ControlServer::Get().IsLive();
}

shaar_error_code HandleOperation(shaar_engine* engine, shaar_scope scope,
                                 shaar_window* window, shaar_tab* tab,
                                 content::WebContents* contents,
                                 const DevToolsTargetIdentity& identity,
                                 shaar_operation operation,
                                 shaar_request_id request_id,
                                 shaar_reply_fn reply, void* reply_context,
                                 shaar_error* error) {
  return ControlServer::Get().Handle(
      engine, scope, window, tab, contents, identity, operation,
      {request_id, reply, reply_context}, error);
}

void RevokeForEngine(shaar_engine* engine) {
  ControlServer::Get().RevokeForEngine(engine);
}
void RevokeForProfile(shaar_engine* engine, shaar_profile* profile) {
  ControlServer::Get().RevokeForProfile(engine, profile);
}
void RevokeForWindow(shaar_engine* engine, shaar_window* window) {
  ControlServer::Get().RevokeForWindow(engine, window);
}
void RevokeForTab(shaar_engine* engine, shaar_tab* tab) {
  ControlServer::Get().RevokeForTab(engine, tab);
}

}  // namespace shaar::agent_bridge
