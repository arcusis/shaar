// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#include "chrome/browser/shaar/private-sessions/shaar_private_sessions.h"
#include "chrome/browser/shaar/private-sessions/shaar_private_sessions_module.h"

#include <utility>

#include "base/check.h"
#include "base/strings/string_util.h"

namespace shaar {

PrivateSessionRegistry::PrivateSessionRegistry() = default;
PrivateSessionRegistry::~PrivateSessionRegistry() {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  DCHECK(sessions_.empty());
}

PrivateSessionRegistry::Session* PrivateSessionRegistry::Open(
    Profile* parent,
    const std::string& session_id) {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  if (!parent || session_id.empty() || !base::IsStringUTF8(session_id) ||
      parent->IsOffTheRecord() || parent->GetOriginalProfile() != parent) {
    return nullptr;
  }

  auto found = sessions_.find(session_id);
  if (found != sessions_.end()) {
    Session& session = *found->second;
    if (session.closing || session.parent != parent)
      return nullptr;
    ++session.open_handles;
    return &session;
  }
  if (retired_ids_.contains(session_id))
    return nullptr;
  auto parent_session = parent_sessions_.find(parent);
  if (parent_session != parent_sessions_.end())
    return nullptr;

  Profile* otr = parent->GetPrimaryOTRProfile(/*create_if_needed=*/true);
  if (!otr || !otr->IsOffTheRecord() || otr->GetOriginalProfile() != parent)
    return nullptr;

  auto session = std::make_unique<Session>();
  session->id = session_id;
  session->parent = parent;
  session->otr = otr;
  session->open_handles = 1;
  parent->AddObserver(this);
  Session* handle = session.get();
  storage_.push_back(std::move(session));
  auto [inserted, ok] = sessions_.emplace(session_id, handle);
  CHECK(ok);
  parent_sessions_.emplace(parent, session_id);
  return inserted->second;
}

bool PrivateSessionRegistry::Close(Session* session) {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  if (!IsLive(session) || session->open_handles == 0)
    return false;
  --session->open_handles;
  if (session->open_handles == 0)
    session->closing = true;
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
  auto session = sessions_.find(parent->second);
  if (session != sessions_.end()) {
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

void PrivateSessionRegistry::MaybeRetire(Session* session) {
  if (!session->closing || session->open_handles != 0 || session->children != 0)
    return;
  retired_ids_.insert(session->id);
  Profile* parent = session->parent;
  Profile* otr = session->otr;
  parent_sessions_.erase(parent);
  sessions_.erase(session->id);
  parent->RemoveObserver(this);
  parent->DestroyOffTheRecordProfile(otr);
  session->parent = nullptr;
  session->otr = nullptr;
}

}  // namespace shaar

namespace shaar {

bool ShaarModuleRegistry::Register(uint32_t module_id,
                                  PrivateSessionModuleHandlers handlers) {
  if (module_id != SHAAR_MODULE_PRIVATE_SESSIONS || !handlers.open ||
      !handlers.close) {
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
    const std::string& session_id,
    PrivateSessionRegistry::Session** out) {
  if (!out)
    return SHAAR_INVALID_ARGUMENT;
  *out = nullptr;
  if (!context || !parent || session_id.empty())
    return SHAAR_INVALID_ARGUMENT;
  if (parent->IsOffTheRecord() || parent->GetOriginalProfile() != parent)
    return SHAAR_WRONG_PROFILE;
  auto* sessions = static_cast<PrivateSessionRegistry*>(context);
  *out = sessions->Open(parent, session_id);
  return *out ? SHAAR_OK : SHAAR_CONFLICT;
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
       .close = &shaar::ClosePrivateSessionHandler});
}
