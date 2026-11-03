// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#include "chrome/browser/shaar/private_sessions/shaar_private_sessions.h"
#include "chrome/browser/shaar/private_sessions/shaar_private_sessions_module.h"

#include <utility>

#include "base/check.h"
#include "base/strings/string_util.h"
#include "chrome/browser/shaar/engine/shaar_event_bridge.h"

namespace shaar {

PrivateSessionRegistry::PrivateSessionRegistry(EventSink event_sink)
    : event_sink_(std::move(event_sink)) {}
PrivateSessionRegistry::~PrivateSessionRegistry() {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  DCHECK(sessions_.empty());
}

shaar_error_code PrivateSessionRegistry::Open(
    Profile* parent,
    const std::string& profile_id,
    const std::string& session_id,
    Session** out) {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  if (!out)
    return SHAAR_INVALID_ARGUMENT;
  *out = nullptr;
  if (!parent || profile_id.empty() || session_id.empty() ||
      !base::IsStringUTF8(profile_id) || !base::IsStringUTF8(session_id))
    return SHAAR_INVALID_ARGUMENT;
  if (parent->IsOffTheRecord() || parent->GetOriginalProfile() != parent)
    return SHAAR_WRONG_PROFILE;

  auto found = sessions_.find(session_id);
  if (found != sessions_.end()) {
    Session& session = *found->second;
    if (session.parent != parent || session.profile_id != profile_id)
      return SHAAR_WRONG_PROFILE;
    if (session.closing)
      return SHAAR_CONFLICT;
    ++session.open_handles;
    *out = &session;
    return SHAAR_OK;
  }
  if (retired_ids_.contains(session_id))
    return SHAAR_CONFLICT;

  Profile* otr = parent->GetPrimaryOTRProfile(/*create_if_needed=*/true);
  if (!otr || !otr->IsOffTheRecord() || otr->GetOriginalProfile() != parent)
    return SHAAR_CHROMIUM_ERROR;

  auto session = std::make_unique<Session>();
  session->id = session_id;
  session->profile_id = profile_id;
  session->parent = parent;
  session->otr = otr;
  session->open_handles = 1;
  auto [parent_entry, new_parent] = parent_sessions_.try_emplace(parent);
  if (new_parent)
    parent->AddObserver(this);
  Session* handle = session.get();
  storage_.push_back(std::move(session));
  auto [inserted, ok] = sessions_.emplace(session_id, handle);
  CHECK(ok);
  parent_entry->second.insert(session_id);
  Emit(*inserted->second, EventState::kOpened);
  *out = inserted->second;
  return SHAAR_OK;
}

bool PrivateSessionRegistry::Close(Session* session) {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  if (!IsLive(session) || session->open_handles == 0)
    return false;
  --session->open_handles;
  if (session->open_handles == 0) {
    session->closing = true;
    Emit(*session, EventState::kClosing);
  }
  MaybeRetire(session);
  return true;
}

bool PrivateSessionRegistry::RetainChild(Session* session) {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  if (!IsLive(session) || session->closing)
    return false;
  ++session->children;
  return true;
}

bool PrivateSessionRegistry::ReleaseChild(Session* session) {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  if (!IsLive(session) || session->children == 0)
    return false;
  --session->children;
  MaybeRetire(session);
  return true;
}

void PrivateSessionRegistry::OnProfileWillBeDestroyed(Profile* profile) {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  auto parent = parent_sessions_.find(profile);
  if (parent == parent_sessions_.end())
    return;
  for (const std::string& session_id : parent->second) {
    auto session = sessions_.find(session_id);
    if (session == sessions_.end())
      continue;
    if (!session->second->closing)
      Emit(*session->second, EventState::kClosing);
    Emit(*session->second, EventState::kClosed);
    session->second->closing = true;
    session->second->open_handles = 0;
    retired_ids_.insert(session->first);
    session->second->parent = nullptr;
    session->second->otr = nullptr;
    sessions_.erase(session);
  }
  parent_sessions_.erase(parent);
}

PrivateSessionRegistry::Session* PrivateSessionRegistry::Find(
    Profile* parent,
    const std::string& session_id) const {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  auto found = sessions_.find(session_id);
  if (found == sessions_.end() || found->second->closing ||
      found->second->parent != parent) {
    return nullptr;
  }
  return found->second;
}

bool PrivateSessionRegistry::IsLive(const Session* session) const {
  if (!session)
    return false;
  for (const auto& entry : sessions_) {
    if (entry.second == session)
      return true;
  }
  return false;
}

void PrivateSessionRegistry::Emit(const Session& session, EventState state) {
  if (event_sink_)
    event_sink_(session.profile_id, session.id, state);
}

void PrivateSessionRegistry::MaybeRetire(Session* session) {
  if (!session->closing || session->open_handles != 0 || session->children != 0)
    return;
  Emit(*session, EventState::kClosed);
  retired_ids_.insert(session->id);
  Profile* parent = session->parent;
  Profile* otr = session->otr;
  auto parent_sessions = parent_sessions_.find(parent);
  CHECK(parent_sessions != parent_sessions_.end());
  parent_sessions->second.erase(session->id);
  sessions_.erase(session->id);
  if (parent_sessions->second.empty()) {
    parent_sessions_.erase(parent_sessions);
    parent->RemoveObserver(this);
    parent->DestroyOffTheRecordProfile(otr);
  }
  session->parent = nullptr;
  session->otr = nullptr;
}

}  // namespace shaar

