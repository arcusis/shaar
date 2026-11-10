// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#include "chrome/browser/shaar/permissions/shaar_permission_prompt.h"

#include "testing/gtest/include/gtest/gtest.h"

namespace shaar::permissions {
namespace {

FrameSnapshot BoundFrame() {
  return FrameSnapshot{"0123456789ABCDEF0123456789ABCDEF", true, true, 42};
}

TEST(ShaarPermissionPromptTest, FrameBindingFailsWhenTheFrameChanges) {
  const FrameSnapshot stored = BoundFrame();
  EXPECT_TRUE(FrameStillBound(stored, stored));

  FrameSnapshot other_token = stored;
  other_token.token = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";
  EXPECT_FALSE(FrameStillBound(stored, other_token));

  FrameSnapshot inactive = stored;
  inactive.active = false;
  EXPECT_FALSE(FrameStillBound(stored, inactive));

  FrameSnapshot other_contents = stored;
  other_contents.same_contents = false;
  EXPECT_FALSE(FrameStillBound(stored, other_contents));

  FrameSnapshot other_navigation = stored;
  other_navigation.navigation_id = 43;
  EXPECT_FALSE(FrameStillBound(stored, other_navigation));

  FrameSnapshot missing;
  EXPECT_FALSE(FrameStillBound(missing, missing));
}

TEST(ShaarPermissionPromptTest, PrivateGrantsDoNotPersist) {
  EXPECT_EQ(PersistenceFor(false, true, true, false, false),
            GrantPersistence::kDeny);
  EXPECT_EQ(PersistenceFor(true, false, true, false, false),
            GrantPersistence::kDeny);
  EXPECT_EQ(PersistenceFor(true, true, true, false, false),
            GrantPersistence::kThisVisit);
  EXPECT_EQ(PersistenceFor(true, true, true, true, false),
            GrantPersistence::kThisVisit);
  EXPECT_EQ(PersistenceFor(true, true, true, false, true),
            GrantPersistence::kPrivateProtocol);
  EXPECT_NE(PersistenceFor(true, true, true, false, true),
            GrantPersistence::kProfile);
  EXPECT_NE(PersistenceFor(true, true, true, false, true),
            GrantPersistence::kThisVisit);
  EXPECT_EQ(PersistenceFor(true, true, false, true, false),
            GrantPersistence::kThisVisit);
  EXPECT_EQ(PersistenceFor(true, true, false, false, false),
            GrantPersistence::kProfile);
  EXPECT_EQ(PersistenceFor(true, true, false, false, true),
            GrantPersistence::kProfile);
}

TEST(ShaarPermissionPromptTest, ReloadOrDetachDropsTheRequest) {
  const FrameSnapshot stored = BoundFrame();
  EXPECT_FALSE(FrameLeftTheRequest(stored, stored, false, false));
  EXPECT_FALSE(FrameLeftTheRequest(stored, stored, true, false));

  FrameSnapshot reloaded = stored;
  reloaded.navigation_id = 43;
  EXPECT_TRUE(FrameLeftTheRequest(stored, reloaded, false, false));
  EXPECT_FALSE(FrameLeftTheRequest(stored, reloaded, true, false));

  EXPECT_TRUE(FrameLeftTheRequest(stored, stored, false, true));

  FrameSnapshot inactive = stored;
  inactive.active = false;
  EXPECT_TRUE(FrameLeftTheRequest(stored, inactive, false, false));

  FrameSnapshot other = stored;
  other.token = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";
  other.navigation_id = 99;
  EXPECT_FALSE(FrameLeftTheRequest(stored, other, false, false));
  EXPECT_FALSE(FrameLeftTheRequest(stored, other, false, true));

  FrameSnapshot missing;
  EXPECT_FALSE(FrameLeftTheRequest(missing, missing, false, true));
}

TEST(ShaarPermissionPromptTest, PrivateProfileGrantIsNotPersisted) {
  EXPECT_FALSE(GrantIsPersisted(GrantPersistence::kDeny));
  EXPECT_FALSE(GrantIsPersisted(GrantPersistence::kThisVisit));
  EXPECT_FALSE(GrantIsPersisted(GrantPersistence::kPrivateProtocol));
  EXPECT_TRUE(GrantIsPersisted(GrantPersistence::kProfile));

  EXPECT_FALSE(
      GrantIsPersisted(PersistenceFor(true, true, true, false, false)));
  EXPECT_FALSE(
      GrantIsPersisted(PersistenceFor(true, true, true, true, false)));
  EXPECT_FALSE(
      GrantIsPersisted(PersistenceFor(true, true, true, false, true)));
  EXPECT_FALSE(
      GrantIsPersisted(PersistenceFor(true, true, true, true, true)));
  EXPECT_FALSE(
      GrantIsPersisted(PersistenceFor(false, true, true, false, false)));

  EXPECT_FALSE(
      GrantIsPersisted(PersistenceFor(true, true, false, true, false)));
  EXPECT_TRUE(
      GrantIsPersisted(PersistenceFor(true, true, false, false, false)));
  EXPECT_TRUE(
      GrantIsPersisted(PersistenceFor(true, true, false, false, true)));
}

}  // namespace
}  // namespace shaar::permissions
