// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#include "chrome/browser/shaar/profiles/shaar_profiles.h"

#include <string>

#include "base/functional/bind.h"
#include "chrome/browser/shaar/engine/shaar_module_registry.h"
#include "chrome/test/base/testing_profile.h"
#include "components/language/core/browser/pref_names.h"
#include "components/prefs/pref_service.h"
#include "components/prefs/pref_registry_simple.h"
#include "components/prefs/testing_pref_service.h"
#include "content/public/test/browser_task_environment.h"
#include "testing/gtest/include/gtest/gtest.h"

namespace {

void NoopReply(void*, const shaar_result*) {}

void MarkNotified(bool* notified) {
  *notified = true;
}

TEST(ShaarProfilesTest, ProfileHandleDestructionCallbackRunsAfterHandleIsCleared) {
  content::BrowserTaskEnvironment task_environment;
  auto profile = std::make_unique<TestingProfile>();
  Profile* borrowed = profile.get();
  bool notified = false;
  shaar::profiles::ProfileHandleObserver observer;
  observer.Observe(profile.get(), &borrowed);
  observer.SetWillBeDestroyedCallback(
      base::BindOnce(&MarkNotified, &notified));

  profile.reset();

  EXPECT_EQ(borrowed, nullptr);
  EXPECT_TRUE(notified);
}

TEST(ShaarProfilesTest, LoadedProfileFollowsApplicationLanguage) {
  content::BrowserTaskEnvironment task_environment;
  TestingProfile profile;
  TestingPrefServiceSimple local_state;
  local_state.registry()->RegisterStringPref(
      language::prefs::kApplicationLocale, "en-US");
  profile.GetPrefs()->SetString(language::prefs::kSelectedLanguages,
                                "en-US,en");
  profile.GetPrefs()->SetString(language::prefs::kAcceptLanguages, "en-US,en");

  shaar::profiles::ApplyApplicationLocale(&profile, &local_state, "he");
  EXPECT_EQ(local_state.GetString(language::prefs::kApplicationLocale), "he");
  EXPECT_EQ(profile.GetPrefs()->GetString(language::prefs::kSelectedLanguages),
            "he,en-US,en");
  EXPECT_EQ(profile.GetPrefs()->GetString(language::prefs::kAcceptLanguages),
            "he,en-US,en");

  shaar::profiles::ApplyApplicationLocale(&profile, &local_state, "en");
  EXPECT_EQ(local_state.GetString(language::prefs::kApplicationLocale), "en");
  EXPECT_EQ(profile.GetPrefs()->GetString(language::prefs::kAcceptLanguages),
            "en,he,en-US");
}

TEST(ShaarProfilesTest, ReapplyingHebrewLocaleOnlyUpdatesPersistedPreferences) {
  content::BrowserTaskEnvironment task_environment;
  TestingProfile profile;
  TestingPrefServiceSimple local_state;
  local_state.registry()->RegisterStringPref(
      language::prefs::kApplicationLocale, "en-US");
  profile.GetPrefs()->SetString(language::prefs::kSelectedLanguages,
                                "en-US,en");
  profile.GetPrefs()->SetString(language::prefs::kAcceptLanguages,
                                "en-US,en");

  // Restart can load the same locale more than once. Persist the profile
  // language each time without changing Chromium's process-global locale after
  // startup.
  shaar::profiles::ApplyApplicationLocale(&profile, &local_state, "he");
  shaar::profiles::ApplyApplicationLocale(&profile, &local_state, "he");

  EXPECT_EQ(local_state.GetString(language::prefs::kApplicationLocale), "he");
  EXPECT_EQ(profile.GetPrefs()->GetString(language::prefs::kSelectedLanguages),
            "he,en-US,en");
  EXPECT_EQ(profile.GetPrefs()->GetString(language::prefs::kAcceptLanguages),
            "he,en-US,en");
}

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

TEST(ShaarProfilesTest, BorrowedProfileIsClearedBeforeDestruction) {
  content::BrowserTaskEnvironment task_environment;
  shaar::profiles::ProfileHandleObserver observer;
  Profile* borrowed = nullptr;
  {
    TestingProfile profile;
    borrowed = &profile;
    observer.Observe(&profile, &borrowed);
    ASSERT_EQ(borrowed, &profile);
  }
  EXPECT_EQ(borrowed, nullptr);
}

TEST(ShaarProfilesTest, RegistersOnlyTheProfileOperationRange) {
  ShaarModuleRegistry registry;
  shaar_profiles_register(&registry);
  EXPECT_NE(registry.Find(SHAAR_OP_PROFILE_DELETE), nullptr);
  EXPECT_NE(registry.Find(SHAAR_OP_PROFILE_GET_STATE), nullptr);
  EXPECT_NE(registry.Find(SHAAR_OP_PROFILE_SET_STATE), nullptr);
}

TEST(ShaarProfilesTest, HandlerRejectsMissingAndPrivateProfileScopes) {
  ShaarModuleRegistry registry;
  shaar_profiles_register(&registry);
  auto handler = registry.Find(SHAAR_OP_PROFILE_GET_STATE);
  auto* fake_engine = reinterpret_cast<shaar_engine*>(0x1);
  shaar_error error = {};
  error.size = sizeof(error);
  shaar_scope scope = {};
  scope.size = sizeof(scope);
  EXPECT_EQ(handler(nullptr, fake_engine, scope, nullptr, nullptr,
                    SHAAR_OP_PROFILE_GET_STATE, {"{}", 2}, 1,
                    &NoopReply, nullptr, &error),
            SHAAR_INVALID_ARGUMENT);
  scope.private_session = reinterpret_cast<shaar_private_session*>(0x2);
  EXPECT_EQ(handler(nullptr, fake_engine, scope, nullptr, nullptr,
                    SHAAR_OP_PROFILE_GET_STATE, {"{}", 2}, 1,
                    &NoopReply, nullptr, &error),
            SHAAR_PRIVATE_DISALLOWED);
}

}  // namespace
