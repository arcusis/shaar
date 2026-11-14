// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#include "chrome/browser/shaar/lifecycle/shaar_lifecycle.h"

#include <mach-o/dyld.h>
#include <pthread.h>

#include <array>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <sstream>
#include <string>
#include <vector>

#include "base/files/file_path.h"
#include "base/files/file_util.h"
#include "base/memory/raw_ptr.h"
#include "chrome/browser/chrome_browser_main.h"
#include "chrome/browser/chrome_browser_main_extra_parts.h"
#include "chrome/browser/chrome_content_browser_client.h"
#include "chrome/browser/lifetime/application_lifetime.h"
#include "chrome/browser/lifetime/application_lifetime_desktop.h"
#include "chrome/browser/lifetime/browser_shutdown.h"
#include "chrome/browser/shaar/engine/shaar_event_bridge.h"
#include "chrome/browser/shaar/engine/shaar_module_registry.h"
#include "chrome/browser/shaar/devtools/shaar_agent_bridge.h"
#include "chrome/browser/shaar/history/shaar_history.h"
#include "chrome/browser/shaar/media/shaar_media_permission.h"
#include "chrome/browser/shaar/private_sessions/shaar_private_trackers.h"
#include "chrome/browser/shaar/windows_tabs/shaar_windows_tabs.h"
#include "content/public/browser/browser_context.h"
#include "content/public/browser/browser_main_parts.h"
#include "content/public/browser/render_frame_host.h"
#include "content/public/browser/render_process_host.h"
#include "components/keep_alive_registry/keep_alive_registry.h"
#include "components/keep_alive_registry/scoped_keep_alive.h"
#include "components/keep_alive_registry/keep_alive_types.h"
#include "mojo/public/cpp/bindings/remote.h"
#include "net/base/net_errors.h"
#include "services/network/public/mojom/web_transport.mojom.h"
#include "services/network/public/mojom/websocket.mojom.h"

extern "C" int ChromeMain(int argc, const char** argv);

namespace {

constexpr char kReady[] = R"({"kind":"engine.ready","schemaVersion":1})";
constexpr char kQuitRequested[] =
    R"({"kind":"engine.quitRequested","schemaVersion":1})";
constexpr char kQuitCancelled[] =
    R"({"kind":"engine.quitCancelled","schemaVersion":1})";
constexpr char kWillShutDown[] =
    R"({"kind":"engine.willShutDown","schemaVersion":1})";
constexpr char kStopped[] = R"({"kind":"engine.stopped","schemaVersion":1})";
constexpr char kStartupFailed[] =
    R"({"kind":"engine.startupFailed","schemaVersion":1})";

struct State {
  shaar_engine* engine = nullptr;
  bool ready = false;
  bool closing = false;
  bool shutting_down = false;
  bool safe_storage_unavailable = false;
  std::unique_ptr<ScopedKeepAlive> host_keep_alive;
};

State g_state;
bool g_run_was_started = false;
thread_local std::string g_probe_keep_alive_state;

bool IsMarkedProbeRoot(const shaar_engine* engine) {
  const base::FilePath data_root = base::MakeAbsoluteFilePath(
      base::FilePath::FromUTF8Unsafe(engine->data_root));
  if (data_root.empty())
    return false;
  const base::FilePath root = data_root.DirName();
  if (data_root != root.Append("Chromium") ||
      root.BaseName().value().rfind("arcusis-engine-probe-", 0) != 0)
    return false;
  std::string marker;
  return base::ReadFileToString(root.Append(".arcusis-probe"), &marker) &&
         marker == "arcusis-engine-probe-v1\n";
}

shaar_error_code Fail(shaar_error_code code,
                      const char* message,
                      int32_t platform_code,
                      shaar_error* error) {
  if (!error)
    return code;
  const uint32_t supplied_size = error->size;
  if (supplied_size >= offsetof(shaar_error, code) + sizeof(error->code))
    error->code = code;
  if (supplied_size >=
      offsetof(shaar_error, platform_code) + sizeof(error->platform_code))
    error->platform_code = platform_code;
  if (supplied_size >= offsetof(shaar_error, message) + sizeof(error->message))
    error->message = {message, strlen(message)};
  return code;
}

shaar_error_code Emit(shaar_engine* engine, const char* payload) {
  return shaar::EmitEvent(engine, SHAAR_EVENT_ENGINE, {}, {}, {}, {},
                          {payload, strlen(payload)});
}

class LifecycleExtraParts final : public ChromeBrowserMainExtraParts {
 public:
  explicit LifecycleExtraParts(shaar_engine* engine) : engine_(engine) {}

