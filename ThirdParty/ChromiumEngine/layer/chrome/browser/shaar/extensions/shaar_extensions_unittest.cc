// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#include "chrome/browser/shaar/extensions/shaar_extensions.h"

#include <string>

#include "base/test/task_environment.h"
#include "chrome/browser/shaar/engine/shaar_engine_context.h"
#include "testing/gtest/include/gtest/gtest.h"

namespace {

class EmptyProfileServices final : public shaar::ProfileServices {
 public:
  Profile* ResolveProfile(shaar_engine*, shaar_profile*) override {
    ++resolve_calls;
    return nullptr;
  }
  std::string_view ProfileID(shaar_engine*, shaar_profile*) override {
    return {};
  }
  KeyedService* GetKeyedService(shaar_engine*, shaar_profile*,
                                KeyedServiceLookup) override {
    return nullptr;
  }
  int resolve_calls = 0;
};

class FakeExtensionsRuntime final : public shaar::ExtensionsRuntimeServices {
 public:
  shaar_error_code BeginInstall(shaar_engine*, shaar_profile* profile,
                                shaar_window* window, shaar_tab* tab,
                                std::string_view extension_id,
                                std::string_view source) override {
    ++install_calls;
    last_profile = profile;
    last_window = window;
    last_tab = tab;
    last_extension_id = extension_id;
    last_source = source;
    return SHAAR_OK;
  }
  shaar_error_code ResolveInstallDecision(shaar_engine*, shaar_profile* profile,
                                          std::string_view request_id,
                                          bool accepted) override {
    ++decision_calls;
    last_profile = profile;
    last_request_id = request_id;
    last_accepted = accepted;
    return SHAAR_OK;
  }
  shaar_error_code InvokeAction(shaar_engine*, shaar_profile* profile,
                                shaar_window* window, shaar_tab* tab,
                                std::string_view extension_id,
                                std::string* route) override {
    ++action_calls;
    last_profile = profile;
    last_window = window;
    last_tab = tab;
    last_extension_id = extension_id;
    *route = "popup";
    return SHAAR_OK;
  }
  shaar_error_code ClosePopup(shaar_engine*, shaar_profile* profile,
                              shaar_window* window,
                              std::string_view popup_id) override {
    ++close_calls;
    last_profile = profile;
    last_window = window;
    last_popup_id = popup_id;
    return SHAAR_OK;
  }

  int install_calls = 0;
  int decision_calls = 0;
  int action_calls = 0;
  int close_calls = 0;
  shaar_profile* last_profile = nullptr;
  shaar_window* last_window = nullptr;
  shaar_tab* last_tab = nullptr;
  std::string last_extension_id;
  std::string last_source;
  std::string last_request_id;
  std::string last_popup_id;
  bool last_accepted = false;
};

shaar_error_code Submit(
    shaar::ShaarEngineContext* context,
    shaar_scope scope,
    shaar_operation operation,
    const std::string& args,
    shaar_error* error,
    shaar_window* window = nullptr,
    shaar_tab* tab = nullptr) {
  return HandleExtensionsOperation(
      context, reinterpret_cast<shaar_engine*>(1), scope, window, tab, operation,
      {args.data(), args.size()}, 1,
      [](void*, const shaar_result*) {}, nullptr, error);
}

TEST(ShaarExtensionsModuleTest, RegistrationAddsOnlyExtensionOperationRange) {
  ShaarModuleRegistry registry;
  shaar_extensions_register(&registry);
  EXPECT_NE(registry.Find(SHAAR_OP_EXTENSION_LIST), nullptr);
  EXPECT_NE(registry.Find(SHAAR_OP_EXTENSION_POPUP_CLOSE), nullptr);
  EXPECT_EQ(registry.Find(SHAAR_OP_TAB_FIND), nullptr);
  const auto* module = static_cast<const shaar::ExtensionsModuleHandlers*>(
      registry.FindModule(SHAAR_MODULE_EXTENSIONS));
  ASSERT_NE(module, nullptr);
  EXPECT_EQ(module->submit, &HandleExtensionsOperation);
}

TEST(ShaarExtensionsModuleTest, RejectsUnknownListFieldsBeforeProfileLookup) {
  EmptyProfileServices profiles;
  shaar::ShaarEngineContext context{&profiles, nullptr};
  shaar_scope scope = {};
  scope.size = sizeof(scope);
  scope.profile = reinterpret_cast<shaar_profile*>(1);
  shaar_error error = {};
  error.size = sizeof(error);
  EXPECT_EQ(Submit(&context, scope, SHAAR_OP_EXTENSION_LIST,
                   R"({"schemaVersion":1,"unexpected":true})", &error),
            SHAAR_INVALID_ARGUMENT);
  EXPECT_EQ(profiles.resolve_calls, 0);
}

TEST(ShaarExtensionsModuleTest, RejectsPrivateMutationWithoutResolvingRegularProfile) {
  EmptyProfileServices profiles;
  shaar::ShaarEngineContext context{&profiles, nullptr};
  shaar_scope scope = {};
  scope.size = sizeof(scope);
  scope.private_session = reinterpret_cast<shaar_private_session*>(1);
  shaar_error error = {};
  error.size = sizeof(error);
  EXPECT_EQ(Submit(&context, scope, SHAAR_OP_EXTENSION_MANAGE,
                   R"({"schemaVersion":1,"action":"uninstall","extensionId":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"})",
                   &error),
            SHAAR_PRIVATE_DISALLOWED);
  EXPECT_EQ(profiles.resolve_calls, 0);
}

