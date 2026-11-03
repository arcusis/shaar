// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#include "chrome/browser/shaar/private-sessions/shaar_private_sessions.h"
#include "chrome/browser/shaar/private-sessions/shaar_private_sessions_module.h"

#include "chrome/test/base/testing_profile.h"
#include "testing/gtest/include/gtest/gtest.h"

namespace shaar {
namespace {

TEST(PrivateSessionRegistryTest, SameParentAndIDShareOnePrimaryOTRLease) {
  TestingProfile profile;
  PrivateSessionRegistry registry;
  auto* first = registry.Open(&profile, "session-a");
  ASSERT_NE(first, nullptr);
  auto* second = registry.Open(&profile, "session-a");
  EXPECT_EQ(first, second);
  EXPECT_EQ(registry.Open(&profile, "session-b"), nullptr);
  EXPECT_EQ(first->otr, profile.GetPrimaryOTRProfile(/*create_if_needed=*/false));
  EXPECT_EQ(first->open_handles, 2u);
  EXPECT_TRUE(registry.Close(first));
  EXPECT_NE(registry.Find(&profile, "session-a"), nullptr);
  EXPECT_TRUE(registry.Close(second));
  EXPECT_EQ(registry.Find(&profile, "session-a"), nullptr);
}

TEST(PrivateSessionRegistryTest, RejectsWrongParentAndRetiredSessionIDs) {
  TestingProfile first_profile;
  TestingProfile second_profile;
  PrivateSessionRegistry registry;
  auto* session = registry.Open(&first_profile, "session-a");
  ASSERT_NE(session, nullptr);
  EXPECT_EQ(registry.Open(&second_profile, "session-a"), nullptr);
  EXPECT_TRUE(registry.Close(session));
  EXPECT_EQ(registry.Open(&first_profile, "session-a"), nullptr);
}

TEST(PrivateSessionRegistryTest, DefersRetirementUntilChildrenClose) {
  TestingProfile profile;
  PrivateSessionRegistry registry;
  auto* session = registry.Open(&profile, "session-a");
  ASSERT_NE(session, nullptr);
  ASSERT_TRUE(registry.RetainChild(session));
  EXPECT_TRUE(registry.Close(session));
  EXPECT_EQ(registry.Find(&profile, "session-a"), nullptr);
  EXPECT_TRUE(registry.ReleaseChild(session));
  EXPECT_EQ(registry.Open(&profile, "session-a"), nullptr);
}

TEST(PrivateSessionRegistryTest, RejectsOTRParentAndEmptyIdentity) {
  TestingProfile profile;
  PrivateSessionRegistry registry;
  Profile* otr = profile.GetPrimaryOTRProfile(/*create_if_needed=*/true);
  ASSERT_NE(otr, nullptr);
  EXPECT_EQ(registry.Open(otr, "session-a"), nullptr);
  EXPECT_EQ(registry.Open(&profile, ""), nullptr);
}

TEST(PrivateSessionRegistryTest, ModuleRegistrationExposesDirectHandlers) {
  TestingProfile profile;
  PrivateSessionRegistry sessions;
  ShaarModuleRegistry modules;
  shaar_private_sessions_register(&modules);
  const auto* handlers = modules.Find(SHAAR_MODULE_PRIVATE_SESSIONS);
  ASSERT_NE(handlers, nullptr);
  PrivateSessionRegistry::Session* session = nullptr;
  EXPECT_EQ(handlers->open(&sessions, &profile, "session-a", &session),
            SHAAR_OK);
  ASSERT_NE(session, nullptr);
  EXPECT_EQ(handlers->close(&sessions, session), SHAAR_OK);
  EXPECT_EQ(handlers->close(&sessions, session), SHAAR_NOT_FOUND);
}

}  // namespace
}  // namespace shaar
