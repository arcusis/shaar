// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#include "chrome/browser/shaar/devtools/shaar_devtools_viewports.h"

#include <stddef.h>
#include <algorithm>
#include <climits>
#include <cstring>
#include <optional>
#include <initializer_list>
#include <map>
#include <memory>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

#include "base/functional/bind.h"
#include "base/containers/span.h"
#include "base/functional/callback_helpers.h"
#include "base/json/json_reader.h"
#include "base/json/json_writer.h"
#include "base/memory/weak_ptr.h"
#include "base/task/sequenced_task_runner.h"
#include "base/time/time.h"
#include "base/timer/timer.h"
#include "base/values.h"
#include "chrome/browser/shaar/devtools/shaar_devtools.h"
#include "chrome/browser/shaar/engine/shaar_engine_context.h"
#include "content/public/browser/devtools_agent_host.h"
#include "content/public/browser/devtools_agent_host_client.h"
#include "content/public/browser/navigation_controller.h"
#include "content/public/browser/navigation_handle.h"
#include "content/public/browser/web_contents.h"
#include "content/public/browser/web_contents_observer.h"
#include "content/public/browser/render_widget_host_view.h"
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

void Deliver(ReplyTarget target, shaar_error_code code, std::string payload,
             std::string message) {
  shaar_result result{};
  result.size = sizeof(result);
  result.request_id = target.id;
  result.error.size = sizeof(result.error);
  result.error.code = code;
  result.error.message = {message.data(), message.size()};
  result.payload_json = {payload.data(), payload.size()};
  target.callback(target.context, &result);
}

void Reply(ReplyTarget target, shaar_error_code code, std::string payload,
           std::string message = {}) {
  base::SequencedTaskRunner::GetCurrentDefault()->PostTask(
      FROM_HERE, base::BindOnce(&Deliver, target, code, std::move(payload),
                                std::move(message)));
}

