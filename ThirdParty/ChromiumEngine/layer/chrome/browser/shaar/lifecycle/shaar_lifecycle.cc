// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#include "chrome/browser/shaar/lifecycle/shaar_lifecycle.h"

#include <mach-o/dyld.h>
#include <pthread.h>

#include <array>
#include <cstring>
#include <memory>
#include <string>
#include <vector>

#include "base/files/file_path.h"
#include "base/memory/raw_ptr.h"
#include "chrome/browser/chrome_browser_main.h"
#include "chrome/browser/chrome_browser_main_extra_parts.h"
#include "chrome/browser/chrome_content_browser_client.h"
#include "chrome/browser/lifetime/application_lifetime.h"
#include "chrome/browser/shaar/engine/shaar_event_bridge.h"
#include "chrome/browser/shaar/engine/shaar_module_registry.h"
// BEGIN find
#include "chrome/browser/shaar/private_sessions/shaar_private_sessions_module.h"
// END find
#include "content/public/browser/browser_main_parts.h"

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
  // BEGIN find
  std::unique_ptr<shaar::PrivateSessionRegistry> private_sessions;
  // END find
  bool ready = false;
  bool closing = false;
  bool shutting_down = false;
};

State g_state;
bool g_run_was_started = false;

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

std::unique_ptr<ChromeContentBrowserClient> CreateContentBrowserClient() {
  return std::make_unique<ShaarContentBrowserClient>(g_state.engine);
}

void EngineReady(shaar_engine* engine) {
  if (g_state.engine != engine || g_state.ready || g_state.closing)
    return;
  g_state.ready = true;
  Emit(engine, kReady);
}

void EngineQuitCancelled() {
  if (!g_state.engine || !g_state.closing || g_state.shutting_down)
    return;
  g_state.closing = false;
  Emit(g_state.engine, kQuitCancelled);
}

void EngineWillShutDown(shaar_engine* engine) {
  if (g_state.engine != engine || g_state.shutting_down)
    return;
  g_state.shutting_down = true;
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

}  // namespace shaar::lifecycle

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
  // BEGIN find
  g_state.private_sessions =
      shaar::CreatePrivateSessionRegistry(engine);
  // END find
  std::string executable_path;
  if (!MakeExecutablePath(&executable_path)) {
    // BEGIN find
    g_state.private_sessions.reset();
    // END find
    g_state.engine = nullptr;
    return Fail(SHAAR_IO_ERROR, "could not resolve app executable path", 0,
                error);
  }

  std::string user_data_switch = "--user-data-dir=" + engine->data_root;
  std::string locale_switch;
  if (!engine->locale.empty())
    locale_switch = "--lang=" + engine->locale;
  std::vector<std::string> argument_storage = {
      executable_path, user_data_switch, "--no-first-run",
      "--no-default-browser-check", "--disable-background-mode"};
  if (!locale_switch.empty()) {
    argument_storage.push_back(locale_switch);
  }
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
  Emit(engine, kQuitRequested);
  chrome::AttemptExit();
  return Fail(SHAAR_OK, "", 0, error);
}
