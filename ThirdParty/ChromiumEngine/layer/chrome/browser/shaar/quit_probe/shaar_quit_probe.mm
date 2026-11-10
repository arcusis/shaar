// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#include "chrome/browser/shaar/quit_probe/shaar_quit_probe.h"

#include <cstddef>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <string>
#include <utility>
#include <vector>

#include "base/files/file_path.h"
#include "base/files/file_util.h"
#include "base/functional/bind.h"
#include "base/functional/callback_helpers.h"
#include "base/memory/ref_counted.h"
#include "base/memory/scoped_refptr.h"
#include "base/memory/weak_ptr.h"
#include "base/task/sequenced_task_runner.h"
#include "base/time/time.h"
#include "base/timer/timer.h"
#include "chrome/browser/lifetime/browser_shutdown.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/shaar/devtools/shaar_devtools.h"
#include "chrome/browser/shaar/engine/shaar_engine_context.h"
#include "chrome/browser/shaar/engine/shaar_event_bridge.h"
#include "chrome/browser/shaar/lifecycle/shaar_lifecycle.h"
#include "chrome/browser/shaar/windows_tabs/shaar_windows_tabs.h"
#include "content/browser/renderer_host/render_widget_host_impl.h"
#include "content/public/browser/browser_context.h"
#include "content/public/browser/javascript_dialog_manager.h"
#include "content/public/browser/render_frame_host.h"
#include "content/public/browser/render_widget_host.h"
#include "content/public/browser/render_widget_host_view.h"
#include "content/public/browser/web_contents.h"
#include "content/public/browser/web_contents_delegate.h"
#include "content/public/browser/web_contents_observer.h"
#include "third_party/blink/public/common/input/web_input_event.h"
#include "third_party/blink/public/common/input/web_mouse_event.h"
#include "third_party/blink/public/mojom/frame/user_activation_notification_type.mojom.h"
#include "ui/gfx/geometry/point_f.h"
#include "ui/gfx/image/image.h"
#include "url/gurl.h"

#import <AppKit/AppKit.h>
#include <pthread.h>

namespace {

// Chromium drops mouse down while first-paint commit deferral is set.
// That deferral lifts only when a main frame runs after 500ms.
constexpr base::TimeDelta kProbeClickCommitDelay = base::Milliseconds(600);
constexpr base::TimeDelta kProbeClickLeaseHold = base::Milliseconds(50);
constexpr base::TimeDelta kProbeCaptureTimeout = base::Seconds(12);

struct ReplyContext {
  shaar_request_id request_id;
  shaar_reply_fn reply;
  void* context;
};

class HoldLifetime final : public content::WebContentsObserver {
 public:
  HoldLifetime(shaar_engine* engine, shaar_tab* tab, content::WebContents* contents)
      : content::WebContentsObserver(contents), engine_(engine), tab_(tab) {}

  void WebContentsDestroyed() override;

