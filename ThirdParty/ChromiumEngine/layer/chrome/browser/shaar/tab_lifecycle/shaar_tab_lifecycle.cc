// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#include "chrome/browser/shaar/tab_lifecycle/shaar_tab_lifecycle.h"

#include <cstring>
#include <optional>
#include <string>
#include <utility>

#include "base/functional/bind.h"
#include "base/json/json_reader.h"
#include "base/json/json_writer.h"
#include "base/task/sequenced_task_runner.h"
#include "base/values.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/resource_coordinator/tab_lifecycle_unit.h"
#include "chrome/browser/shaar/engine/shaar_engine_context.h"
#include "chrome/browser/shaar/engine/shaar_event_bridge.h"
#include "components/performance_manager/public/decorators/page_live_state_decorator.h"
#include "components/performance_manager/public/performance_manager.h"
#include "content/public/browser/visibility.h"
#include "content/public/browser/web_contents.h"

namespace {

constexpr size_t kMaximumArgumentsBytes = 4096;

struct Identity {
  std::string profile_id;
  std::string session_id;
  std::string window_id;
  std::string tab_id;
};

struct Snapshot {
  const char* state = "active";
  const char* discard_reason = "";
  bool audible = false;
  bool capturing = false;
  bool auto_discardable = true;
};

struct ReplyContext {
  shaar_request_id request_id;
  shaar_reply_fn callback;
  void* context;
};

shaar_bytes Bytes(const std::string& value) {
  return {value.data(), value.size()};
}

shaar_error_code Fail(shaar_error* error,
                      shaar_error_code code,
                      const char* message) {
  if (error) {
    const uint32_t size = error->size;
    if (size >= offsetof(shaar_error, code) + sizeof(error->code))
      error->code = code;
    if (size >=
        offsetof(shaar_error, platform_code) + sizeof(error->platform_code))
      error->platform_code = 0;
    if (size >= offsetof(shaar_error, message) + sizeof(error->message))
      error->message = {message, std::strlen(message)};
  }
  return code;
}

using LifecycleUnit = resource_coordinator::TabLifecycleUnitSource::TabLifecycleUnit;

LifecycleUnit* UnitFor(content::WebContents* contents) {
  auto* external =
      resource_coordinator::TabLifecycleUnitExternal::FromWebContents(contents);
  if (!external)
    return nullptr;
  return static_cast<LifecycleUnit*>(external);
}

bool PageNodeReady(content::WebContents* contents) {
  if (!performance_manager::PerformanceManager::IsAvailable())
    return false;
  return performance_manager::PerformanceManager::GetPrimaryPageNodeForWebContents(
             contents)
      .get();
}

bool IsCapturing(content::WebContents* contents) {
  if (contents->IsBeingCaptured())
    return true;
  if (!PageNodeReady(contents))
    return false;
  if (performance_manager::PageLiveStateDecorator::IsCapturingVideo(contents))
    return true;
  if (performance_manager::PageLiveStateDecorator::IsCapturingAudio(contents))
    return true;
  if (performance_manager::PageLiveStateDecorator::IsCapturingWindow(contents))
    return true;
  if (performance_manager::PageLiveStateDecorator::IsCapturingDisplay(contents))
    return true;
  if (performance_manager::PageLiveStateDecorator::IsBeingMirrored(contents))
    return true;
  return false;
}

const char* ReasonName(mojom::LifecycleUnitDiscardReason reason) {
  switch (reason) {
    case mojom::LifecycleUnitDiscardReason::EXTERNAL:
      return "external";
    case mojom::LifecycleUnitDiscardReason::URGENT:
      return "urgent";
    case mojom::LifecycleUnitDiscardReason::PROACTIVE:
      return "proactive";
    case mojom::LifecycleUnitDiscardReason::SUGGESTED:
      return "suggested";
    case mojom::LifecycleUnitDiscardReason::FROZEN_WITH_GROWING_MEMORY:
      return "frozenWithGrowingMemory";
  }
  return "";
}

const char* StateName(mojom::LifecycleUnitState state, bool discarded) {
  if (discarded || state == mojom::LifecycleUnitState::DISCARDED)
    return "discarded";
  if (state == mojom::LifecycleUnitState::FROZEN)
    return "frozen";
  return "active";
}

Snapshot ReadSnapshot(content::WebContents* contents, const char* forced_state) {
  Snapshot snapshot;
  snapshot.audible = contents->IsCurrentlyAudible();
  snapshot.capturing = IsCapturing(contents);
  LifecycleUnit* unit = UnitFor(contents);
  if (!unit) {
    snapshot.state = forced_state ? forced_state : "active";
    snapshot.auto_discardable = true;
    return snapshot;
  }
  snapshot.auto_discardable = unit->IsAutoDiscardable();
  const bool discarded = contents->WasDiscarded() ||
                         unit->GetTabState() == mojom::LifecycleUnitState::DISCARDED;
  snapshot.state = forced_state ? forced_state
                                : StateName(unit->GetTabState(), discarded);
  if (snapshot.state && std::strcmp(snapshot.state, "discarded") == 0)
    snapshot.discard_reason = ReasonName(unit->GetDiscardReason());
  return snapshot;
}

std::string PayloadJSON(const Snapshot& snapshot) {
  base::DictValue payload;
  payload.Set("schemaVersion", 1);
  payload.Set("kind", "lifecycle");
  payload.Set("state", snapshot.state);
  payload.Set("discardReason", snapshot.discard_reason);
  payload.Set("audible", snapshot.audible);
  payload.Set("capturing", snapshot.capturing);
  payload.Set("autoDiscardable", snapshot.auto_discardable);
  std::string json;
  base::JSONWriter::Write(base::Value(std::move(payload)), &json);
  return json;
}

void DeliverReply(ReplyContext request,
                  shaar_error_code code,
                  std::string payload,
                  std::string message) {
  shaar_result result = {};
  result.size = sizeof(result);
  result.request_id = request.request_id;
  result.error.size = sizeof(result.error);
  result.error.code = code;
  result.error.platform_code = 0;
  result.error.message = {message.data(), message.size()};
  result.payload_json = {payload.data(), payload.size()};
  request.callback(request.context, &result);
}

void ReplyLater(ReplyContext request,
                shaar_error_code code,
                std::string payload,
                std::string message) {
  base::SequencedTaskRunner::GetCurrentDefault()->PostTask(
      FROM_HERE, base::BindOnce(&DeliverReply, request, code, std::move(payload),
                                std::move(message)));
}

void EmitLater(shaar_engine* engine, Identity identity, std::string payload) {
  base::SequencedTaskRunner::GetCurrentDefault()->PostTask(
      FROM_HERE,
      base::BindOnce(
          [](shaar_engine* engine, Identity identity, std::string payload) {
            if (!shaar::EngineIsLive(engine) || payload.empty())
              return;
            shaar::EmitEvent(engine, SHAAR_EVENT_TAB, Bytes(identity.profile_id),
                             Bytes(identity.session_id), Bytes(identity.window_id),
                             Bytes(identity.tab_id), Bytes(payload));
          },
          engine, std::move(identity), std::move(payload)));
}

bool AllowedKeys(const base::DictValue& dict, bool allow_reason) {
  for (const auto item : dict) {
    if (item.first == "schemaVersion")
      continue;
    if (allow_reason && item.first == "reason")
      continue;
    return false;
  }
  return true;
}

std::optional<base::DictValue> ParseArguments(shaar_bytes bytes) {
  if (!bytes.data || bytes.size == 0 || bytes.size > kMaximumArgumentsBytes)
    return std::nullopt;
  auto parsed = base::JSONReader::Read(
      std::string_view(bytes.data, bytes.size), base::JSON_PARSE_RFC);
  if (!parsed || !parsed->is_dict())
    return std::nullopt;
  return std::move(parsed->GetDict());
}

std::optional<mojom::LifecycleUnitDiscardReason> ParseReason(
    const base::DictValue& args) {
  const base::Value* value = args.Find("reason");
  if (!value)
    return mojom::LifecycleUnitDiscardReason::PROACTIVE;
  if (!value->is_string())
    return std::nullopt;
  const std::string& reason = value->GetString();
  if (reason == "external")
    return mojom::LifecycleUnitDiscardReason::EXTERNAL;
  if (reason == "urgent")
    return mojom::LifecycleUnitDiscardReason::URGENT;
  if (reason == "proactive")
    return mojom::LifecycleUnitDiscardReason::PROACTIVE;
  if (reason == "suggested")
    return mojom::LifecycleUnitDiscardReason::SUGGESTED;
  if (reason == "frozenWithGrowingMemory")
    return mojom::LifecycleUnitDiscardReason::FROZEN_WITH_GROWING_MEMORY;
  return std::nullopt;
}

shaar_error_code ResolveIdentity(shaar::ShaarEngineContext* context,
                                 shaar_engine* engine,
                                 shaar_scope scope,
                                 shaar_window* window,
                                 shaar_tab* tab,
                                 content::WebContents** contents,
                                 Identity* identity,
                                 const char** message) {
  if (!context || !context->browser_tabs || !engine || !window || !tab ||
      !contents || !identity) {
    *message = "tab lifecycle is missing its target";
    return SHAAR_INVALID_ARGUMENT;
  }
  *contents = context->browser_tabs->FindWebContents(engine, window, tab);
  if (!*contents) {
    *message = "tab is not registered";
    return SHAAR_NOT_FOUND;
  }
  identity->window_id =
      std::string(context->browser_tabs->WindowID(engine, window));
  identity->tab_id = std::string(context->browser_tabs->TabID(engine, window, tab));
  if (identity->window_id.empty() || identity->tab_id.empty()) {
    *message = "tab identity is unavailable";
    return SHAAR_NOT_FOUND;
  }
  if (scope.profile) {
    if (!context->profile_services) {
      *message = "profile services are unavailable";
      return SHAAR_NOT_READY;
    }
    Profile* profile =
        context->profile_services->ResolveProfile(engine, scope.profile);
    Profile* tab_profile =
        Profile::FromBrowserContext((*contents)->GetBrowserContext());
    if (!profile || profile->IsOffTheRecord() || profile != tab_profile) {
      *message = "tab is not in this profile";
      return SHAAR_WRONG_PROFILE;
    }
    identity->profile_id =
        std::string(context->profile_services->ProfileID(engine, scope.profile));
    return SHAAR_OK;
  }
  if (!context->private_sessions) {
    *message = "private sessions are unavailable";
    return SHAAR_NOT_READY;
  }
  Profile* parent = nullptr;
  Profile* otr = nullptr;
  std::string_view profile_id;
  std::string_view session_id;
  const bool resolved = context->private_sessions->Resolve(
      engine, scope.private_session, &parent, &otr, &profile_id, &session_id);
  if (!resolved || !otr || (*contents)->GetBrowserContext() != otr) {
    *message = "tab is not in this private session";
    return SHAAR_WRONG_SESSION;
  }
  identity->profile_id = std::string(profile_id);
  identity->session_id = std::string(session_id);
  return SHAAR_OK;
}

bool PageIsVisible(content::WebContents* contents) {
  return contents->GetVisibility() == content::Visibility::VISIBLE;
}

void UnfreezeIfHidden(content::WebContents* contents) {
  if (PageIsVisible(contents) || contents->WasDiscarded())
    return;
  contents->SetPageFrozen(false);
}

shaar_error_code DiscardTab(content::WebContents* contents,
                            mojom::LifecycleUnitDiscardReason reason,
                            LifecycleUnit* unit,
                            const char** message) {
  if (PageIsVisible(contents)) {
    *message = "visible tab stays awake";
    return SHAAR_POLICY_BLOCKED;
  }
  if (contents->WasDiscarded() ||
      unit->GetTabState() == mojom::LifecycleUnitState::DISCARDED) {
    return SHAAR_OK;
  }
  if (!unit->DiscardTab(reason, 0)) {
    *message = "Chromium refused to discard this tab";
    return SHAAR_POLICY_BLOCKED;
  }
  return SHAAR_OK;
}

shaar_error_code FreezeTab(content::WebContents* contents,
                           LifecycleUnit* unit,
                           const char** message) {
  if (PageIsVisible(contents)) {
    *message = "visible tab cannot be frozen";
    return SHAAR_POLICY_BLOCKED;
  }
  if (contents->WasDiscarded() ||
      unit->GetTabState() == mojom::LifecycleUnitState::DISCARDED) {
    return SHAAR_OK;
  }
  contents->SetPageFrozen(true);
  return SHAAR_OK;
}

}  // namespace

