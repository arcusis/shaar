// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#include "chrome/browser/shaar/windows-tabs/shaar_windows_tabs_handlers.h"
#include "chrome/browser/shaar/windows-tabs/shaar_windows_tabs.h"

#include <string>
#include <unordered_map>
#include <vector>

#include "testing/gtest/include/gtest/gtest.h"

namespace shaar::windows_tabs {
namespace {

struct CapturedHandlers {
  std::unordered_map<int, shaar::ModuleHandler> by_operation;
};

void CaptureHandler(void* context,
                    shaar_operation operation,
                    shaar::ModuleHandler handler) {
  static_cast<CapturedHandlers*>(context)->by_operation.emplace(operation,
                                                                 handler);
}

TEST(ShaarWindowsTabsHandlersTest, PlacementRequiresExactUniqueMembership) {
  EXPECT_TRUE(ValidatePlacement({"a", "b", "c"}, {"c", "b", "a"},
                                {"a", "b"}));
  EXPECT_FALSE(ValidatePlacement({"a", "a"}, {"a", "b"}, {}));
  EXPECT_FALSE(ValidatePlacement({"a", "c"}, {"a", "b"}, {}));
}

TEST(ShaarWindowsTabsHandlersTest, PinnedTabsMustBeAnOrderedPrefix) {
  EXPECT_TRUE(ValidatePlacement({"a", "b", "c"}, {"a", "b", "c"},
                                {"a", "b"}));
  EXPECT_FALSE(ValidatePlacement({"a", "b", "c"}, {"a", "b", "c"},
                                 {"b"}));
  EXPECT_FALSE(ValidatePlacement({"a", "b"}, {"a", "b"}, {"outside"}));
}

TEST(ShaarWindowsTabsHandlersTest, PlaceHandlerRejectsWrongOperationBeforeMutation) {
  shaar::ModuleCall call = {};
  call.operation = SHAAR_OP_WINDOW_ACTIVATE_TAB;
  shaar_error error = {};
  error.size = sizeof(error);
  EXPECT_EQ(HandleWindowPlaceTabs(&call, &error), SHAAR_INVALID_ARGUMENT);
}

TEST(ShaarWindowsTabsHandlersTest, RegistersEveryWindowsTabsOperation) {
  CapturedHandlers captured;
  shaar::ShaarModuleRegistry registry = {
      sizeof(shaar::ShaarModuleRegistry), &captured, CaptureHandler};
  shaar_windows_tabs_register(&registry);
  EXPECT_EQ(captured.by_operation.size(), 8u);
  EXPECT_NE(captured.by_operation.find(SHAAR_OP_WINDOW_PLACE_TABS),
            captured.by_operation.end());
  EXPECT_NE(captured.by_operation.find(SHAAR_OP_TAB_MOVE),
            captured.by_operation.end());
}

TEST(ShaarWindowsTabsHandlersTest, RegularProfileBindingIsExplicitAndStable) {
  shaar::ModuleCall call = {};
  Browser* const browser = reinterpret_cast<Browser*>(1);
  std::unordered_map<std::string, Browser*> browsers;
  call.engine = reinterpret_cast<shaar_engine*>(1);
  call.scope.size = sizeof(shaar_scope);
  call.scope.profile = reinterpret_cast<shaar_profile*>(1);
  call.window = reinterpret_cast<shaar_window*>(1);
  call.operation = SHAAR_OP_WINDOW_BIND_PROFILE;
  static constexpr char kArgs[] = R"({"schemaVersion":1,"profileID":"p"})";
  call.args_json = {kArgs, sizeof(kArgs) - 1};
  call.scope_profile_id = "p";
  call.scoped_browser = browser;
  call.browsers_by_profile = &browsers;
  shaar_error error = {};
  error.size = sizeof(error);

  EXPECT_EQ(HandleWindowBindProfile(&call, &error), SHAAR_OK);
  EXPECT_EQ(browsers.at("p"), browser);
  EXPECT_EQ(HandleWindowBindProfile(&call, &error), SHAAR_OK);
  EXPECT_EQ(browsers.size(), 1u);
}

TEST(ShaarWindowsTabsHandlersTest, ProfileBindingRejectsPrivateScope) {
  shaar::ModuleCall call = {};
  call.scope.private_session = reinterpret_cast<shaar_private_session*>(1);
  shaar_error error = {};
  error.size = sizeof(error);
  EXPECT_EQ(HandleWindowBindProfile(&call, &error), SHAAR_WRONG_SESSION);
}

TEST(ShaarWindowsTabsHandlersTest, ActiveProfileMustAlreadyBeBound) {
  shaar::ModuleCall call = {};
  Browser* const browser = reinterpret_cast<Browser*>(1);
  Browser* active_browser = nullptr;
  std::string active_profile_id;
  std::unordered_map<std::string, Browser*> browsers = {{"p", browser}};
  call.engine = reinterpret_cast<shaar_engine*>(1);
  call.scope.size = sizeof(shaar_scope);
  call.scope.profile = reinterpret_cast<shaar_profile*>(1);
  call.window = reinterpret_cast<shaar_window*>(1);
  call.operation = SHAAR_OP_WINDOW_SET_ACTIVE_PROFILE;
  static constexpr char kArgs[] = R"({"schemaVersion":1,"profileID":"p"})";
  call.args_json = {kArgs, sizeof(kArgs) - 1};
  call.active_browser = &active_browser;
  call.active_profile_id = &active_profile_id;
  call.browsers_by_profile = &browsers;
  shaar_error error = {};
  error.size = sizeof(error);

  EXPECT_EQ(HandleWindowSetActiveProfile(&call, &error), SHAAR_OK);
  EXPECT_EQ(active_browser, browser);
  EXPECT_EQ(active_profile_id, "p");
  static constexpr char kUnknown[] =
      R"({"schemaVersion":1,"profileID":"missing"})";
  call.args_json = {kUnknown, sizeof(kUnknown) - 1};
  EXPECT_EQ(HandleWindowSetActiveProfile(&call, &error), SHAAR_WRONG_PROFILE);
}

}  // namespace
}  // namespace shaar::windows_tabs