 private:
  shaar_engine* engine_;
  shaar_tab* tab_;
};

struct HoldState {
  shaar_engine* engine = nullptr;
  shaar_window* window = nullptr;
  shaar_tab* tab = nullptr;
  bool command_pending = false;
  bool confirmed_pending = false;
  std::unique_ptr<HoldLifetime> lifetime;
};

void DeleteHoldLifetime(std::unique_ptr<HoldLifetime> observer) {
  observer.reset();
}

struct ResolvedTab {
  content::WebContents* contents = nullptr;
  bool private_tab = false;
  bool selected = false;
};

std::vector<HoldState>& Holds() {
  static std::vector<HoldState> holds;
  return holds;
}

thread_local std::string g_audit_json;

shaar_error_code Fail(shaar_error_code code, const char* message, shaar_error* error) {
  if (!error)
    return code;
  const uint32_t supplied_size = error->size;
  if (supplied_size >= offsetof(shaar_error, code) + sizeof(error->code))
    error->code = code;
  if (supplied_size >=
      offsetof(shaar_error, platform_code) + sizeof(error->platform_code))
    error->platform_code = 0;
  if (supplied_size >= offsetof(shaar_error, message) + sizeof(error->message))
    error->message = {message, std::strlen(message)};
  return code;
}

void DeliverReply(ReplyContext request, shaar_error_code code,
                  std::string payload, std::string message) {
  shaar_result result{};
  result.size = sizeof(result);
  result.request_id = request.request_id;
  result.error.size = sizeof(result.error);
  result.error.code = code;
  result.error.message = {message.data(), message.size()};
  result.payload_json = {payload.data(), payload.size()};
  if (request.reply)
    request.reply(request.context, &result);
}

void Reply(ReplyContext request, shaar_error_code code, std::string payload,
           std::string message = {}) {
  base::SequencedTaskRunner::GetCurrentDefault()->PostTask(
      FROM_HERE, base::BindOnce(&DeliverReply, request, code, std::move(payload),
                                std::move(message)));
}

bool TestingEnabled() {
  const char* testing = std::getenv("SHAAR_ENGINE_TESTING");
  return testing && std::strcmp(testing, "1") == 0;
}

bool MarkedProbeRoot(const shaar_engine* engine) {
  if (!engine)
    return false;
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

bool HostIsHidden(content::WebContents* contents) {
  if (!shaar::windows_tabs::HasHiddenNativeWindow(contents))
    return false;
  for (NSWindow* window in [NSApp windows]) {
    if (window.isVisible)
      return false;
  }
  return true;
}

ResolvedTab ResolveTab(shaar_engine* engine, shaar_scope scope,
                       shaar_window* window, shaar_tab* tab) {
  ResolvedTab resolved;
  if (!engine || !window || !tab || scope.size < sizeof(shaar_scope))
    return resolved;
  shaar::BrowserTabRegistry* tabs = shaar::EngineContext().browser_tabs;
  if (!tabs)
    return resolved;
  content::WebContents* contents = tabs->FindWebContents(engine, window, tab);
  if (!contents || !contents->GetBrowserContext())
    return resolved;
  const bool off_record = contents->GetBrowserContext()->IsOffTheRecord();
  if (scope.private_session || off_record) {
    resolved.contents = contents;
    resolved.private_tab = true;
    return resolved;
  }
  if (!scope.profile || !shaar::EngineContext().profile_services)
    return resolved;
  Profile* profile =
      shaar::EngineContext().profile_services->ResolveProfile(engine, scope.profile);
  if (!profile || profile->IsOffTheRecord() ||
      profile != Profile::FromBrowserContext(contents->GetBrowserContext()))
    return resolved;
  resolved.contents = contents;
  resolved.selected = tabs->IsSelectedWebContents(engine, window, tab, contents);
  return resolved;
}

shaar::quit_probe::TargetGate MakeTarget(bool hidden, const ResolvedTab& resolved) {
  shaar::quit_probe::TargetGate gate;
  gate.testing = TestingEnabled();
  gate.marked_probe = true;
  gate.target_present = resolved.contents != nullptr;
  gate.selected_regular = resolved.selected;
  gate.private_tab = resolved.private_tab;
  gate.hidden_host = hidden;
  return gate;
}

bool EngineAcceptsProbe(shaar_engine* engine, shaar_error* error) {
  if (!engine)
    return Fail(SHAAR_INVALID_ARGUMENT, "missing engine", error) == SHAAR_OK;
  if (!pthread_main_np())
    return Fail(SHAAR_INVALID_ARGUMENT, "main thread required", error) == SHAAR_OK;
  if (!shaar::EngineIsLive(engine) || !shaar::lifecycle::EngineIsReady(engine))
    return Fail(SHAAR_NOT_READY, "engine is not ready", error) == SHAAR_OK;
  if (!TestingEnabled())
    return Fail(SHAAR_POLICY_BLOCKED,
                shaar::quit_probe::RefusalMessage(shaar::quit_probe::ProbeRefusal::kNotTesting),
                error) == SHAAR_OK;
  if (!MarkedProbeRoot(engine))
    return Fail(SHAAR_POLICY_BLOCKED,
                shaar::quit_probe::RefusalMessage(shaar::quit_probe::ProbeRefusal::kForeignProbe),
                error) == SHAAR_OK;
  return true;
}

bool AcceptedRequest(shaar_request_id request_id, shaar_reply_fn reply, shaar_error* error) {
  if (!reply || !request_id)
    return Fail(SHAAR_INVALID_ARGUMENT, "missing quit probe reply", error) == SHAAR_OK;
  return true;
}

shaar_error_code Reported(const shaar_error* error) {
  if (error && error->code != SHAAR_OK)
    return error->code;
  return SHAAR_INVALID_ARGUMENT;
}

shaar_error_code Refuse(shaar::quit_probe::ProbeRefusal refusal, shaar_error* error) {
  shaar_error_code code = SHAAR_NOT_READY;
  if (refusal == shaar::quit_probe::ProbeRefusal::kNotTesting ||
      refusal == shaar::quit_probe::ProbeRefusal::kForeignProbe)
    code = SHAAR_POLICY_BLOCKED;
  return Fail(code, shaar::quit_probe::RefusalMessage(refusal), error);
}

HoldState* FindHold(shaar_engine* engine, shaar_tab* tab) {
  for (HoldState& hold : Holds()) {
    if (hold.engine == engine && hold.tab == tab)
      return &hold;
  }
  return nullptr;
}

void ArmHold(shaar_engine* engine, shaar_window* window, shaar_tab* tab,
             content::WebContents* contents) {
  if (HoldState* existing = FindHold(engine, tab)) {
    existing->window = window;
    existing->command_pending = true;
    existing->confirmed_pending = true;
    if (!existing->lifetime && contents)
      existing->lifetime = std::make_unique<HoldLifetime>(engine, tab, contents);
    return;
  }
  HoldState created;
  created.engine = engine;
  created.window = window;
  created.tab = tab;
  created.command_pending = true;
  created.confirmed_pending = true;
  if (contents)
    created.lifetime = std::make_unique<HoldLifetime>(engine, tab, contents);
  Holds().push_back(std::move(created));
}

void ClearHold(shaar_engine* engine, shaar_tab* tab) {
  std::vector<HoldState>& holds = Holds();
  for (auto it = holds.begin(); it != holds.end(); ++it) {
    if (it->engine == engine && it->tab == tab) {
      holds.erase(it);
      return;
    }
  }
}

void HoldLifetime::WebContentsDestroyed() {
  // Detach before the hold drops this observer. Deleting it on this stack
  // use-after-frees the WebContents observer list.
  Observe(nullptr);
  shaar_engine* engine = engine_;
  shaar_tab* tab = tab_;
  std::vector<HoldState>& holds = Holds();
  for (auto it = holds.begin(); it != holds.end(); ++it) {
    if (it->engine != engine || it->tab != tab)
      continue;
    std::unique_ptr<HoldLifetime> self = std::move(it->lifetime);
    holds.erase(it);
    base::SequencedTaskRunner::GetCurrentDefault()->PostTask(
        FROM_HERE, base::BindOnce(&DeleteHoldLifetime, std::move(self)));
    return;
  }
}

content::RenderWidgetHostImpl* ProbeWidget(content::WebContents* contents) {
  if (!contents)
    return nullptr;
  content::RenderWidgetHostView* view = contents->GetRenderWidgetHostView();
  if (!view || !view->GetRenderWidgetHost())
    return nullptr;
  content::RenderWidgetHostImpl* widget =
      content::RenderWidgetHostImpl::From(view->GetRenderWidgetHost());
  if (!widget || !widget->input_router())
    return nullptr;
  return widget;
}

bool PointInsideContents(content::WebContents* contents, int x, int y) {
  content::RenderWidgetHostView* view =
      contents ? contents->GetRenderWidgetHostView() : nullptr;
  if (!view)
    return false;
  const gfx::Size size = view->GetViewBounds().size();
  return shaar::quit_probe::PointInsideProbeView(x, y, size.width(), size.height());
}

void DispatchTrustedClick(content::RenderWidgetHost* widget, int x, int y) {
  const gfx::PointF point(x, y);
  const base::TimeTicks now = base::TimeTicks::Now();
  widget->ForwardMouseEvent(blink::WebMouseEvent(
      blink::WebInputEvent::Type::kMouseMove, point, point,
      blink::WebPointerProperties::Button::kNoButton, 0,
      blink::WebInputEvent::kNoModifiers, now));
  widget->ForwardMouseEvent(blink::WebMouseEvent(
      blink::WebInputEvent::Type::kMouseDown, point, point,
      blink::WebPointerProperties::Button::kLeft, 1,
      blink::WebInputEvent::kLeftButtonDown, now));
  widget->ForwardMouseEvent(blink::WebMouseEvent(
      blink::WebInputEvent::Type::kMouseUp, point, point,
      blink::WebPointerProperties::Button::kLeft, 1,
      blink::WebInputEvent::kNoModifiers, now));
}

void NotifyRendererActivation(content::WebContents* contents) {
  content::RenderFrameHost* frame = contents->GetPrimaryMainFrame();
  if (!frame || !frame->IsRenderFrameLive())
    return;
  frame->NotifyUserActivation(
      blink::mojom::UserActivationNotificationType::kInteraction);
}

class ProbeTrustedClick final : public base::RefCountedThreadSafe<ProbeTrustedClick> {
 public:
  ProbeTrustedClick(ReplyContext reply, int x, int y) : reply_(reply), x_(x), y_(y) {}

  void Start(content::WebContents* contents) {
    contents_ = contents->GetWeakPtr();
    capturer_ = shaar::devtools::StartHiddenProbeCapture(contents);
    if (!capturer_ || !Activate()) {
      FailClick();
      return;
    }
    timer_.Start(FROM_HERE, kProbeCaptureTimeout,
                 base::BindOnce(&ProbeTrustedClick::OnTimeout, base::WrapRefCounted(this)));
    base::SequencedTaskRunner::GetCurrentDefault()->PostDelayedTask(
        FROM_HERE,
        base::BindOnce(&ProbeTrustedClick::ForceFrame, base::WrapRefCounted(this)),
        kProbeClickCommitDelay);
  }

 private:
  friend class base::RefCountedThreadSafe<ProbeTrustedClick>;
  ~ProbeTrustedClick() = default;

  content::RenderWidgetHostImpl* Activate() {
    content::WebContents* contents = contents_.get();
    content::RenderWidgetHostImpl* widget = ProbeWidget(contents);
    if (!widget || !PointInsideContents(contents, x_, y_))
      return nullptr;
    widget->input_router()->MakeActive();
    return widget;
  }

  void ForceFrame() {
    if (finished_)
      return;
    content::RenderWidgetHostImpl* widget = Activate();
    if (!widget) {
      FailClick();
      return;
    }
    widget->GetSnapshotFromBrowser(
        base::BindOnce(&ProbeTrustedClick::OnFrame, base::WrapRefCounted(this)),
        /*from_surface=*/true);
  }

  void OnFrame(const gfx::Image&) {
    if (finished_)
      return;
    content::RenderWidgetHostImpl* widget = Activate();
    if (!widget) {
      FailClick();
      return;
    }
    content::WebContents* contents = contents_.get();
    if (contents)
      NotifyRendererActivation(contents);
    DispatchTrustedClick(widget, x_, y_);
    finished_ = true;
    timer_.Stop();
    Reply(reply_, SHAAR_OK, R"({"schemaVersion":1,"submitted":true})");
    base::SequencedTaskRunner::GetCurrentDefault()->PostDelayedTask(
        FROM_HERE,
        base::BindOnce(&ProbeTrustedClick::ReleaseLease, base::WrapRefCounted(this)),
        kProbeClickLeaseHold);
  }

  void OnTimeout() { FailClick(); }

  void FailClick() {
    if (finished_)
      return;
    finished_ = true;
    timer_.Stop();
    capturer_.RunAndReset();
    Reply(reply_, SHAAR_NOT_READY, {}, shaar::quit_probe::TrustedClickFailureMessage());
  }

  void ReleaseLease() { capturer_.RunAndReset(); }

  ReplyContext reply_;
  int x_;
  int y_;
  base::WeakPtr<content::WebContents> contents_;
  base::ScopedClosureRunner capturer_;
  base::OneShotTimer timer_;
  bool finished_ = false;
};

bool DismissQuitDialog(content::WebContents* contents) {
  content::WebContentsDelegate* delegate = contents ? contents->GetDelegate() : nullptr;
  if (!delegate)
    return false;
  content::JavaScriptDialogManager* manager = delegate->GetJavaScriptDialogManager(contents);
  if (!manager)
    return false;
  return manager->HandleJavaScriptDialog(contents, false, nullptr);
}

}  // namespace

extern "C" SHAAR_EXPORT shaar_error_code shaar_test_renderer_activate(
    shaar_engine* engine, shaar_scope scope, shaar_window* window, shaar_tab* tab,
    int x, int y, shaar_request_id request_id, shaar_reply_fn reply,
    void* reply_context, shaar_error* error) {
  if (!EngineAcceptsProbe(engine, error) || !AcceptedRequest(request_id, reply, error))
    return Reported(error);
  const ResolvedTab resolved = ResolveTab(engine, scope, window, tab);
  shaar::quit_probe::ActivateGate gate;
  gate.target = MakeTarget(HostIsHidden(resolved.contents), resolved);
  gate.point_inside = PointInsideContents(resolved.contents, x, y);
  const shaar::quit_probe::ProbeRefusal refusal = shaar::quit_probe::ActivationRefusal(gate);
  if (refusal != shaar::quit_probe::ProbeRefusal::kNone)
    return Refuse(refusal, error);
  NotifyRendererActivation(resolved.contents);
  base::MakeRefCounted<ProbeTrustedClick>(ReplyContext{request_id, reply, reply_context}, x, y)
      ->Start(resolved.contents);
  return Fail(SHAAR_OK, "", error);
}

extern "C" SHAAR_EXPORT shaar_error_code shaar_test_quit_dialog_prepare(
    shaar_engine* engine, shaar_scope scope, shaar_window* window, shaar_tab* tab,
    shaar_request_id request_id, shaar_reply_fn reply, void* reply_context,
    shaar_error* error) {
  if (!EngineAcceptsProbe(engine, error) || !AcceptedRequest(request_id, reply, error))
    return Reported(error);
  const ResolvedTab resolved = ResolveTab(engine, scope, window, tab);
  shaar::quit_probe::PrepareGate gate;
  gate.target = MakeTarget(HostIsHidden(resolved.contents), resolved);
  const GURL url = resolved.contents ? resolved.contents->GetLastCommittedURL() : GURL();
  gate.loopback = shaar::quit_probe::LoopbackHttpHost(url.scheme(), url.host());
  gate.trying_to_quit = browser_shutdown::IsTryingToQuit();
  const shaar::quit_probe::ProbeRefusal refusal = shaar::quit_probe::PrepareRefusal(gate);
  if (refusal != shaar::quit_probe::ProbeRefusal::kNone)
    return Refuse(refusal, error);
  ArmHold(engine, window, tab, resolved.contents);
  Reply({request_id, reply, reply_context}, SHAAR_OK,
        R"({"schemaVersion":1,"prepared":true})");
  return Fail(SHAAR_OK, "", error);
}

extern "C" SHAAR_EXPORT shaar_error_code shaar_test_quit_dialog_release(
    shaar_engine* engine, shaar_scope, shaar_window*, shaar_tab* tab,
    shaar_error* error) {
  if (!EngineAcceptsProbe(engine, error))
    return Reported(error);
  ClearHold(engine, tab);
  return Fail(SHAAR_OK, "", error);
}

extern "C" SHAAR_EXPORT shaar_error_code shaar_test_quit_dialog_cancel(
    shaar_engine* engine, shaar_scope scope, shaar_window* window, shaar_tab* tab,
    shaar_request_id request_id, shaar_reply_fn reply, void* reply_context,
    shaar_error* error) {
  if (!EngineAcceptsProbe(engine, error) || !AcceptedRequest(request_id, reply, error))
    return Reported(error);
  const ResolvedTab resolved = ResolveTab(engine, scope, window, tab);
  HoldState* hold = FindHold(engine, tab);
  shaar::quit_probe::CancelGate gate;
  gate.target = MakeTarget(HostIsHidden(resolved.contents), resolved);
  gate.trying_to_quit = browser_shutdown::IsTryingToQuit();
  gate.hold_present = hold != nullptr;
  gate.same_owner = hold && hold->window == window && hold->tab == tab;
  gate.dialog_handled = false;
  shaar::quit_probe::ProbeRefusal refusal = shaar::quit_probe::CancelRefusal(gate);
  if (refusal != shaar::quit_probe::ProbeRefusal::kNoDialog)
    return Refuse(refusal, error);
  gate.dialog_handled = DismissQuitDialog(resolved.contents);
  refusal = shaar::quit_probe::CancelRefusal(gate);
  if (shaar::quit_probe::CancelKeepsHold(refusal)) {
    Reply({request_id, reply, reply_context}, SHAAR_NOT_READY, {},
          shaar::quit_probe::RefusalMessage(refusal));
    return Fail(SHAAR_OK, "", error);
  }
  ClearHold(engine, tab);
  Reply({request_id, reply, reply_context}, SHAAR_OK,
        R"({"schemaVersion":1,"cancelled":true})");
  return Fail(SHAAR_OK, "", error);
}

extern "C" SHAAR_EXPORT shaar_error_code shaar_test_quit_dialog_audit(
    shaar_engine* engine, shaar_scope scope, shaar_window* window, shaar_tab* tab,
    shaar_bytes* out_json, shaar_error* error) {
  if (out_json)
    *out_json = {};
  if (!out_json)
    return Fail(SHAAR_INVALID_ARGUMENT, "missing quit probe audit", error);
  if (!EngineAcceptsProbe(engine, error))
    return Reported(error);
  const ResolvedTab resolved = ResolveTab(engine, scope, window, tab);
  HoldState* hold = FindHold(engine, tab);
  if (!hold || hold->window != window)
    return Fail(SHAAR_NOT_FOUND, shaar::quit_probe::RefusalMessage(
                                     shaar::quit_probe::ProbeRefusal::kNoHold),
                error);
  const bool selected = resolved.selected && !resolved.private_tab &&
                        resolved.contents != nullptr;
  g_audit_json = shaar::quit_probe::HoldAuditJSON(
      hold->command_pending, hold->confirmed_pending, selected);
  *out_json = {g_audit_json.data(), g_audit_json.size()};
  return Fail(SHAAR_OK, "", error);
}
