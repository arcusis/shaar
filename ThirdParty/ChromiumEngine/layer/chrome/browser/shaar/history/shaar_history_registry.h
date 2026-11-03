// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#ifndef CHROME_BROWSER_SHAAR_HISTORY_SHAAR_HISTORY_REGISTRY_H_
#define CHROME_BROWSER_SHAAR_HISTORY_SHAAR_HISTORY_REGISTRY_H_

#include <functional>
#include <string>

#include "chrome/browser/shaar/public/shaar_engine.h"

class Profile;

// Temporary module boundary for step 8. Replace with the lifecycle-owned
// registry interface when that module lands; its handler signature is stable.
class ShaarModuleRegistry {
 public:
  // A non-OK return is the shaar_submit immediate error and must not reply.
  // SHAAR_OK accepts the request and requires one later, non-inline reply.
  using Handler = std::function<shaar_error_code(shaar_scope, shaar_bytes,
                                                shaar_request_id, shaar_reply_fn,
                                                void*, shaar_error*)>;
  using HistoryEvent = std::function<void(const std::string& profile_id,
                                          const std::string& payload)>;

  virtual ~ShaarModuleRegistry() = default;
  virtual void RegisterHandler(shaar_operation operation, Handler handler) = 0;
  virtual Profile* ResolveRegularProfile(shaar_profile* handle) = 0;
  virtual std::string ProfileID(shaar_profile* handle) const = 0;
  virtual HistoryEvent HistoryEventSink() = 0;
};

#endif  // CHROME_BROWSER_SHAAR_HISTORY_SHAAR_HISTORY_REGISTRY_H_
