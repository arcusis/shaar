// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
#include "chrome/browser/shaar/devtools/shaar_devtools_panel.h"

#include <stddef.h>
#include <stdint.h>

#include <algorithm>
#include <climits>
#include <cstring>
#include <deque>
#include <map>
#include <memory>
#include <set>
#include <string>
#include <string_view>
#include <utility>

#include "base/containers/span.h"
#include "base/functional/bind.h"
#include "base/json/json_reader.h"
#include "base/json/json_writer.h"
#include "base/memory/weak_ptr.h"
#include "base/no_destructor.h"
#include "base/task/sequenced_task_runner.h"
#include "base/time/time.h"
#include "base/values.h"
#include "chrome/browser/shaar/engine/shaar_event_bridge.h"
#include "content/public/browser/devtools_agent_host.h"
#include "content/public/browser/devtools_agent_host_client.h"
#include "content/public/browser/navigation_handle.h"
#include "content/public/browser/web_contents.h"
#include "content/public/browser/web_contents_observer.h"

namespace shaar::devtools {
namespace {
constexpr size_t kMaxInputBytes = 1200 * 1024;
constexpr size_t kMaxEventInputBytes = 256 * 1024;
constexpr size_t kMaxFieldBytes = 4 * 1024;
constexpr size_t kMaxEventBytes = 32 * 1024;
constexpr size_t kMaxFrameBytes = 384 * 1024;
constexpr size_t kMaxFrameBase64Bytes = 340 * 1024;
constexpr size_t kMaxBodyBytes = 1024 * 1024;
constexpr size_t kMaxQueuedEvents = 256;
constexpr size_t kMaxQueuedBytes = 2 * 1024 * 1024;
constexpr size_t kMaxRequestIDs = 512;
constexpr size_t kMaxPendingBodies = 16;

struct ReplyTarget {
  shaar_request_id id;
  shaar_reply_fn callback;
  void* context;
};

constexpr char kReproMaskCSS[] =
    "input,textarea,select,option,[contenteditable],[contenteditable] *"
    "{color:transparent!important;-webkit-text-security:disc!important;"
    "text-shadow:none!important}input::placeholder,textarea::placeholder"
    "{color:transparent!important}";

std::string MaskExpression(bool install) {
  std::string quoted;
  base::JSONWriter::Write(base::Value(std::string(kReproMaskCSS)), &quoted);
  if (install) {
    return "(() => { let s=document.getElementById('shaar-repro-mask');"
           "if(!s){s=document.createElement('style');s.id='shaar-repro-mask';"
           "document.documentElement.appendChild(s)}s.textContent=" + quoted +
           ";return new Promise(resolve=>requestAnimationFrame(()=>"
           "requestAnimationFrame(()=>resolve(!!s.sheet))))})()";
  }
  return "(() => {const s=document.getElementById('shaar-repro-mask');"
         "if(!s||!s.isConnected||!s.sheet||s.textContent!==" + quoted +
         ")return false;const all=document.querySelectorAll('*');"
         "if(all.length>2000)return false;for(const e of all){"
         "if(e.localName.includes('-'))return false;"
         "if(!e.matches('input,textarea,select,option,[contenteditable],"
         "[contenteditable] *'))continue;"
         "const c=getComputedStyle(e).color;"
         "if(c!=='rgba(0, 0, 0, 0)'&&c!=='transparent')return false;}"
         "return true})()";
}

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

bool HasKeys(const base::DictValue& value,
             std::initializer_list<std::string_view> expected) {
  if (value.size() != expected.size())
    return false;
  for (const auto item : value) {
    if (std::find(expected.begin(), expected.end(), item.first) == expected.end())
      return false;
  }
  return true;
}

std::string Clipped(const std::string* source, bool* truncated) {
  if (!source)
    return {};
  if (source->size() <= kMaxFieldBytes)
    return *source;
  *truncated = true;
  std::string result = source->substr(0, kMaxFieldBytes);
  while (!result.empty() &&
         (static_cast<unsigned char>(result.back()) & 0xc0) == 0x80)
    result.pop_back();
  return result;
}

void PutString(base::DictValue* output, std::string_view key,
               const std::string* value, bool* truncated) {
  if (value)
    output->Set(key, Clipped(value, truncated));
}

std::string ConsoleText(const base::ListValue* args, bool* truncated) {
  std::string text;
  if (!args)
    return text;
  size_t count = 0;
  for (const auto& arg : *args) {
    if (++count > 8) {
      *truncated = true;
      break;
    }
    if (!arg.is_dict())
      continue;
    const auto& object = arg.GetDict();
    std::string piece;
    if (const auto* description = object.FindString("description")) {
      piece = *description;
    } else if (const auto* value = object.Find("value")) {
      if (value->is_string())
        piece = value->GetString();
      else if (value->is_int())
        piece = std::to_string(value->GetInt());
      else if (value->is_double())
        piece = std::to_string(value->GetDouble());
      else if (value->is_bool())
        piece = value->GetBool() ? "true" : "false";
    }
    if (piece.empty())
      continue;
    if (!text.empty())
      text += ' ';
    text += piece;
    if (text.size() > kMaxFieldBytes) {
      text = Clipped(&text, truncated);
      break;
    }
  }
  return text;
}

struct Projection {
  shaar_devtools_panel_event_id id;
  base::DictValue data;
  bool truncated = false;
};

// Only these fixed protocol notifications can cross the ABI. Each projection
// copies named scalar fields; headers, cookies, post data and protocol JSON
// never enter the event envelope.
bool Project(std::string_view method, const base::DictValue& params,
             Projection* result) {
  auto& data = result->data;
  if (method.starts_with("Network.")) {
    const auto* request_id = params.FindString("requestId");
    if (!request_id || request_id->empty() || request_id->size() > 128)
      return false;
  }
  if (method == "Runtime.consoleAPICalled") {
    result->id = SHAAR_DEVTOOLS_PANEL_CONSOLE_API_CALLED;
    PutString(&data, "level", params.FindString("type"), &result->truncated);
    data.Set("text", ConsoleText(params.FindList("args"), &result->truncated));
  } else if (method == "Runtime.exceptionThrown") {
    result->id = SHAAR_DEVTOOLS_PANEL_EXCEPTION_THROWN;
    const auto* detail = params.FindDict("exceptionDetails");
    PutString(&data, "text", detail ? detail->FindString("text") : nullptr,
              &result->truncated);
  } else if (method == "Log.entryAdded") {
    result->id = SHAAR_DEVTOOLS_PANEL_LOG_ENTRY_ADDED;
    const auto* entry = params.FindDict("entry");
    PutString(&data, "text", entry ? entry->FindString("text") : nullptr,
              &result->truncated);
    PutString(&data, "level", entry ? entry->FindString("level") : nullptr,
              &result->truncated);
  } else if (method == "Network.requestWillBeSent") {
    result->id = SHAAR_DEVTOOLS_PANEL_REQUEST_WILL_BE_SENT;
    const auto* request = params.FindDict("request");
    PutString(&data, "requestID", params.FindString("requestId"),
              &result->truncated);
    PutString(&data, "url", request ? request->FindString("url") : nullptr,
              &result->truncated);
    PutString(&data, "method", request ? request->FindString("method") : nullptr,
              &result->truncated);
  } else if (method == "Network.webSocketCreated") {
    result->id = SHAAR_DEVTOOLS_PANEL_WEB_SOCKET_CREATED;
    PutString(&data, "requestID", params.FindString("requestId"),
              &result->truncated);
    PutString(&data, "url", params.FindString("url"), &result->truncated);
  } else if (method == "Network.webSocketHandshakeResponseReceived") {
    result->id = SHAAR_DEVTOOLS_PANEL_WEB_SOCKET_HANDSHAKE;
    const auto* response = params.FindDict("response");
    PutString(&data, "requestID", params.FindString("requestId"),
              &result->truncated);
    if (response) {
      if (auto status = response->FindInt("status"))
        data.Set("status", *status);
    }
  } else if (method == "Network.webSocketFrameSent" ||
             method == "Network.webSocketFrameReceived") {
    result->id = method == "Network.webSocketFrameSent"
                     ? SHAAR_DEVTOOLS_PANEL_WEB_SOCKET_FRAME_SENT
                     : SHAAR_DEVTOOLS_PANEL_WEB_SOCKET_FRAME_RECEIVED;
    const auto* response = params.FindDict("response");
    PutString(&data, "requestID", params.FindString("requestId"),
              &result->truncated);
    if (response) {
      if (auto opcode = response->FindInt("opcode"))
        data.Set("opcode", *opcode);
      PutString(&data, "payload", response->FindString("payloadData"),
                &result->truncated);
    }
  } else if (method == "Network.webSocketClosed") {
    result->id = SHAAR_DEVTOOLS_PANEL_WEB_SOCKET_CLOSED;
    PutString(&data, "requestID", params.FindString("requestId"),
              &result->truncated);
  } else if (method == "Network.responseReceived") {
    result->id = SHAAR_DEVTOOLS_PANEL_RESPONSE_RECEIVED;
    const auto* response = params.FindDict("response");
    PutString(&data, "requestID", params.FindString("requestId"),
              &result->truncated);
    PutString(&data, "url", response ? response->FindString("url") : nullptr,
              &result->truncated);
    PutString(&data, "mimeType", response ? response->FindString("mimeType") : nullptr,
              &result->truncated);
    if (response) {
      if (auto status = response->FindInt("status"))
        data.Set("status", *status);
      else if (auto status = response->FindDouble("status"))
        data.Set("status", *status);
    }
  } else if (method == "Network.loadingFinished" ||
             method == "Network.loadingFailed" ||
             method == "Network.dataReceived") {
    result->id = method == "Network.loadingFinished"
                     ? SHAAR_DEVTOOLS_PANEL_LOADING_FINISHED
                     : method == "Network.loadingFailed"
                           ? SHAAR_DEVTOOLS_PANEL_LOADING_FAILED
                           : SHAAR_DEVTOOLS_PANEL_DATA_RECEIVED;
    PutString(&data, "requestID", params.FindString("requestId"),
              &result->truncated);
    if (method == "Network.loadingFailed")
      PutString(&data, "text", params.FindString("errorText"),
                &result->truncated);
    if (auto bytes = params.FindDouble("encodedDataLength"))
      data.Set("encodedBytes", *bytes);
  } else if (method == "Page.lifecycleEvent") {
    result->id = SHAAR_DEVTOOLS_PANEL_PAGE_LIFECYCLE;
    PutString(&data, "name", params.FindString("name"), &result->truncated);
  } else if (method == "Performance.metrics") {
    result->id = SHAAR_DEVTOOLS_PANEL_PERFORMANCE_METRICS;
    base::ListValue metrics;
    const auto* source = params.FindList("metrics");
    if (source) {
      for (const auto& item : *source) {
        if (!item.is_dict() || metrics.size() == 32) {
          result->truncated = true;
          break;
        }
        const auto& metric = item.GetDict();
        const auto* name = metric.FindString("name");
        auto value = metric.FindDouble("value");
        if (!name || !value)
          continue;
        base::DictValue copy;
        PutString(&copy, "name", name, &result->truncated);
        copy.Set("value", *value);
        metrics.Append(std::move(copy));
      }
    }
    data.Set("metrics", std::move(metrics));
  } else {
    return false;
  }
  data.Set("truncated", result->truncated);
  return true;
}

bool EncodeProjectedEvent(Projection projection, int lease_id,
                          std::string* output) {
  const size_t limit = projection.id == SHAAR_DEVTOOLS_PANEL_SCREENCAST_FRAME
                           ? kMaxFrameBytes : kMaxEventBytes;
  base::DictValue envelope;
  envelope.Set("schemaVersion", 1);
  envelope.Set("kind", "panelEvent");
  envelope.Set("eventID", static_cast<int>(projection.id));
  envelope.Set("leaseID", lease_id);
  envelope.Set("data", std::move(projection.data));
  return base::JSONWriter::Write(base::Value(std::move(envelope)), output) &&
         output->size() <= limit;
}

class PanelClient;
std::map<content::WebContents*, PanelClient*>& Leases() {
  static base::NoDestructor<std::map<content::WebContents*, PanelClient*>> leases;
  return *leases;
}
int& NextLeaseID() {
  static int next = 1;
  return next;
}

class PanelClient final : public content::DevToolsAgentHostClient,
                          public content::WebContentsObserver {
 public:
  PanelClient(shaar_engine* engine, shaar_scope scope, shaar_window* window,
              shaar_tab* tab, content::WebContents* contents,
              DevToolsTargetIdentity identity,
              scoped_refptr<content::DevToolsAgentHost> host, int lease_id)
      : content::WebContentsObserver(contents), engine_(engine), scope_(scope),
        window_(window), tab_(tab), contents_(contents),
        identity_(std::move(identity)), host_(std::move(host)),
        lease_id_(lease_id) {}

  bool Attach() {
    attached_ = host_->AttachClient(this);
    if (!attached_)
      return false;
    const char* commands[] = {
        R"({"id":-1,"method":"Runtime.enable"})",
        R"({"id":-2,"method":"Log.enable"})",
        R"({"id":-3,"method":"Network.enable"})",
        R"({"id":-4,"method":"Page.enable"})",
        R"({"id":-5,"method":"Page.setLifecycleEventsEnabled","params":{"enabled":true}})",
        R"({"id":-6,"method":"Performance.enable"})"};
    for (const char* command : commands)
      host_->DispatchProtocolMessage(this, base::as_byte_span(std::string_view(command)));
    return true;
  }

  ~PanelClient() override {
    if (attached_)
      host_->DetachClient(this);
  }

  int lease_id() const { return lease_id_; }
  shaar_engine* engine() const { return engine_; }
  void Activate() {
    ready_ = true;
    ScheduleFlush();
  }
  const DevToolsTargetIdentity& identity() const { return identity_; }
  bool Matches(shaar_engine* engine, const DevToolsTargetIdentity& identity) const {
    return engine_ == engine && identity_.profile_id == identity.profile_id &&
           identity_.session_id == identity.session_id &&
           identity_.window_id == identity.window_id &&
           identity_.tab_id == identity.tab_id;
  }

  void Close() {
    if (closing_)
      return;
    closing_ = true;
    StopScreencast();
    Leases().erase(contents_);
    auto pending = std::move(pending_bodies_);
    queue_.clear();
    queued_bytes_ = 0;
    for (auto& entry : pending)
      Reply(entry.second, SHAAR_CANCELLED, {}, "DevTools panel lease closed");
    delete this;
  }

  shaar_error_code GetBody(const std::string& request_id, ReplyTarget reply,
                           shaar_error* error) {
    if (!known_requests_.contains(request_id))
      return Fail(error, SHAAR_NOT_FOUND, "unknown panel request ID");
    if (pending_bodies_.size() >= kMaxPendingBodies)
      return Fail(error, SHAAR_NOT_READY, "too many pending response bodies");
    if (next_command_id_ == INT_MAX)
      return Fail(error, SHAAR_NOT_READY, "panel command IDs exhausted");
    const int command_id = next_command_id_++;
    base::DictValue params;
    params.Set("requestId", request_id);
    base::DictValue command;
    command.Set("id", command_id);
    command.Set("method", "Network.getResponseBody");
    command.Set("params", std::move(params));
    std::string json;
    if (!base::JSONWriter::Write(base::Value(std::move(command)), &json))
      return Fail(error, SHAAR_INVALID_ARGUMENT, "invalid body request");
    pending_bodies_.emplace(command_id, reply);
    base::SequencedTaskRunner::GetCurrentDefault()->PostDelayedTask(
        FROM_HERE, base::BindOnce(&PanelClient::BodyTimedOut,
                                  weak_factory_.GetWeakPtr(), command_id),
        base::Seconds(15));
    host_->DispatchProtocolMessage(this, base::as_byte_span(json));
    return SHAAR_OK;
  }

  shaar_error_code ControlScreencast(int command, int session,
                                    ReplyTarget reply, shaar_error* error) {
    if (command == SHAAR_DEVTOOLS_SCREENCAST_START) {
      if (recording_ || pending_start_)
        return Fail(error, SHAAR_CONFLICT, "screencast already started");
      pending_start_ = std::make_unique<ReplyTarget>(reply);
      recording_ = true;
      base::DictValue params;
      params.Set("expression", MaskExpression(true));
      params.Set("returnByValue", true);
      params.Set("awaitPromise", true);
      mask_setup_id_ = SendCommand("Runtime.evaluate", std::move(params));
      if (mask_setup_id_ != 0) {
        base::SequencedTaskRunner::GetCurrentDefault()->PostDelayedTask(
            FROM_HERE, base::BindOnce(&PanelClient::MaskStartTimedOut,
                                      weak_factory_.GetWeakPtr(), mask_setup_id_),
            base::Seconds(3));
        return SHAAR_OK;
      }
      pending_start_.reset();
      recording_ = false;
      return Fail(error, SHAAR_NOT_READY, "screencast command unavailable");
    }
    if (command == SHAAR_DEVTOOLS_SCREENCAST_STOP) {
      StopScreencast();
      Reply(reply, SHAAR_OK, R"({"schemaVersion":1})");
      return SHAAR_OK;
    }
    if (command == SHAAR_DEVTOOLS_SCREENCAST_ACK && session > 0 &&
        session == awaiting_ack_) {
      SendAck(session);
      awaiting_ack_ = 0;
      Reply(reply, SHAAR_OK, R"({"schemaVersion":1})");
      return SHAAR_OK;
    }
    return Fail(error, SHAAR_INVALID_ARGUMENT, "invalid screencast command");
  }

  void DispatchProtocolMessage(content::DevToolsAgentHost*,
                               base::span<const uint8_t> message) override {
    if (closing_)
      return;
    if (message.size() > kMaxInputBytes) {
      Drop();
      return;
    }
    const std::string_view input(reinterpret_cast<const char*>(message.data()),
                                 message.size());
    auto parsed = base::JSONReader::Read(input, base::JSON_PARSE_RFC);
    if (!parsed || !parsed->is_dict())
      return;
    const auto& root = parsed->GetDict();
    if (auto id = root.FindInt("id")) {
      if (*id == mask_setup_id_) {
        mask_setup_id_ = 0;
        if (!BooleanResult(root)) {
          FailStart();
          return;
        }
        mask_ready_ = true;
        base::DictValue params;
        params.Set("format", "jpeg");
        params.Set("quality", 40);
        params.Set("maxWidth", 1280);
        params.Set("maxHeight", 720);
        params.Set("everyNthFrame", 12);
        params.Set("maxFramesInFlight", 1);
        start_command_id_ = SendCommand("Page.startScreencast", std::move(params));
        if (!start_command_id_)
          FailStart();
        return;
      }
      if (*id == start_command_id_) {
        start_command_id_ = 0;
        if (root.FindDict("error")) {
          FailStart();
        } else if (pending_start_) {
          Reply(*pending_start_, SHAAR_OK, R"({"schemaVersion":1})");
          pending_start_.reset();
        }
        return;
      }
      if (*id == frame_mask_id_) {
        frame_mask_id_ = 0;
        ConfirmFrame(BooleanResult(root));
        return;
      }
      auto found = pending_bodies_.find(*id);
      if (found == pending_bodies_.end())
        return;
      const ReplyTarget target = found->second;
      pending_bodies_.erase(found);
      const auto* result = root.FindDict("result");
      const auto* body = result ? result->FindString("body") : nullptr;
      if (!body || body->size() > kMaxBodyBytes || root.FindDict("error")) {
        Reply(target, SHAAR_CHROMIUM_ERROR, {}, "response body unavailable or too large");
        return;
      }
      base::DictValue output;
      output.Set("schemaVersion", 1);
      output.Set("body", *body);
      output.Set("base64Encoded", result->FindBool("base64Encoded").value_or(false));
      std::string json;
      base::JSONWriter::Write(base::Value(std::move(output)), &json);
      Reply(target, SHAAR_OK, std::move(json));
      return;
    }
    const auto* method = root.FindString("method");
    const auto* params = root.FindDict("params");
    if (!method || !params)
      return;
    if (*method == "Page.screencastFrame") {
      HandleFrame(*params);
      return;
    }
    if (message.size() > kMaxEventInputBytes) {
      Drop();
      return;
    }
    Projection projection{};
    if (!Project(*method, *params, &projection))
      return;
    if (projection.id == SHAAR_DEVTOOLS_PANEL_REQUEST_WILL_BE_SENT) {
      const auto* request_id = params->FindString("requestId");
      if (request_id && request_id->size() <= 128 &&
          known_requests_.insert(*request_id).second) {
        request_order_.push_back(*request_id);
        if (request_order_.size() > kMaxRequestIDs) {
          known_requests_.erase(request_order_.front());
          request_order_.pop_front();
        }
      }
    }
    Enqueue(std::move(projection));
  }

  void AgentHostClosed(content::DevToolsAgentHost*) override {
    attached_ = false;
    Close();
  }
  void WebContentsDestroyed() override { Close(); }
  void DidFinishNavigation(content::NavigationHandle* navigation) override {
    if (navigation->HasCommitted() && navigation->IsInPrimaryMainFrame() &&
        !navigation->IsSameDocument())
      Close();
  }

 private:
  void MaskStartTimedOut(int command_id) {
    if (mask_setup_id_ == command_id)
      FailStart();
  }

  struct PendingFrame {
    std::string jpeg_base64;
    int session_id;
  };

  static bool BooleanResult(const base::DictValue& root) {
    if (root.FindDict("error"))
      return false;
    const auto* result = root.FindDict("result");
    const auto* value = result ? result->FindDict("result") : nullptr;
    return value && value->FindBool("value") == true;
  }

  int SendCommand(std::string_view method, base::DictValue params) {
    if (next_command_id_ == INT_MAX)
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

  void SendAck(int session_id) {
    base::DictValue params;
    params.Set("sessionId", session_id);
    SendCommand("Page.screencastFrameAck", std::move(params));
  }

  void StopScreencast() {
    if (!recording_)
      return;
    recording_ = false;
    mask_ready_ = false;
    pending_frame_.reset();
    mask_setup_id_ = 0;
    start_command_id_ = 0;
    frame_mask_id_ = 0;
    awaiting_ack_ = 0;
    if (pending_start_) {
      Reply(*pending_start_, SHAAR_CANCELLED, {}, "screencast stopped");
      pending_start_.reset();
    }
    SendCommand("Page.stopScreencast", base::DictValue());
    base::DictValue params;
    params.Set("expression",
               "document.getElementById('shaar-repro-mask')?.remove()");
    SendCommand("Runtime.evaluate", std::move(params));
  }

  void FailStart() {
    auto pending = std::move(pending_start_);
    pending_start_.reset();
    StopScreencast();
    if (pending)
      Reply(*pending, SHAAR_NOT_READY, {}, "screencast mask unavailable");
  }

  void HandleFrame(const base::DictValue& params) {
    const auto session = params.FindInt("sessionId");
    if (!session || *session <= 0)
      return;
    if (!recording_ || !mask_ready_ || pending_start_ || pending_frame_ ||
        awaiting_ack_ || frame_mask_id_ ||
        (!last_frame_time_.is_null() &&
         base::TimeTicks::Now() - last_frame_time_ < base::Milliseconds(200))) {
      SendAck(*session);
      return;
    }
    const auto* data = params.FindString("data");
    if (!data || data->empty() || data->size() > kMaxFrameBase64Bytes) {
      SendAck(*session);
      return;
    }
    pending_frame_ = std::make_unique<PendingFrame>(PendingFrame{*data, *session});
    base::DictValue check;
    check.Set("expression", MaskExpression(false));
    check.Set("returnByValue", true);
    frame_mask_id_ = SendCommand("Runtime.evaluate", std::move(check));
    if (!frame_mask_id_) {
      SendAck(*session);
      pending_frame_.reset();
      StopScreencast();
    } else {
      base::SequencedTaskRunner::GetCurrentDefault()->PostDelayedTask(
          FROM_HERE, base::BindOnce(&PanelClient::FrameMaskTimedOut,
                                    weak_factory_.GetWeakPtr(), frame_mask_id_),
          base::Seconds(1));
    }
  }

  void FrameMaskTimedOut(int command_id) {
    if (frame_mask_id_ != command_id)
      return;
    frame_mask_id_ = 0;
    ConfirmFrame(false);
  }

  void ConfirmFrame(bool mask_confirmed) {
    if (!pending_frame_)
      return;
    PendingFrame frame = std::move(*pending_frame_);
    pending_frame_.reset();
    if (!recording_ || !mask_confirmed) {
      SendAck(frame.session_id);
      StopScreencast();
      return;
    }
    Projection projection{};
    projection.id = SHAAR_DEVTOOLS_PANEL_SCREENCAST_FRAME;
    projection.data.Set("jpegBase64", std::move(frame.jpeg_base64));
    projection.data.Set("sessionID", frame.session_id);
    projection.data.Set("masked", true);
    projection.data.Set("truncated", false);
    if (Enqueue(std::move(projection))) {
      awaiting_ack_ = frame.session_id;
      last_frame_time_ = base::TimeTicks::Now();
    } else {
      SendAck(frame.session_id);
    }
  }

  void BodyTimedOut(int command_id) {
    auto found = pending_bodies_.find(command_id);
    if (found == pending_bodies_.end())
      return;
    const ReplyTarget target = found->second;
    pending_bodies_.erase(found);
    Reply(target, SHAAR_NOT_READY, {}, "response body timed out");
  }

  bool StillOwnsTarget() const {
    const auto& context = shaar::EngineContext();
    DevToolsTargetIdentity current;
    return context.devtools_runtime && context.browser_tabs &&
        context.browser_tabs->FindWebContents(engine_, window_, tab_) == contents_ &&
        context.devtools_runtime->ResolveTarget(engine_, scope_, window_, tab_,
                                                contents_, &current) &&
        Matches(engine_, current);
  }

  void Drop() {
    if (dropped_ != INT_MAX)
      ++dropped_;
  }

  bool Enqueue(Projection projection) {
    std::string payload;
    if (!EncodeProjectedEvent(std::move(projection), lease_id_, &payload) ||
        queue_.size() == kMaxQueuedEvents ||
        queued_bytes_ + payload.size() > kMaxQueuedBytes) {
      Drop();
      return false;
    }
    queued_bytes_ += payload.size();
    queue_.push_back(std::move(payload));
    ScheduleFlush();
    return true;
  }

  void ScheduleFlush() {
    if (!ready_ || flush_posted_ || queue_.empty())
      return;
    flush_posted_ = true;
    base::SequencedTaskRunner::GetCurrentDefault()->PostTask(
        FROM_HERE, base::BindOnce(&PanelClient::Flush,
                                  weak_factory_.GetWeakPtr()));
  }

  void Emit(const std::string& payload) {
    const shaar_bytes profile{identity_.profile_id.data(), identity_.profile_id.size()};
    const shaar_bytes session{identity_.session_id.data(), identity_.session_id.size()};
    const shaar_bytes window{identity_.window_id.data(), identity_.window_id.size()};
    const shaar_bytes tab{identity_.tab_id.data(), identity_.tab_id.size()};
    const shaar_bytes body{payload.data(), payload.size()};
    shaar::EmitEvent(engine_, SHAAR_EVENT_DEVTOOLS, profile, session, window,
                     tab, body);
  }

  void Flush() {
    flush_posted_ = false;
    if (!StillOwnsTarget()) {
      Close();
      return;
    }
    while (!queue_.empty()) {
      std::string payload = std::move(queue_.front());
      queue_.pop_front();
      queued_bytes_ -= payload.size();
      auto weak = weak_factory_.GetWeakPtr();
      Emit(payload);
      if (!weak)
        return;
    }
    if (dropped_) {
      Projection summary{};
      summary.id = SHAAR_DEVTOOLS_PANEL_EVENTS_DROPPED;
      summary.data.Set("count", static_cast<int>(dropped_));
      dropped_ = 0;
      Enqueue(std::move(summary));
    }
  }

  shaar_engine* engine_;
  shaar_scope scope_;
  shaar_window* window_;
  shaar_tab* tab_;
  content::WebContents* contents_;
  DevToolsTargetIdentity identity_;
  scoped_refptr<content::DevToolsAgentHost> host_;
  int lease_id_;
  int next_command_id_ = 1000000;
  bool attached_ = false;
  bool closing_ = false;
  bool ready_ = false;
  bool flush_posted_ = false;
  uint32_t dropped_ = 0;
  size_t queued_bytes_ = 0;
  std::deque<std::string> queue_;
  std::set<std::string> known_requests_;
  std::deque<std::string> request_order_;
  std::map<int, ReplyTarget> pending_bodies_;
  std::unique_ptr<ReplyTarget> pending_start_;
  std::unique_ptr<PendingFrame> pending_frame_;
  int mask_setup_id_ = 0;
  int start_command_id_ = 0;
  int frame_mask_id_ = 0;
  int awaiting_ack_ = 0;
  bool recording_ = false;
  bool mask_ready_ = false;
  base::TimeTicks last_frame_time_;
  base::WeakPtrFactory<PanelClient> weak_factory_{this};
};

}  // namespace

bool ProjectPanelEventForTesting(std::string_view message, int lease_id,
                                 std::string* output) {
  if (!output || lease_id <= 0 || message.size() > kMaxEventInputBytes)
    return false;
  auto parsed = base::JSONReader::Read(message, base::JSON_PARSE_RFC);
  if (!parsed || !parsed->is_dict())
    return false;
  const auto* method = parsed->GetDict().FindString("method");
  const auto* params = parsed->GetDict().FindDict("params");
  Projection projection{};
  return method && params && Project(*method, *params, &projection) &&
         EncodeProjectedEvent(std::move(projection), lease_id, output);
}

void ClosePanelLeaseForTab(content::WebContents* contents) {
  auto found = Leases().find(contents);
  if (found != Leases().end())
    found->second->Close();
}

void ClosePanelLeasesForEngine(shaar_engine* engine) {
  for (auto it = Leases().begin(); it != Leases().end();) {
    PanelClient* lease = it->second;
    ++it;
    if (lease->engine() == engine)
      lease->Close();
  }
}

shaar_error_code HandlePanelOperation(
    ShaarEngineContext* context, shaar_engine* engine, shaar_scope scope,
    shaar_window* window, shaar_tab* tab, content::WebContents* contents,
    const DevToolsTargetIdentity& identity, shaar_operation operation,
    shaar_bytes args_json, shaar_request_id request_id, shaar_reply_fn reply,
    void* reply_context, shaar_error* error) {
  if (!context || !context->devtools_runtime || !engine || !contents || !reply ||
      !args_json.data || args_json.size == 0 || args_json.size > 1024)
    return Fail(error, SHAAR_INVALID_ARGUMENT, "invalid panel request");
  auto parsed = base::JSONReader::Read(
      std::string_view(args_json.data, args_json.size), base::JSON_PARSE_RFC);
  if (!parsed || !parsed->is_dict() ||
      parsed->GetDict().FindInt("schemaVersion") != 1)
    return Fail(error, SHAAR_INVALID_ARGUMENT, "invalid panel schema");
  const auto& args = parsed->GetDict();
  ReplyTarget target{request_id, reply, reply_context};
  auto found = Leases().find(contents);
  PanelClient* lease = found == Leases().end() ? nullptr : found->second;
  if (operation == SHAAR_OP_DEVTOOLS_PANEL_OPEN) {
    if (!HasKeys(args, {"schemaVersion"}))
      return Fail(error, SHAAR_INVALID_ARGUMENT, "invalid panel open schema");
    if (lease && !lease->Matches(engine, identity))
      return Fail(error, SHAAR_CONFLICT, "panel target already leased");
    if (!lease) {
      if (NextLeaseID() == INT_MAX)
        return Fail(error, SHAAR_NOT_READY, "panel lease IDs exhausted");
      auto host = ProtocolAgentHostFor(contents);
      if (!host)
        return Fail(error, SHAAR_NOT_READY, "panel protocol target unavailable");
      const int id = NextLeaseID()++;
      auto owned = std::make_unique<PanelClient>(engine, scope, window, tab,
                                                   contents, identity, host, id);
      if (!owned->Attach())
        return Fail(error, SHAAR_NOT_READY, "panel protocol attach denied");
      lease = owned.release();
      Leases()[contents] = lease;
    }
    Reply(target, SHAAR_OK, "{\"schemaVersion\":1,\"leaseID\":" +
                                std::to_string(lease->lease_id()) + "}");
    lease->Activate();
    return SHAAR_OK;
  }
  const auto lease_id = args.FindInt("leaseID");
  if (!lease_id || *lease_id <= 0)
    return Fail(error, SHAAR_INVALID_ARGUMENT, "invalid panel lease ID");
  if (operation == SHAAR_OP_DEVTOOLS_PANEL_CLOSE) {
    if (!HasKeys(args, {"schemaVersion", "leaseID"}))
      return Fail(error, SHAAR_INVALID_ARGUMENT, "invalid panel close schema");
    if (lease && (!lease->Matches(engine, identity) ||
                  lease->lease_id() != *lease_id))
      return Fail(error, SHAAR_NOT_FOUND, "panel lease not found");
    if (lease)
      lease->Close();
    Reply(target, SHAAR_OK, "{\"schemaVersion\":1}");
    return SHAAR_OK;
  }
  if (operation == SHAAR_OP_DEVTOOLS_PANEL_GET_RESPONSE_BODY) {
    if (!HasKeys(args, {"schemaVersion", "leaseID", "requestID"}))
      return Fail(error, SHAAR_INVALID_ARGUMENT, "invalid response body schema");
    const auto* id = args.FindString("requestID");
    if (!id || id->empty() || id->size() > 128)
      return Fail(error, SHAAR_INVALID_ARGUMENT, "invalid response request ID");
    if (!lease || !lease->Matches(engine, identity) ||
        lease->lease_id() != *lease_id)
      return Fail(error, SHAAR_NOT_FOUND, "panel lease not found");
    return lease->GetBody(*id, target, error);
  }
  if (operation == SHAAR_OP_DEVTOOLS_PANEL_SCREENCAST) {
    const auto command = args.FindInt("commandID");
    if (!command || *command < SHAAR_DEVTOOLS_SCREENCAST_START ||
        *command > SHAAR_DEVTOOLS_SCREENCAST_ACK)
      return Fail(error, SHAAR_INVALID_ARGUMENT, "invalid screencast command ID");
    const auto session = args.FindInt("sessionID");
    if ((*command == SHAAR_DEVTOOLS_SCREENCAST_ACK &&
         (!session || *session <= 0 ||
          !HasKeys(args, {"schemaVersion", "leaseID", "commandID", "sessionID"}))) ||
        (*command != SHAAR_DEVTOOLS_SCREENCAST_ACK &&
         !HasKeys(args, {"schemaVersion", "leaseID", "commandID"})))
      return Fail(error, SHAAR_INVALID_ARGUMENT, "invalid screencast schema");
    if (!lease || !lease->Matches(engine, identity) ||
        lease->lease_id() != *lease_id)
      return Fail(error, SHAAR_NOT_FOUND, "panel lease not found");
    return lease->ControlScreencast(*command, session.value_or(0), target, error);
  }
  return Fail(error, SHAAR_INVALID_ARGUMENT, "unknown panel operation");
}

}  // namespace shaar::devtools