  void PostBrowserStart() override { shaar::lifecycle::EngineReady(engine_); }
  void PostMainMessageLoopRun() override {
    shaar::lifecycle::EngineWillShutDown(engine_);
  }

 private:
  raw_ptr<shaar_engine> engine_;
};

class ShaarContentBrowserClient final : public ChromeContentBrowserClient {
 public:
  explicit ShaarContentBrowserClient(shaar_engine* engine) : engine_(engine) {}

  std::unique_ptr<content::BrowserMainParts> CreateBrowserMainParts(
      bool is_integration_test) override {
    std::unique_ptr<content::BrowserMainParts> parts =
        ChromeContentBrowserClient::CreateBrowserMainParts(is_integration_test);
    static_cast<ChromeBrowserMainParts*>(parts.get())
        ->AddParts(std::make_unique<LifecycleExtraParts>(engine_));
    return parts;
  }

  void WillCreateURLLoaderFactory(
      content::BrowserContext *browser_context, content::RenderFrameHost *frame,
      int render_process_id, URLLoaderFactoryType type,
      const url::Origin &request_initiator,
      const net::IsolationInfo &isolation_info,
      std::optional<int64_t> navigation_id, ukm::SourceIdObj ukm_source_id,
      network::URLLoaderFactoryBuilder &factory_builder,
      mojo::PendingRemote<network::mojom::TrustedURLLoaderHeaderClient>
          *header_client,
      bool *bypass_redirect_checks, bool *disable_secure_dns,
      network::mojom::URLLoaderFactoryOverridePtr *factory_override,
      scoped_refptr<base::SequencedTaskRunner> navigation_response_task_runner,
      bool is_for_network_service) override {
    shaar::InstallPrivateTrackerFactory(browser_context, isolation_info,
                                        factory_builder);
    ChromeContentBrowserClient::WillCreateURLLoaderFactory(
        browser_context, frame, render_process_id, type, request_initiator,
        isolation_info, navigation_id, ukm_source_id, factory_builder,
        header_client, bypass_redirect_checks, disable_secure_dns,
        factory_override, navigation_response_task_runner,
        is_for_network_service);
  }

  bool WillInterceptWebSocket(content::RenderFrameHost *frame) override {
    return (frame && frame->GetBrowserContext()->IsOffTheRecord()) ||
           ChromeContentBrowserClient::WillInterceptWebSocket(frame);
  }

  void CreateWebSocket(
      content::RenderFrameHost *frame, WebSocketFactory factory,
      const GURL &url, const net::SiteForCookies &site_for_cookies,
      const std::optional<std::string> &user_agent,
      mojo::PendingRemote<network::mojom::WebSocketHandshakeClient>
          handshake_client,
      content::ContentBrowserClient::WebSocketOptions options) override {
    if (frame &&
        shaar::ShouldBlockPrivateTracker(
            frame->GetBrowserContext(), url,
            frame->GetOutermostMainFrame()->GetLastCommittedOrigin())) {
      mojo::Remote<network::mojom::WebSocketHandshakeClient> client(
          std::move(handshake_client));
      client->OnFailure("Blocked by private tracker protection",
                        net::ERR_BLOCKED_BY_CLIENT, -1);
      return;
    }
    if (ChromeContentBrowserClient::WillInterceptWebSocket(frame)) {
      ChromeContentBrowserClient::CreateWebSocket(
          frame, std::move(factory), url, site_for_cookies, user_agent,
          std::move(handshake_client), std::move(options));
      return;
    }
    std::move(factory).Run(url, {}, std::move(handshake_client), {},
                           std::move(options.header_client));
  }

  void WillCreateWebTransport(
      int process_id, int frame_routing_id, const GURL &url,
      const url::Origin &initiator_origin,
      mojo::PendingRemote<network::mojom::WebTransportHandshakeClient>
          handshake_client,
      WillCreateWebTransportCallback callback) override {
    auto *process = content::RenderProcessHost::FromID(process_id);
    if (process && process->GetBrowserContext()->IsOffTheRecord()) {
      std::optional<url::Origin> top_origin = initiator_origin;
      if (auto *frame =
              content::RenderFrameHost::FromID(process_id, frame_routing_id)) {
        top_origin = frame->GetOutermostMainFrame()->GetLastCommittedOrigin();
      }
      if (shaar::ShouldBlockPrivateTracker(process->GetBrowserContext(), url,
                                           top_origin)) {
        auto error = network::mojom::WebTransportError::New();
        error->net_error = net::ERR_BLOCKED_BY_CLIENT;
        error->details = "Blocked by private tracker protection";
        std::move(callback).Run(std::move(handshake_client), std::move(error));
        return;
      }
    }
    ChromeContentBrowserClient::WillCreateWebTransport(
        process_id, frame_routing_id, url, initiator_origin,
        std::move(handshake_client), std::move(callback));
  }

