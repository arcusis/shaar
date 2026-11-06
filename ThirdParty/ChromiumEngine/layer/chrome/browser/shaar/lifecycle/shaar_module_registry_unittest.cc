// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#include "chrome/browser/shaar/engine/shaar_module_registry.h"
#include "chrome/browser/shaar/lifecycle/shaar_lifecycle.h"

#include <algorithm>

#include "testing/gtest/include/gtest/gtest.h"
#include "components/keep_alive_registry/keep_alive_registry.h"
#include "components/keep_alive_registry/scoped_keep_alive.h"
#include "components/keep_alive_registry/keep_alive_types.h"

namespace {

TEST(ShaarLifecycleProbeTest, BackgroundSwitchesAreVerificationOnly) {
  const auto production = shaar::lifecycle::ChromeMainArguments(
      "/test/Shaar", "/tmp/prod", "en", false);
  const auto verification = shaar::lifecycle::ChromeMainArguments(
      "/test/Shaar", "/tmp/probe", "en", true);
  EXPECT_NE(std::find(production.begin(), production.end(), "--no-startup-window"),
            production.end());
  EXPECT_NE(std::find(verification.begin(), verification.end(),
                      "--no-startup-window"),
            verification.end());
  for (const auto& arguments : {production, verification}) {
    for (const char* option : {"--shaar-embedder", "--no-first-run"}) {
      EXPECT_NE(std::find(arguments.begin(), arguments.end(), option),
                arguments.end());
    }
  }
  for (const char* option : {"--disable-renderer-backgrounding",
                             "--disable-backgrounding-occluded-windows",
                             "--disable-background-timer-throttling",
                             "--use-fake-device-for-media-stream",
                             "--host-resolver-rules=MAP trackertest.org 127.0.0.1"}) {
    EXPECT_EQ(std::find(production.begin(), production.end(), option),
              production.end());
    EXPECT_NE(std::find(verification.begin(), verification.end(), option),
              verification.end());
  }
}

TEST(ShaarLifecycleProbeTest, ClosingDevToolsKeepsHostAliveUntilExplicitRelease) {
  auto host = shaar::lifecycle::CreateHostKeepAlive();
  {
    ScopedKeepAlive devtools(KeepAliveOrigin::DEVTOOLS_WINDOW,
                            KeepAliveRestartOption::DISABLED);
    EXPECT_TRUE(KeepAliveRegistry::GetInstance()->IsOriginRegistered(
        KeepAliveOrigin::DEVTOOLS_WINDOW));
  }
  EXPECT_TRUE(KeepAliveRegistry::GetInstance()->IsKeepingAlive());
  EXPECT_TRUE(KeepAliveRegistry::GetInstance()->IsOriginRegistered(
      KeepAliveOrigin::APP_CONTROLLER));
  host.reset();
  EXPECT_FALSE(KeepAliveRegistry::GetInstance()->IsOriginRegistered(
      KeepAliveOrigin::APP_CONTROLLER));
}

TEST(ShaarLifecycleProbeTest, KeepAliveStateRequiresActiveEngine) {
  shaar_error error = {};
  error.size = sizeof(error);
  shaar_bytes state = {"old", 3};
  EXPECT_EQ(shaar_test_keep_alive_state(nullptr, &state, &error),
            SHAAR_INVALID_ARGUMENT);
  EXPECT_EQ(state.data, nullptr);
  EXPECT_EQ(error.code, SHAAR_INVALID_ARGUMENT);
  EXPECT_EQ(shaar_test_keep_alive_state(
                reinterpret_cast<shaar_engine*>(1), &state, &error),
            SHAAR_NOT_READY);
  EXPECT_EQ(state.data, nullptr);
  EXPECT_EQ(error.code, SHAAR_NOT_READY);
}

shaar_error_code FakeProfileHandler(shaar::ShaarEngineContext*,
                                    shaar_engine*,
                                    shaar_scope,
                                    shaar_window*,
                                    shaar_tab*,
                                    shaar_operation operation,
                                    shaar_bytes,
                                    shaar_request_id,
                                    shaar_reply_fn,
                                    void*,
                                    shaar_error*) {
  return operation == SHAAR_OP_PROFILE_GET_STATE ? SHAAR_OK
                                                  : SHAAR_INVALID_ARGUMENT;
}

shaar_error_code FakeCancelHandler(shaar_engine*,
                                   shaar_request_id,
                                   shaar_error*) {
  return SHAAR_OK;
}

TEST(ShaarModuleRegistryTest, DispatchesOperationsInsideRegisteredRange) {
  ShaarModuleRegistry registry;
  ASSERT_TRUE(registry.Register(SHAAR_OP_PROFILE_DELETE,
                                SHAAR_OP_PROFILE_SET_STATE,
                                &FakeProfileHandler));
  EXPECT_EQ(registry.Find(SHAAR_OP_PROFILE_GET_STATE), &FakeProfileHandler);
  EXPECT_EQ(registry.Find(SHAAR_OP_WINDOW_BIND_PROFILE), nullptr);

  auto handler = registry.Find(SHAAR_OP_PROFILE_GET_STATE);
  ASSERT_NE(handler, nullptr);
  EXPECT_EQ(handler(nullptr, nullptr, {}, nullptr, nullptr, SHAAR_OP_PROFILE_GET_STATE,
                    {}, 1, nullptr, nullptr, nullptr),
            SHAAR_OK);
}

TEST(ShaarModuleRegistryTest, PassesProfileAndTabServicesThroughContext) {
  class FakeProfiles final : public shaar::ProfileServices {
   public:
    Profile* ResolveProfile(shaar_engine*, shaar_profile*) override {
      return reinterpret_cast<Profile*>(0x11);
    }
    std::string_view ProfileID(shaar_engine*, shaar_profile*) override {
      return "fake-profile";
    }
    KeyedService* GetKeyedService(shaar_engine*, shaar_profile*,
                                  KeyedServiceLookup lookup) override {
      return lookup ? lookup(ResolveProfile(nullptr, nullptr)) : nullptr;
    }
  } profiles;
  class FakeTabs final : public shaar::BrowserTabRegistry {
   public:
    Browser* FindBrowser(shaar_engine*, shaar_window*) override {
      return reinterpret_cast<Browser*>(0x12);
    }
    content::WebContents* FindWebContents(shaar_engine*, shaar_window*,
                                          shaar_tab*) override {
      return reinterpret_cast<content::WebContents*>(0x13);
    }
    content::WebContents* FindWebContentsByID(shaar_engine*, shaar_window*,
                                               std::string_view) override {
      return reinterpret_cast<content::WebContents*>(0x14);
    }
    std::string_view TabID(shaar_engine*, shaar_window*, shaar_tab*) override {
      return "fake-tab";
    }
    void GetTabs(shaar_engine*, shaar_window*,
                 std::unordered_map<std::string, content::WebContents*>* tabs)
        override {
      if (tabs)
        tabs->emplace("fake-tab", reinterpret_cast<content::WebContents*>(0x15));
    }
  } tabs;
  shaar::ShaarEngineContext context{&profiles, &tabs};
  EXPECT_NE(context.profile_services->ResolveProfile(nullptr, nullptr), nullptr);
  EXPECT_NE(context.profile_services->GetKeyedService(
                nullptr, nullptr,
                +[](Profile*) -> KeyedService* {
                  return reinterpret_cast<KeyedService*>(0x16);
                }),
            nullptr);
  EXPECT_NE(context.browser_tabs->FindBrowser(nullptr, nullptr), nullptr);
  EXPECT_NE(context.browser_tabs->FindWebContents(nullptr, nullptr, nullptr),
            nullptr);
}

TEST(ShaarModuleRegistryTest, RejectsInvalidAndOverlappingRanges) {
  ShaarModuleRegistry registry;
  EXPECT_FALSE(registry.Register(0, 2, &FakeProfileHandler));
  EXPECT_FALSE(registry.Register(10, 9, &FakeProfileHandler));
  EXPECT_FALSE(registry.Register(10, 12, nullptr));
  ASSERT_TRUE(registry.Register(100, 102, &FakeProfileHandler));
  EXPECT_FALSE(registry.Register(101, 105, &FakeProfileHandler));
  EXPECT_FALSE(registry.Register(99, 100, &FakeProfileHandler));
  EXPECT_TRUE(registry.Register(200, 207, &FakeProfileHandler));
}

TEST(ShaarModuleRegistryTest, StoresModuleContractsByModuleID) {
  ShaarModuleRegistry registry;
  static const int handlers = 7;
  EXPECT_TRUE(registry.RegisterModule(SHAAR_MODULE_PRIVATE_SESSIONS, &handlers));
  EXPECT_EQ(registry.FindModule(SHAAR_MODULE_PRIVATE_SESSIONS), &handlers);
  EXPECT_FALSE(
      registry.RegisterModule(SHAAR_MODULE_PRIVATE_SESSIONS, &handlers));
  EXPECT_FALSE(registry.RegisterModule(0, &handlers));
  EXPECT_FALSE(registry.RegisterModule(1201, nullptr));
}

TEST(ShaarModuleRegistryTest, TracksRequestsForModuleOwnedCancellation) {
  ShaarModuleRegistry registry;
  ASSERT_TRUE(registry.Register(SHAAR_OP_PROFILE_DELETE,
                                SHAAR_OP_PROFILE_SET_STATE,
                                &FakeProfileHandler, &FakeCancelHandler));
  auto* engine = reinterpret_cast<shaar_engine*>(0x10);
  ASSERT_TRUE(registry.Reserve(engine, 42, registry.FindCancel(SHAAR_OP_PROFILE_DELETE)));
  EXPECT_FALSE(registry.Reserve(engine, 42, &FakeCancelHandler));
  EXPECT_TRUE(registry.IsPending(engine, 42));
  EXPECT_EQ(registry.PendingCancel(engine, 42), &FakeCancelHandler);
  EXPECT_TRUE(registry.BeginCompletion(42));
  EXPECT_FALSE(registry.IsPending(engine, 42));
  EXPECT_FALSE(registry.BeginCompletion(42));
  registry.FinishCompletion(42);
  EXPECT_FALSE(registry.IsPending(engine, 42));
}

}  // namespace
