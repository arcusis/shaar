// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#ifndef CHROME_BROWSER_SHAAR_PROFILES_SHAAR_PROFILES_H_
#define CHROME_BROWSER_SHAAR_PROFILES_SHAAR_PROFILES_H_

#include <string>

#include "base/functional/callback.h"
#include "chrome/browser/profiles/profile_observer.h"
#include "chrome/browser/shaar/public/shaar_engine.h"

class PrefService;
class Profile;

namespace shaar::profiles {

// Clears an ABI handle's borrowed Profile pointer before Chromium destroys it.
class ProfileHandleObserver final : public ProfileObserver {
 public:
  ProfileHandleObserver() = default;
  ~ProfileHandleObserver() override;
  ProfileHandleObserver(const ProfileHandleObserver&) = delete;
  ProfileHandleObserver& operator=(const ProfileHandleObserver&) = delete;

  void Observe(Profile* profile, Profile** slot);
  void SetWillBeDestroyedCallback(base::OnceClosure callback);
  void StopObserving();
  void OnProfileWillBeDestroyed(Profile* profile) override;

 private:
  Profile* observed_ = nullptr;
  Profile** slot_ = nullptr;
  base::OnceClosure will_be_destroyed_callback_;
};

// Validates the canonical ID and returns its only permitted relative path.
bool CanonicalDirectory(shaar_bytes profile_id, std::string* directory);

// Reorders a loaded profile's page languages and stores the app locale for
// this launch. The app language remains first when opening an existing profile.
void ApplyApplicationLocale(Profile* profile,
                            PrefService* local_state,
                            const std::string& locale);

}  // namespace shaar::profiles

struct ShaarModuleRegistry;
extern "C" void shaar_profiles_register(ShaarModuleRegistry* registry);

#endif  // CHROME_BROWSER_SHAAR_PROFILES_SHAAR_PROFILES_H_