 private:
  raw_ptr<shaar_engine> engine_;
};

bool MakeExecutablePath(std::string* path) {
  std::array<char, 4096> buffer{};
  uint32_t size = buffer.size();
  if (_NSGetExecutablePath(buffer.data(), &size) != 0)
    return false;
  *path = buffer.data();
  return true;
}

}  // namespace

namespace shaar::lifecycle {

std::vector<std::string> ChromeMainArguments(
    const std::string& executable_path, const std::string& data_root,
    const std::string& locale, bool testing) {
  std::vector<std::string> arguments = {
      executable_path, "--user-data-dir=" + data_root, "--no-first-run",
      "--no-default-browser-check", "--no-startup-window",
      "--disable-background-mode", "--shaar-embedder"};
  // Chromium 157 shows an HTTPS-only warning as a Views dialog. Shaar has no
  // dialog host, so keep Chromium's interstitial.
  arguments.push_back("--disable-features=HttpsFirstDialogUi");
  if (testing) {
    arguments.push_back("--use-mock-keychain");
    arguments.push_back("--use-fake-device-for-media-stream");
    arguments.push_back("--disable-renderer-backgrounding");
    arguments.push_back("--disable-backgrounding-occluded-windows");
    arguments.push_back("--disable-background-timer-throttling");
    // Private privacy fixtures use this synthetic tracker hostname with the
    // owned loopback server. Never send those requests to the public network.
    arguments.push_back("--host-resolver-rules=MAP trackertest.org 127.0.0.1");
  }
  if (!locale.empty())
    arguments.push_back("--lang=" + locale);
  return arguments;
}

std::unique_ptr<ChromeContentBrowserClient> CreateContentBrowserClient() {
  return std::make_unique<ShaarContentBrowserClient>(g_state.engine);
}

std::unique_ptr<ScopedKeepAlive> CreateHostKeepAlive() {
  return std::make_unique<ScopedKeepAlive>(KeepAliveOrigin::APP_CONTROLLER,
                                          KeepAliveRestartOption::DISABLED);
}

void EngineReady(shaar_engine* engine) {
  if (g_state.engine != engine || g_state.ready || g_state.closing)
    return;
  g_state.host_keep_alive = CreateHostKeepAlive();
  g_state.ready = true;
  shaar::media::StartCaptureObserving(engine);
  Emit(engine, kReady);
  if (g_state.safe_storage_unavailable)
    SafeStorageUnavailable();
}

void SafeStorageUnavailable() {
  g_state.safe_storage_unavailable = true;
  if (g_state.engine && g_state.ready && !g_state.shutting_down) {
    Emit(g_state.engine,
         R"({"kind":"storage.keychainUnavailable","schemaVersion":1,"restartRequired":true,"persistentCookiesAvailable":false})");
  }
}

void EngineQuitCancelled() {
  if (!g_state.engine || !g_state.closing || g_state.shutting_down)
    return;
  shaar::windows_tabs::Registry().CancelEngineQuit(g_state.engine);
  g_state.host_keep_alive = CreateHostKeepAlive();
  g_state.closing = false;
  Emit(g_state.engine, kQuitCancelled);
}

void EngineWillShutDown(shaar_engine* engine) {
  if (g_state.engine != engine || g_state.shutting_down)
    return;
  g_state.shutting_down = true;
  shaar::agent_bridge::RevokeForEngine(engine);
  g_state.host_keep_alive.reset();
  shaar::windows_tabs::Registry().BeginEngineQuit(engine);
  shaar_history::StopObservingLifecycle(engine);
  shaar::media::StopCaptureObserving();
  shaar::windows_tabs::StopObservingLifecycle();
  Emit(engine, kWillShutDown);
}

shaar_engine* ActiveEngine() {
  return g_state.engine;
}

bool EngineIsRunning(shaar_engine* engine) {
  return g_state.engine == engine && engine->run_active;
}

bool EngineIsReady(shaar_engine* engine) {
  return g_state.engine == engine && g_state.ready && !g_state.shutting_down;
}

bool EngineIsShuttingDown(shaar_engine* engine) {
  return g_state.engine == engine && g_state.shutting_down;
}

bool HasOwnedProbeRoot(const shaar_engine* engine) {
  return engine && IsMarkedProbeRoot(engine);
}

}  // namespace shaar::lifecycle