TEST(ShaarExtensionsModuleTest, RejectsMalformedExtensionIDs) {
  EmptyProfileServices profiles;
  shaar::ShaarEngineContext context{&profiles, nullptr};
  shaar_scope scope = {};
  scope.size = sizeof(scope);
  scope.profile = reinterpret_cast<shaar_profile*>(1);
  shaar_error error = {};
  error.size = sizeof(error);
  EXPECT_EQ(Submit(&context, scope, SHAAR_OP_EXTENSION_MANAGE,
                   R"({"schemaVersion":1,"action":"uninstall","extensionId":"../bad"})",
                   &error),
            SHAAR_INVALID_ARGUMENT);
  EXPECT_EQ(profiles.resolve_calls, 0);
}

TEST(ShaarExtensionsModuleTest, HostOperationsKeepExactOpaqueOwnership) {
  base::test::SingleThreadTaskEnvironment task_environment;
  EmptyProfileServices profiles;
  FakeExtensionsRuntime host;
  shaar::ShaarEngineContext context{&profiles, nullptr, &host};
  shaar_scope scope = {};
  scope.size = sizeof(scope);
  auto* profile = reinterpret_cast<shaar_profile*>(1);
  auto* window = reinterpret_cast<shaar_window*>(2);
  auto* tab = reinterpret_cast<shaar_tab*>(3);
  scope.profile = profile;
  shaar_error error = {};
  error.size = sizeof(error);

  EXPECT_EQ(Submit(&context, scope, SHAAR_OP_EXTENSION_MANAGE,
                   R"({"schemaVersion":1,"action":"install","extensionId":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","source":"webStore"})",
                   &error, window, tab),
            SHAAR_OK);
  EXPECT_EQ(host.install_calls, 1);
  EXPECT_EQ(host.last_profile, profile);
  EXPECT_EQ(host.last_window, window);
  EXPECT_EQ(host.last_tab, tab);
  EXPECT_EQ(host.last_extension_id, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");
  EXPECT_EQ(host.last_source, "webStore");

  EXPECT_EQ(Submit(&context, scope, SHAAR_OP_EXTENSION_ACTION,
                   R"({"schemaVersion":1,"action":"invoke","extensionId":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"})",
                   &error, window, tab),
            SHAAR_OK);
  EXPECT_EQ(host.action_calls, 1);
  EXPECT_EQ(host.last_window, window);
  EXPECT_EQ(host.last_tab, tab);

  EXPECT_EQ(Submit(&context, scope, SHAAR_OP_EXTENSION_INSTALL_DECISION,
                   R"({"schemaVersion":1,"consentRequestId":"consent-1","accepted":false})",
                   &error),
            SHAAR_OK);
  EXPECT_EQ(host.decision_calls, 1);
  EXPECT_EQ(host.last_request_id, "consent-1");
  EXPECT_FALSE(host.last_accepted);

  EXPECT_EQ(Submit(&context, scope, SHAAR_OP_EXTENSION_POPUP_CLOSE,
                   R"({"schemaVersion":1,"popupId":"popup-1"})",
                   &error, window),
            SHAAR_OK);
  EXPECT_EQ(host.close_calls, 1);
  EXPECT_EQ(host.last_window, window);
  EXPECT_EQ(host.last_popup_id, "popup-1");
  EXPECT_EQ(profiles.resolve_calls, 0);
  task_environment.RunUntilIdle();
}

}  // namespace