namespace shaar::tab_lifecycle {

void NoteDiscarded(shaar_engine* engine,
                   std::string_view profile_id,
                   std::string_view session_id,
                   std::string_view window_id,
                   std::string_view tab_id,
                   content::WebContents* contents) {
  if (!engine || !contents || profile_id.empty() || tab_id.empty())
    return;
  Identity identity;
  identity.profile_id = std::string(profile_id);
  identity.session_id = std::string(session_id);
  identity.window_id = std::string(window_id);
  identity.tab_id = std::string(tab_id);
  const std::string payload = PayloadJSON(ReadSnapshot(contents, "discarded"));
  EmitLater(engine, std::move(identity), payload);
}

}  // namespace shaar::tab_lifecycle

shaar_error_code HandleTabLifecycleOperation(
    shaar::ShaarEngineContext* context,
    shaar_engine* engine,
    shaar_scope scope,
    shaar_window* window,
    shaar_tab* tab,
    shaar_operation operation,
    shaar_bytes args_json,
    shaar_request_id request_id,
    shaar_reply_fn reply,
    void* reply_context,
    shaar_error* error) {
  if (!reply || !request_id)
    return Fail(error, SHAAR_INVALID_ARGUMENT, "tab lifecycle reply is missing");
  const char* message = "tab lifecycle failed";
  content::WebContents* contents = nullptr;
  Identity identity;
  const shaar_error_code scope_status = ResolveIdentity(
      context, engine, scope, window, tab, &contents, &identity, &message);
  if (scope_status != SHAAR_OK)
    return Fail(error, scope_status, message);

  LifecycleUnit* unit = UnitFor(contents);
  if (!unit)
    return Fail(error, SHAAR_UNSUPPORTED_CAPABILITY,
                "tab lifecycle is not running");

  auto args = ParseArguments(args_json);
  if (!args)
    return Fail(error, SHAAR_INVALID_ARGUMENT, "tab lifecycle arguments are invalid");
  const bool is_discard = operation == SHAAR_OP_TAB_DISCARD;
  if (!AllowedKeys(*args, is_discard))
    return Fail(error, SHAAR_INVALID_ARGUMENT, "tab lifecycle arguments are invalid");

  shaar_error_code status = SHAAR_OK;
  if (is_discard) {
    const auto reason = ParseReason(*args);
    if (!reason)
      return Fail(error, SHAAR_INVALID_ARGUMENT, "discard reason is invalid");
    status = DiscardTab(contents, *reason, unit, &message);
  } else if (operation == SHAAR_OP_TAB_FREEZE) {
    status = FreezeTab(contents, unit, &message);
  } else if (operation == SHAAR_OP_TAB_WAKE) {
    UnfreezeIfHidden(contents);
    unit->MaybeLoad();
  } else if (operation != SHAAR_OP_TAB_LIFECYCLE_GET) {
    return Fail(error, SHAAR_UNSUPPORTED_CAPABILITY,
                "tab lifecycle operation is unknown");
  }
  if (status != SHAAR_OK)
    return Fail(error, status, message);

  // Replace-path discard destroys the WebContents pointer captured above.
  // The lifecycle unit follows the contents Chromium kept.
  content::WebContents* current = unit->GetWebContents();
  if (!current)
    return Fail(error, SHAAR_NOT_FOUND, "tab is not registered");

  const char* forced_state = nullptr;
  if (is_discard)
    forced_state = "discarded";
  else if (operation == SHAAR_OP_TAB_FREEZE)
    forced_state = current->WasDiscarded() ? "discarded" : "frozen";
  else if (operation == SHAAR_OP_TAB_WAKE)
    forced_state = "active";

  // Discard notifies WasDiscarded, which posts the lifecycle event. Freeze
  // and wake post it here. Reading state only replies.
  const std::string payload = PayloadJSON(ReadSnapshot(current, forced_state));
  if (payload.empty())
    return Fail(error, SHAAR_IO_ERROR, "tab lifecycle state could not be written");
  if (operation == SHAAR_OP_TAB_FREEZE || operation == SHAAR_OP_TAB_WAKE)
    EmitLater(engine, identity, payload);
  ReplyLater(ReplyContext{request_id, reply, reply_context}, SHAAR_OK, payload,
             std::string());
  return SHAAR_OK;
}

extern "C" void shaar_tab_lifecycle_register(ShaarModuleRegistry* registry) {
  if (!registry)
    return;
  registry->Register(SHAAR_OP_TAB_DISCARD, SHAAR_OP_TAB_LIFECYCLE_GET,
                     &HandleTabLifecycleOperation);
}