extern "C" SHAAR_EXPORT shaar_error_code shaar_test_keep_alive_state(
    shaar_engine* engine, shaar_bytes* out, shaar_error* error) {
  if (out) *out = {};
  if (!engine || !out)
    return Fail(SHAAR_INVALID_ARGUMENT, "missing probe input", 0, error);
  if (!pthread_main_np())
    return Fail(SHAAR_INVALID_ARGUMENT, "main thread required", 0, error);
  if (g_state.engine != engine || !g_state.ready || !engine->run_active)
    return Fail(SHAAR_NOT_READY, "engine is not running", 0, error);
  const char* testing = std::getenv("SHAAR_ENGINE_TESTING");
  if (!testing || std::strcmp(testing, "1") != 0)
    return Fail(SHAAR_POLICY_BLOCKED, "verification mode required", 0, error);
  if (!IsMarkedProbeRoot(engine))
    return Fail(SHAAR_POLICY_BLOCKED, "foreign probe root", 0, error);
  std::ostringstream state;
  state << *KeepAliveRegistry::GetInstance()
        << " trying_to_quit=" << browser_shutdown::IsTryingToQuit();
  g_probe_keep_alive_state = state.str();
  *out = {g_probe_keep_alive_state.data(), g_probe_keep_alive_state.size()};
  return Fail(SHAAR_OK, "", 0, error);
}

extern "C" SHAAR_EXPORT shaar_error_code shaar_engine_run(
    shaar_engine* engine,
    shaar_error* error) {
  if (!engine)
    return Fail(SHAAR_INVALID_ARGUMENT, "missing engine", 0, error);
  if (!pthread_main_np())
    return Fail(SHAAR_INVALID_ARGUMENT, "main thread required", 0, error);
  if (g_run_was_started)
    return Fail(SHAAR_CONFLICT, "engine process is single-run", 0, error);
  if (engine->data_root.empty() || !base::FilePath::FromUTF8Unsafe(
                                     engine->data_root).IsAbsolute()) {
    return Fail(SHAAR_INVALID_ARGUMENT, "data root must be an absolute path",
                0, error);
  }

  g_run_was_started = true;
  g_state = State{.engine = engine};
  std::string executable_path;
  if (!MakeExecutablePath(&executable_path)) {
    g_state.engine = nullptr;
    return Fail(SHAAR_IO_ERROR, "could not resolve app executable path", 0,
                error);
  }

  const char* testing = std::getenv("SHAAR_ENGINE_TESTING");
  std::vector<std::string> argument_storage =
      shaar::lifecycle::ChromeMainArguments(
          executable_path, engine->data_root, engine->locale,
          testing && std::strcmp(testing, "1") == 0);
  std::vector<const char*> argv;
  argv.reserve(argument_storage.size());
  for (const std::string& argument : argument_storage)
    argv.push_back(argument.c_str());
  argv.push_back(nullptr);


  engine->run_active = true;
  const int result = ChromeMain(static_cast<int>(argv.size() - 1), argv.data());

  if (!g_state.ready)
    Emit(engine, kStartupFailed);
  if (!g_state.shutting_down)
    shaar::lifecycle::EngineWillShutDown(engine);
  engine->run_active = false;
  g_state = {};
  Emit(engine, kStopped);
  shaar::windows_tabs::Registry().CancelEngineQuit(engine);
  return result == 0 ? Fail(SHAAR_OK, "", 0, error)
                     : Fail(SHAAR_CHROMIUM_ERROR, "Chromium startup or run failed",
                            result, error);
}

extern "C" SHAAR_EXPORT shaar_error_code shaar_engine_request_quit(
    shaar_engine* engine,
    shaar_error* error) {
  if (!engine)
    return Fail(SHAAR_INVALID_ARGUMENT, "missing engine", 0, error);
  if (!pthread_main_np())
    return Fail(SHAAR_INVALID_ARGUMENT, "main thread required", 0, error);
  if (g_state.engine != engine || !g_state.ready)
    return Fail(SHAAR_NOT_READY, "engine is not ready", 0, error);
  if (g_state.closing)
    return Fail(SHAAR_SHUTTING_DOWN, "shutdown is already requested", 0,
                error);

  g_state.closing = true;
  shaar::windows_tabs::Registry().BeginEngineQuit(engine);
  Emit(engine, kQuitRequested);
  // The Mac application delegate's termination route can wait on native
  // prompts while Shaar still owns hidden browser windows. Close Chromium's
  // browsers directly so their normal unload and shutdown callbacks run.
  g_state.host_keep_alive.reset();
  chrome::CloseAllBrowsersAndQuit();
  return Fail(SHAAR_OK, "", 0, error);
}
