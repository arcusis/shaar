// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#ifndef CHROME_BROWSER_SHAAR_PRIVATE_SESSIONS_SHAAR_PRIVATE_SESSIONS_H_
#define CHROME_BROWSER_SHAAR_PRIVATE_SESSIONS_SHAAR_PRIVATE_SESSIONS_H_

#include <functional>
#include <memory>
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <vector>

#include "base/memory/raw_ptr.h"
#include "base/sequence_checker.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/profiles/profile_observer.h"
// BEGIN find
#include "chrome/browser/shaar/engine/shaar_engine_context.h"
// END find

namespace shaar {

// Owns Shaar's identity and lease for Chromium's primary OTR profile. The
// ProfileManager remains the owner of the Profile itself; this registry keeps
// it alive by retaining a live session until every child handle is closed.
class PrivateSessionRegistry : public ProfileObserver
// BEGIN find
                              , public PrivateSessionServices
// END find
{
 public:
  enum class EventState { kOpened, kClosing, kClosed };
  using EventSink = std::function<void(const std::string&, const std::string&,
                                       EventState)>;

  struct Session {
    std::string id;
    std::string profile_id;
    raw_ptr<Profile> parent = nullptr;
    raw_ptr<Profile> otr = nullptr;
    size_t open_handles = 0;
    size_t children = 0;
    bool closing = false;
  };

  explicit PrivateSessionRegistry(
      EventSink event_sink = {}
      // BEGIN find
      , shaar_engine* engine = nullptr
      // END find
  );
  ~PrivateSessionRegistry();
  PrivateSessionRegistry(const PrivateSessionRegistry&) = delete;
  PrivateSessionRegistry& operator=(const PrivateSessionRegistry&) = delete;

  // Returns an existing session only for the exact same (profile, ID) pair.
  // IDs are never reusable during this engine lifetime, preventing stale
  // callbacks from binding to a later private context.
  shaar_error_code Open(Profile* parent,
                        const std::string& profile_id,
                        const std::string& session_id,
                        Session** out);
  bool Close(Session* session);
  bool RetainChild(Session* session);
  bool ReleaseChild(Session* session);
  Session* Find(Profile* parent, const std::string& session_id) const;
  // BEGIN find
  bool Resolve(shaar_engine* engine,
               shaar_private_session* handle,
               Profile** parent,
               Profile** otr,
               std::string_view* profile_id,
               std::string_view* session_id) override;
  // END find
  void OnProfileWillBeDestroyed(Profile* profile) override;

 private:
  void MaybeRetire(Session* session);
  bool IsLive(const Session* session) const;
  void Emit(const Session& session, EventState state);

  SEQUENCE_CHECKER(sequence_checker_);
  // BEGIN find
  shaar_engine* const engine_;
  // END find
  std::unordered_map<std::string, Session*> sessions_;
  // Keep retired handle storage alive until engine shutdown so a stale opaque
  // pointer can be compared safely and can never alias a newly opened session.
  std::vector<std::unique_ptr<Session>> storage_;
  std::unordered_map<Profile*, std::unordered_set<std::string>> parent_sessions_;
  std::unordered_set<std::string> retired_ids_;
  EventSink event_sink_;
};

}  // namespace shaar

#endif  // CHROME_BROWSER_SHAAR_PRIVATE_SESSIONS_SHAAR_PRIVATE_SESSIONS_H_