namespace shaar {

bool ShaarModuleRegistry::Register(uint32_t module_id,
                                  PrivateSessionModuleHandlers handlers) {
  if (module_id != SHAAR_MODULE_PRIVATE_SESSIONS || !handlers.open ||
      !handlers.close || !handlers.scope_policy) {
    return false;
  }
  return handlers_.emplace(module_id, handlers).second;
}

const PrivateSessionModuleHandlers* ShaarModuleRegistry::Find(
    uint32_t module_id) const {
  auto found = handlers_.find(module_id);
  return found == handlers_.end() ? nullptr : &found->second;
}

shaar_error_code OpenPrivateSessionHandler(
    void* context,
    Profile* parent,
    const std::string& profile_id,
    const std::string& session_id,
    PrivateSessionRegistry::Session** out) {
  if (!out)
    return SHAAR_INVALID_ARGUMENT;
  *out = nullptr;
  if (!context || !parent || profile_id.empty() || session_id.empty())
    return SHAAR_INVALID_ARGUMENT;
  if (parent->IsOffTheRecord() || parent->GetOriginalProfile() != parent)
    return SHAAR_WRONG_PROFILE;
  auto* sessions = static_cast<PrivateSessionRegistry*>(context);
  return sessions->Open(parent, profile_id, session_id, out);
}

shaar_error_code PrivateSessionScopePolicy(shaar_scope scope,
                                           shaar_operation operation) {
  if (scope.size < sizeof(shaar_scope))
    return SHAAR_INVALID_ARGUMENT;
  if ((scope.profile == nullptr) == (scope.private_session == nullptr))
    return SHAAR_INVALID_ARGUMENT;
  if (!scope.private_session)
    return SHAAR_OK;
  switch (operation) {
    case SHAAR_OP_DOWNLOAD_LIST:
    case SHAAR_OP_DOWNLOAD_DIRECTORY:
    case SHAAR_OP_BOOKMARK_TREE:
    case SHAAR_OP_BOOKMARK_APPLY:
    case SHAAR_OP_HISTORY_QUERY:
    case SHAAR_OP_HISTORY_INSERT:
    case SHAAR_OP_HISTORY_DELETE:
    case SHAAR_OP_PROFILE_DELETE:
    case SHAAR_OP_PROFILE_SET_STATE:
      return SHAAR_PRIVATE_DISALLOWED;
    default:
      return SHAAR_OK;
  }
}

shaar_error_code EmitPrivateSessionStateEvent(
    shaar_engine* engine,
    const std::string& profile_id,
    const std::string& session_id,
    PrivateSessionRegistry::EventState state) {
  const char* payload = nullptr;
  size_t payload_size = 0;
  switch (state) {
    case PrivateSessionRegistry::EventState::kOpened:
      payload = "{\"kind\":\"privateSession.opened\",\"schemaVersion\":1}";
      payload_size = sizeof("{\"kind\":\"privateSession.opened\",\"schemaVersion\":1}") - 1;
      break;
    case PrivateSessionRegistry::EventState::kClosing:
      payload = "{\"kind\":\"privateSession.closing\",\"schemaVersion\":1}";
      payload_size = sizeof("{\"kind\":\"privateSession.closing\",\"schemaVersion\":1}") - 1;
      break;
    case PrivateSessionRegistry::EventState::kClosed:
      payload = "{\"kind\":\"privateSession.closed\",\"schemaVersion\":1}";
      payload_size = sizeof("{\"kind\":\"privateSession.closed\",\"schemaVersion\":1}") - 1;
      break;
  }
  return EmitEvent(
      engine, SHAAR_EVENT_PRIVATE_SESSION,
      {profile_id.data(), profile_id.size()},
      {session_id.data(), session_id.size()}, {nullptr, 0}, {nullptr, 0},
      {payload, payload_size});
}

std::unique_ptr<PrivateSessionRegistry> CreatePrivateSessionRegistry(
    shaar_engine* engine) {
  return std::make_unique<PrivateSessionRegistry>(
      [engine](const std::string& profile_id, const std::string& session_id,
               PrivateSessionRegistry::EventState state) {
        EmitPrivateSessionStateEvent(engine, profile_id, session_id, state);
      });
}

shaar_error_code ClosePrivateSessionHandler(
    void* context,
    PrivateSessionRegistry::Session* session) {
  if (!context || !session)
    return SHAAR_INVALID_ARGUMENT;
  return static_cast<PrivateSessionRegistry*>(context)->Close(session)
             ? SHAAR_OK
             : SHAAR_NOT_FOUND;
}

}  // namespace shaar

extern "C" void shaar_private_sessions_register(
    shaar::ShaarModuleRegistry* registry) {
  if (!registry)
    return;
  registry->Register(
      SHAAR_MODULE_PRIVATE_SESSIONS,
      {.open = &shaar::OpenPrivateSessionHandler,
       .close = &shaar::ClosePrivateSessionHandler,
       .scope_policy = &shaar::PrivateSessionScopePolicy});
}
