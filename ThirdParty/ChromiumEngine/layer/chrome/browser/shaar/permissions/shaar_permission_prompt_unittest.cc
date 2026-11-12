// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#include "chrome/browser/shaar/permissions/shaar_permission_prompt.h"

#include "chrome/browser/content_settings/host_content_settings_map_factory.h"
#include "chrome/browser/custom_handlers/protocol_handler_registry_factory.h"
#include "chrome/test/base/testing_profile.h"
#include "content/public/test/browser_task_environment.h"
#include "components/content_settings/core/browser/host_content_settings_map.h"
#include "components/content_settings/core/common/content_settings.h"
#include "components/custom_handlers/protocol_handler.h"
#include "components/custom_handlers/protocol_handler_registry.h"
#include "components/permissions/test/mock_permission_prompt_delegate.h"
#include "testing/gmock/include/gmock/gmock.h"
#include "testing/gtest/include/gtest/gtest.h"

namespace shaar::permissions {
namespace {

TEST(ShaarPermissionPromptTest, MapsLocationNotificationAndMidiRequests) {
  EXPECT_EQ(PermissionKindForRequestType(
                ::permissions::RequestType::kGeolocation),
            "location");
  EXPECT_EQ(PermissionKindForRequestType(
                ::permissions::RequestType::kNotifications),
            "notifications");
  EXPECT_EQ(PermissionKindForRequestType(
                ::permissions::RequestType::kMidiSysex),
            "midi");
}

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

TEST(ShaarPermissionPromptTest, AppendedPermissionWasNotShownAndCannotBeGranted) {
  const std::vector<std::string> shown = {"camera"};
  const std::vector<std::string> current = {"camera", "location"};
  const std::vector<std::string> same_kinds_different_order = {
      "location", "camera"};

  EXPECT_FALSE(ShownPermissionsMatch(shown, current));
  EXPECT_TRUE(ShownPermissionsMatch(current, same_kinds_different_order));
  EXPECT_TRUE(ShownPermissionsMatch(shown, shown));
  // A new request of an already listed kind still changes what Allow would
  // resolve, even though the visible kind set is unchanged.
  EXPECT_FALSE(ShownRequestCountMatches(1, 2));
}

TEST(ShaarPermissionPromptTest, OTRDecisionLeavesParentPermissionStoresAlone) {
  content::BrowserTaskEnvironment task_environment;
  TestingProfile profile;
  Profile* otr = profile.GetPrimaryOTRProfile(/*create_if_needed=*/true);
  ASSERT_NE(otr, nullptr);

  auto* parent_settings = HostContentSettingsMapFactory::GetForProfile(&profile);
  auto* otr_settings = HostContentSettingsMapFactory::GetForProfile(otr);
  ASSERT_NE(parent_settings, nullptr);
  ASSERT_NE(otr_settings, nullptr);

  const ContentSettingsType type = ContentSettingsType::GEOLOCATION;
  const GURL origin("https://permission.example.test/");
  parent_settings->SetContentSettingDefaultScope(
      origin, origin, type, CONTENT_SETTING_ASK);
  const ContentSetting parent_default_before =
      parent_settings->GetDefaultContentSetting(type);
  const ContentSetting parent_site_before =
      parent_settings->GetContentSetting(origin, origin, type);
  const ContentSetting otr_default_before =
      otr_settings->GetDefaultContentSetting(type);
  const ContentSetting otr_site_before =
      otr_settings->GetContentSetting(origin, origin, type);

  auto* registry_factory =
      ProtocolHandlerRegistryFactory::GetInstance();
  registry_factory->SetTestingFactoryAndUse(
      &profile,
      ProtocolHandlerRegistryFactory::GetDefaultFactory());
  registry_factory->SetTestingFactoryAndUse(
      otr,
      ProtocolHandlerRegistryFactory::GetDefaultFactory());
  auto* parent_registry =
      ProtocolHandlerRegistryFactory::GetForBrowserContext(
          &profile);
  auto* otr_registry =
      ProtocolHandlerRegistryFactory::GetForBrowserContext(
          otr);
  ASSERT_NE(parent_registry, nullptr);
  ASSERT_NE(otr_registry, nullptr);
  ASSERT_NE(parent_registry, otr_registry);
  parent_registry->OnDenyRegisterProtocolHandler(
      custom_handlers::ProtocolHandler::CreateProtocolHandler(
          "web+shaartest", GURL("https://handler.example.test/?%s")));
  const size_t parent_protocol_handlers_before =
      parent_registry->GetHandlersFor("web+shaartest").size();

  ::testing::StrictMock<::permissions::MockPermissionPromptDelegate> delegate;
  EXPECT_CALL(delegate, AcceptThisTime(::testing::_)).Times(1);
  const GrantPersistence location_persistence = DecideGrant(
      &delegate, true, true, otr->IsOffTheRecord(), false, false,
      std::monostate{});
  ASSERT_EQ(location_persistence, GrantPersistence::kThisVisit);

  EXPECT_EQ(parent_settings->GetDefaultContentSetting(type),
            parent_default_before);
  EXPECT_EQ(parent_settings->GetContentSetting(origin, origin, type),
            parent_site_before);
  EXPECT_EQ(otr_settings->GetDefaultContentSetting(type), otr_default_before);
  EXPECT_EQ(otr_settings->GetContentSetting(origin, origin, type),
            otr_site_before);
  EXPECT_EQ(parent_registry->GetHandlersFor("web+shaartest").size(),
            parent_protocol_handlers_before);

  EXPECT_CALL(delegate, Accept(::testing::_)).Times(1);
  const GrantPersistence protocol_persistence = DecideGrant(
      &delegate, true, true, otr->IsOffTheRecord(), false, true,
      std::monostate{});
  ASSERT_EQ(protocol_persistence, GrantPersistence::kPrivateProtocol);
  EXPECT_EQ(parent_registry->GetHandlersFor("web+shaartest").size(),
            parent_protocol_handlers_before);
}

}  // namespace
}  // namespace shaar::permissions
