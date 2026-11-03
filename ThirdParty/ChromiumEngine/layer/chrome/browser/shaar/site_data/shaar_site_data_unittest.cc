// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#include "chrome/browser/shaar/site_data/shaar_site_data.h"

#include <string>
#include <string_view>

#include "testing/gtest/include/gtest/gtest.h"

namespace {

class FakePrivateSessionServices final : public shaar::PrivateSessionServices {
 public:
  Profile* ResolvePrivateProfile(shaar_engine*, shaar_private_session*) override {
    return live ? profile : nullptr;
  }
  std::string_view ProfileID(shaar_engine*, shaar_private_session*) override {
    return live ? "profile-1" : std::string_view();
  }
  std::string_view SessionID(shaar_engine*, shaar_private_session*) override {
    return live ? "session-1" : std::string_view();
  }

  bool live = true;
  Profile* profile = reinterpret_cast<Profile*>(1);
};

}  // namespace

TEST(ShaarSiteDataTest, AcceptsExactHttpOrigins) {
  EXPECT_TRUE(IsValidSiteDataOriginForTesting("https://example.com"));
  EXPECT_TRUE(IsValidSiteDataOriginForTesting("http://localhost:8080/"));
}

TEST(ShaarSiteDataTest, RejectsNonOriginAndUnsafeSchemes) {
  EXPECT_FALSE(IsValidSiteDataOriginForTesting("https://example.com/path"));
  EXPECT_FALSE(IsValidSiteDataOriginForTesting("https://example.com?q=1"));
  EXPECT_FALSE(IsValidSiteDataOriginForTesting("file:///tmp/page"));
  EXPECT_FALSE(IsValidSiteDataOriginForTesting("https://user@example.com"));
  EXPECT_FALSE(IsValidSiteDataOriginForTesting(""));
}

TEST(ShaarSiteDataTest, RegistersItsOperationRangeAndModuleID) {
  ShaarModuleRegistry registry;
  shaar_site_data_register(&registry);
  EXPECT_EQ(registry.Find(SHAAR_OP_SITE_SETTINGS_GET), &HandleSiteDataOperation);
  EXPECT_EQ(registry.Find(SHAAR_OP_THIRD_PARTY_COOKIES_SET),
            &HandleSiteDataOperation);
  EXPECT_NE(registry.FindModule(SHAAR_MODULE_SITE_DATA), nullptr);
}

TEST(ShaarSiteDataTest, InFlightPrivateClearRejectsClosedSessionAtCompletion) {
  FakePrivateSessionServices sessions;
  shaar::ShaarEngineContext context{};
  context.private_sessions = &sessions;
  auto* engine = reinterpret_cast<shaar_engine*>(2);
  auto* session = reinterpret_cast<shaar_private_session*>(3);

  EXPECT_EQ(SHAAR_OK, shaar::site_data::ClearCompletionStatus(
                          &context, engine, session, sessions.profile,
                          "profile-1", "session-1", false));
  sessions.live = false;
  EXPECT_EQ(SHAAR_WRONG_SESSION, shaar::site_data::ClearCompletionStatus(
                                     &context, engine, session, sessions.profile,
                                     "profile-1", "session-1", false));
}
