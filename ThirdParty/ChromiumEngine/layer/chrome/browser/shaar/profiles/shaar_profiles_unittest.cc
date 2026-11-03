// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#include "chrome/browser/shaar/profiles/shaar_profiles.h"

#include <map>
#include <string>

#include "chrome/browser/shaar/profiles/shaar_module_registry.h"
#include "testing/gtest/include/gtest/gtest.h"

namespace {

class CapturingRegistry final : public shaar::ShaarModuleRegistry {
 public:
  void Register(shaar_operation operation, Handler handler) override {
    handlers[operation] = handler;
  }

  std::map<shaar_operation, Handler> handlers;
};

void NoopReply(void*, const shaar_result*) {}

TEST(ShaarProfilesTest, UUIDMappingIsCanonicalAndContained) {
  std::string relative;
  constexpr char kID[] = "4a4d4885-d38a-4b4a-bc03-b12f634bff01";
  EXPECT_TRUE(shaar::profiles::CanonicalDirectory({kID, sizeof(kID) - 1}, &relative));
  EXPECT_EQ(relative, "Profile 4a4d4885-d38a-4b4a-bc03-b12f634bff01");
  constexpr char kUpperID[] = "4A4D4885-d38a-4b4a-bc03-b12f634bff01";
  EXPECT_FALSE(
      shaar::profiles::CanonicalDirectory({kUpperID, sizeof(kUpperID) - 1}, &relative));
  constexpr char kTraversal[] = "../Default";
  EXPECT_FALSE(shaar::profiles::CanonicalDirectory(
      {kTraversal, sizeof(kTraversal) - 1}, &relative));
}

TEST(ShaarProfilesTest, RegistersOnlyTheProfileOperationRange) {
  CapturingRegistry registry;
  shaar_profiles_register(&registry);
  ASSERT_EQ(registry.handlers.size(), 3u);
  EXPECT_TRUE(registry.handlers.contains(SHAAR_OP_PROFILE_DELETE));
  EXPECT_TRUE(registry.handlers.contains(SHAAR_OP_PROFILE_GET_STATE));
  EXPECT_TRUE(registry.handlers.contains(SHAAR_OP_PROFILE_SET_STATE));
}

TEST(ShaarProfilesTest, HandlerRejectsMissingAndPrivateProfileScopes) {
  CapturingRegistry registry;
  shaar_profiles_register(&registry);
  auto handler = registry.handlers.at(SHAAR_OP_PROFILE_GET_STATE);
  auto* fake_engine = reinterpret_cast<shaar_engine*>(0x1);
  shaar_error error = {};
  error.size = sizeof(error);
  shaar_scope scope = {};
  scope.size = sizeof(scope);
  EXPECT_EQ(handler(fake_engine, scope, nullptr, nullptr,
                    SHAAR_OP_PROFILE_GET_STATE, {"{}", 2}, 1,
                    &NoopReply, nullptr, &error),
            SHAAR_INVALID_ARGUMENT);
  scope.private_session = reinterpret_cast<shaar_private_session*>(0x2);
  EXPECT_EQ(handler(fake_engine, scope, nullptr, nullptr,
                    SHAAR_OP_PROFILE_GET_STATE, {"{}", 2}, 1,
                    &NoopReply, nullptr, &error),
            SHAAR_PRIVATE_DISALLOWED);
}

}  // namespace
