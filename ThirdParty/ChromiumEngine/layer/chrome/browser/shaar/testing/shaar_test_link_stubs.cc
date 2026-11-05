// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// The standalone layer test binary omits ChromeMainDelegate and managed-profile
// UI. These link stubs are test-only and are never included in the framework.

#include <memory>
#include <optional>

#include "base/check.h"
#include "chrome/browser/enterprise/signin/managed_profile_creation_controller.h"

class Profile;

namespace extensions {
class ManagementPolicy;
}

bool g_ardia_embedder = false;

namespace ardia {

void RegisterManagementPolicyProviders(Profile*, extensions::ManagementPolicy*) {}

}  // namespace ardia

std::unique_ptr<ManagedProfileCreationController>
ManagedProfileCreationController::CreateManagedProfileForTesting(
    Profile*,
    const AccountInfo&,
    signin_metrics::AccessPoint,
    ManagedProfileCreationControllerCallback,
    std::optional<policy::ProfileSeparationPolicies>,
    std::optional<signin::SigninChoice>) {
  CHECK(false) << "Chrome's managed-profile test path is not part of Shaar's layer tests";
  return nullptr;
}
