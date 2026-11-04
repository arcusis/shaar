// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#ifndef CHROME_BROWSER_SHAAR_PRIVATE_SESSIONS_SHAAR_PRIVATE_TRACKERS_H_
#define CHROME_BROWSER_SHAAR_PRIVATE_SESSIONS_SHAAR_PRIVATE_TRACKERS_H_

#include <map>
#include <optional>
#include <set>
#include <string>
#include <vector>

#include "chrome/browser/shaar/public/shaar_engine.h"
#include "url/gurl.h"
#include "url/origin.h"

class Profile;
namespace content { class BrowserContext; }
namespace net { class IsolationInfo; }
namespace network { class URLLoaderFactoryBuilder; }

namespace shaar {

class PrivateTrackerProtection {
 public:
  struct StatusInfo {
    std::string revision;
    int domain_count = 0;
    int blocked_requests = 0;
    bool enabled = false;
  };

  shaar_error_code SetRules(Profile* parent, const std::string& revision,
                            const std::vector<std::string>& domains);
  shaar_error_code SetAllowance(Profile* otr, const std::string& origin,
                                bool allow);
  bool Allowance(Profile* otr, const std::string& origin) const;
  StatusInfo Status(Profile* otr) const;
  bool ShouldBlock(Profile* profile, const GURL& url,
                   const std::optional<url::Origin>& top_origin);
  void RemoveProfile(Profile* profile);

 private:
  struct Rules {
    std::string revision;
    std::set<std::string, std::less<>> domains;
  };
  struct PrivateState {
    std::set<std::string> allowed_origins;
    int blocked_requests = 0;
  };
  std::map<Profile*, Rules> rules_;
  std::map<Profile*, PrivateState> private_states_;
};

PrivateTrackerProtection& TrackerProtection();
bool ValidPrivateTrackerOrigin(const std::string& origin);
void InstallPrivateTrackerFactory(content::BrowserContext* context,
                                  const net::IsolationInfo& isolation,
                                  network::URLLoaderFactoryBuilder& builder);
bool ShouldBlockPrivateTracker(content::BrowserContext* context,
                               const GURL& url,
                               const std::optional<url::Origin>& top_origin);

}  // namespace shaar

#endif