void Reply(ReplyTarget target, std::string payload) {
  Reply(target, SHAAR_OK, std::move(payload));
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

bool ValidInsets(const base::DictValue& insets) {
  if (!HasKeys(insets, {"top", "right", "bottom", "left"}))
    return false;
  for (std::string_view edge : {"top", "right", "bottom", "left"}) {
    const auto value = insets.FindInt(edge);
    if (!value || *value < 0 || *value > 200)
      return false;
  }
  return true;
}

base::DictValue DefaultInsets(std::string_view preset) {
  int top = 0;
  int bottom = 0;
  if (preset == "iphone15Pro") {
    top = 59;
    bottom = 34;
  } else if (preset == "pixel8") {
    top = 24;
    bottom = 24;
  }
  base::DictValue insets;
  insets.Set("top", top);
  insets.Set("right", 0);
  insets.Set("bottom", bottom);
  insets.Set("left", 0);
  return insets;
}

class ViewportSession;

class Viewport final : public content::DevToolsAgentHostClient,
                       public content::WebContentsObserver {
 public:
  Viewport(ViewportSession* session, int id, std::string preset, int width,
           int height, std::unique_ptr<content::WebContents> contents)
      : content::WebContentsObserver(contents.get()), session_(session), id_(id),
        preset_(std::move(preset)), width_(width), height_(height),
        contents_(std::move(contents)) {}

  ~Viewport() override {
    Observe(nullptr);
    CompleteCapture(SHAAR_CANCELLED, {}, "viewport closed");
    if (attached_)
      host_->DetachClient(this);
  }

  bool Attach() {
    host_ = ProtocolAgentHostFor(contents_.get());
    if (!host_ || !host_->AttachClient(this))
      return false;
    attached_ = true;
    base::DictValue metrics;
    metrics.Set("width", width_);
    metrics.Set("height", height_);
    metrics.Set("deviceScaleFactor", 1);
    metrics.Set("mobile", preset_ != "desktop");
    return Send("Emulation.setDeviceMetricsOverride", std::move(metrics)) != 0 &&
           SetSafeArea(DefaultInsets(preset_));
  }

  int id() const { return id_; }
  int width() const { return width_; }
  int height() const { return height_; }
  bool attached() const { return attached_; }
  const GURL& url() const { return contents_->GetLastCommittedURL(); }

  void Navigate(const GURL& url) {
    content::NavigationController::LoadURLParams params(url);
    contents_->GetController().LoadURLWithParams(params);
  }

  bool SetSafeArea(const base::DictValue& insets) {
    base::DictValue params;
    params.Set("insets", insets.Clone());
    return Send("Emulation.setSafeAreaInsetsOverride", std::move(params)) != 0;
  }

  bool Click(int x, int y) {
    base::DictValue pressed;
    pressed.Set("type", "mousePressed");
    pressed.Set("x", x);
    pressed.Set("y", y);
    pressed.Set("button", "left");
    pressed.Set("clickCount", 1);
    base::DictValue released = pressed.Clone();
    released.Set("type", "mouseReleased");
    return Send("Input.dispatchMouseEvent", std::move(pressed)) != 0 &&
           Send("Input.dispatchMouseEvent", std::move(released)) != 0;
  }

  bool Scroll(int delta_x, int delta_y) {
    base::DictValue params;
    params.Set("type", "mouseWheel");
    params.Set("x", width_ / 2);
    params.Set("y", height_ / 2);
    params.Set("deltaX", delta_x);
    params.Set("deltaY", delta_y);
    return Send("Input.dispatchMouseEvent", std::move(params)) != 0;
  }

  bool Capture(ReplyTarget reply) {
    if (pending_capture_ || !attached_ || !contents_->GetRenderWidgetHostView())
      return false;
    capture_lease_ = StartHiddenProbeCapture(contents_.get());
    if (!capture_lease_)
      return false;
    base::DictValue params;
    params.Set("format", "png");
    params.Set("captureBeyondViewport", false);
    pending_capture_ = reply;
    capture_command_id_ = next_command_id_;
    timer_.Start(FROM_HERE, base::Seconds(12),
                 base::BindOnce(&Viewport::CaptureTimedOut,
                                weak_factory_.GetWeakPtr()));
    const int id = Send("Page.captureScreenshot", std::move(params));
    if (!id) {
      pending_capture_.reset();
      capture_command_id_ = 0;
      timer_.Stop();
      capture_lease_.RunAndReset();
      return false;
    }
    return true;
  }

  void DispatchProtocolMessage(content::DevToolsAgentHost*,
                               base::span<const uint8_t> message) override {
    if (!pending_capture_ || message.size() > 12 * 1024 * 1024)
      return;
    const std::string_view input(reinterpret_cast<const char*>(message.data()),
                                 message.size());
    auto parsed = base::JSONReader::Read(input, base::JSON_PARSE_RFC);
    if (!parsed || !parsed->is_dict() ||
        parsed->GetDict().FindInt("id") != capture_command_id_)
      return;
    const auto* result = parsed->GetDict().FindDict("result");
    const auto* data = result ? result->FindString("data") : nullptr;
    if (!data || data->empty() || data->size() > ((8 * 1024 * 1024 + 2) / 3) * 4 ||
        parsed->GetDict().FindDict("error")) {
      CompleteCapture(SHAAR_NOT_READY, {}, "viewport frame unavailable");
      return;
    }
    base::DictValue envelope;
    envelope.Set("schemaVersion", 1);
    envelope.Set("viewportID", id_);
    envelope.Set("url", url().spec());
    envelope.Set("data", *data);
    std::string payload;
    if (!base::JSONWriter::Write(base::Value(std::move(envelope)), &payload)) {
      CompleteCapture(SHAAR_CHROMIUM_ERROR, {}, "viewport frame encoding failed");
      return;
    }
    CompleteCapture(SHAAR_OK, std::move(payload), {});
  }

  void AgentHostClosed(content::DevToolsAgentHost*) override {
    attached_ = false;
    CompleteCapture(SHAAR_CANCELLED, {}, "viewport target closed");
  }

  void DidFinishNavigation(content::NavigationHandle* navigation) override;

 private:
  int Send(std::string_view method, base::DictValue params) {
    if (!attached_ || next_command_id_ == INT_MAX)
      return 0;
    const int id = next_command_id_++;
    base::DictValue command;
    command.Set("id", id);
    command.Set("method", std::string(method));
    command.Set("params", std::move(params));
    std::string json;
    if (!base::JSONWriter::Write(base::Value(std::move(command)), &json))
      return 0;
    host_->DispatchProtocolMessage(this, base::as_byte_span(json));
    return id;
  }

  void CaptureTimedOut() {
    CompleteCapture(SHAAR_NOT_READY, {}, "viewport frame timed out");
  }

  void CompleteCapture(shaar_error_code code, std::string payload,
                       std::string message) {
    if (!pending_capture_)
      return;
    const ReplyTarget reply = *pending_capture_;
    pending_capture_.reset();
    capture_command_id_ = 0;
    timer_.Stop();
    capture_lease_.RunAndReset();
    Reply(reply, code, std::move(payload), std::move(message));
  }

  ViewportSession* session_;
  int id_;
  std::string preset_;
  int width_;
  int height_;
  std::unique_ptr<content::WebContents> contents_;
  scoped_refptr<content::DevToolsAgentHost> host_;
  bool attached_ = false;
  int next_command_id_ = 1;
  int capture_command_id_ = 0;
  std::optional<ReplyTarget> pending_capture_;
  base::ScopedClosureRunner capture_lease_;
  base::OneShotTimer timer_;
  base::WeakPtrFactory<Viewport> weak_factory_{this};
};

class ViewportSession final : public content::WebContentsObserver {
 public:
  ViewportSession(shaar_engine* engine, content::WebContents* source,
                  DevToolsTargetIdentity identity, int lease_id)
      : content::WebContentsObserver(source), engine_(engine), source_(source),
        identity_(std::move(identity)), lease_id_(lease_id),
        synced_url_(source->GetLastCommittedURL()) {}

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
    const GURL url = synced_url_;
    if (!IsPageURL(url))
      return 0;
    auto child = content::WebContents::Create(
        content::WebContents::CreateParams(source_->GetBrowserContext()));
    if (!child)
      return 0;
    const int id = next_viewport_id_++;
    auto viewport = std::make_unique<Viewport>(this, id, std::move(preset),
                                                width, height, std::move(child));
    if (!viewport->Attach())
      return 0;
    viewport->Navigate(url);
    viewports_.push_back(std::move(viewport));
    return id;
  }

  bool Remove(int viewport_id) {
    if (viewports_.size() <= 1)
      return false;
    const auto old_size = viewports_.size();
    std::erase_if(viewports_, [viewport_id](const auto& viewport) {
      return viewport->id() == viewport_id;
    });
    return viewports_.size() != old_size;
  }

  Viewport* Find(int viewport_id) const {
    for (const auto& viewport : viewports_)
      if (viewport->id() == viewport_id)
        return viewport.get();
    return nullptr;
  }

  bool Click(int viewport_id, int x, int y) {
    Viewport* source = Find(viewport_id);
    if (!source || x < 0 || x >= source->width() || y < 0 ||
        y >= source->height() || !AllAttached())
      return false;
    for (const auto& viewport : viewports_)
      if (!viewport->Click(x * viewport->width() / source->width(),
                           y * viewport->height() / source->height()))
        return false;
    return true;
  }

  bool Scroll(int viewport_id, int delta_x, int delta_y) {
    if (!Find(viewport_id) || delta_x < -2000 || delta_x > 2000 ||
        delta_y < -2000 || delta_y > 2000 || !AllAttached())
      return false;
    for (const auto& viewport : viewports_)
      if (!viewport->Scroll(delta_x, delta_y))
        return false;
    return true;
  }

  bool SetSafeArea(int viewport_id, const base::DictValue& insets) {
    auto* viewport = Find(viewport_id);
    return viewport && ValidInsets(insets) && viewport->SetSafeArea(insets);
  }

  bool AllAttached() const {
    return std::all_of(viewports_.begin(), viewports_.end(),
                       [](const auto& viewport) { return viewport->attached(); });
  }

  bool NavigateAll(const GURL& url) {
    if (!IsPageURL(url))
      return false;
    synced_url_ = url;
    for (const auto& viewport : viewports_)
      viewport->Navigate(url);
    return true;
  }

  void ChildNavigated(int viewport_id, const GURL& url) {
    if (!IsPageURL(url) || url == synced_url_)
      return;
    synced_url_ = url;
    for (const auto& viewport : viewports_)
      if (viewport->id() != viewport_id && viewport->url() != url)
        viewport->Navigate(url);
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
  GURL synced_url_;
  std::vector<std::unique_ptr<Viewport>> viewports_;
};

void Viewport::DidFinishNavigation(content::NavigationHandle* navigation) {
  if (navigation->HasCommitted() && navigation->IsInPrimaryMainFrame() &&
      !navigation->IsSameDocument())
    session_->ChildNavigated(id_, navigation->GetURL());
}

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
      !request_id || !args_json.data || !args_json.size ||
      args_json.size > 16 * 1024 ||
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
  if (operation == SHAAR_OP_DEVTOOLS_VIEWPORT_ACTION) {
    const std::string* kind = args.FindString("kind");
    if (!kind)
      return Fail(error, SHAAR_INVALID_ARGUMENT, "invalid viewport action");
    if (*kind == "navigate") {
      if (!HasKeys(args, {"schemaVersion", "leaseID", "kind", "url"}))
        return Fail(error, SHAAR_INVALID_ARGUMENT, "invalid viewport navigation schema");
      const std::string* url = args.FindString("url");
      if (!url || url->size() > 8192 || !lease->NavigateAll(GURL(*url)))
        return Fail(error, SHAAR_INVALID_ARGUMENT, "invalid viewport URL");
    } else if (*kind == "safeArea") {
      if (!HasKeys(args, {"schemaVersion", "leaseID", "kind", "viewportID",
                          "insets"}))
        return Fail(error, SHAAR_INVALID_ARGUMENT, "invalid safe-area schema");
      const auto id = args.FindInt("viewportID");
      const auto* insets = args.FindDict("insets");
      if (!id || *id <= 0 || !insets || !ValidInsets(*insets))
        return Fail(error, SHAAR_INVALID_ARGUMENT, "invalid safe-area insets");
      if (!lease->SetSafeArea(*id, *insets))
        return Fail(error, SHAAR_NOT_READY, "viewport safe area unavailable");
    } else if (*kind == "click") {
      if (!HasKeys(args, {"schemaVersion", "leaseID", "kind", "viewportID",
                          "x", "y"}))
        return Fail(error, SHAAR_INVALID_ARGUMENT, "invalid viewport click schema");
      const auto id = args.FindInt("viewportID");
      const auto x = args.FindInt("x");
      const auto y = args.FindInt("y");
      if (!id || !x || !y || *id <= 0 || !lease->Click(*id, *x, *y))
        return Fail(error, SHAAR_INVALID_ARGUMENT, "invalid viewport click");
    } else if (*kind == "scroll") {
      if (!HasKeys(args, {"schemaVersion", "leaseID", "kind", "viewportID",
                          "deltaX", "deltaY"}))
        return Fail(error, SHAAR_INVALID_ARGUMENT, "invalid viewport scroll schema");
      const auto id = args.FindInt("viewportID");
      const auto delta_x = args.FindInt("deltaX");
      const auto delta_y = args.FindInt("deltaY");
      if (!id || !delta_x || !delta_y || *id <= 0 ||
          !lease->Scroll(*id, *delta_x, *delta_y))
        return Fail(error, SHAAR_INVALID_ARGUMENT, "invalid viewport scroll");
    } else {
      return Fail(error, SHAAR_INVALID_ARGUMENT, "unknown viewport action");
    }
    Reply(target, R"({"schemaVersion":1})");
    return SHAAR_OK;
  }
  if (operation == SHAAR_OP_DEVTOOLS_VIEWPORT_FRAME) {
    if (!HasKeys(args, {"schemaVersion", "leaseID", "viewportID"}))
      return Fail(error, SHAAR_INVALID_ARGUMENT, "invalid viewport frame schema");
    const auto id = args.FindInt("viewportID");
    Viewport* viewport = id && *id > 0 ? lease->Find(*id) : nullptr;
    if (!viewport)
      return Fail(error, SHAAR_NOT_FOUND, "viewport not found");
    if (!viewport->Capture(target))
      return Fail(error, SHAAR_NOT_READY, "viewport frame not ready");
    return SHAAR_OK;
  }
  return Fail(error, SHAAR_INVALID_ARGUMENT, "unknown viewport operation");
}

}  // namespace shaar::devtools
