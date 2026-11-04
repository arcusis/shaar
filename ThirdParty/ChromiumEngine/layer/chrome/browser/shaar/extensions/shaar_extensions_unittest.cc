// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#include "chrome/browser/shaar/extensions/shaar_extensions.h"

#include <string>

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

shaar_error_code Submit(
    shaar::ShaarEngineContext* context,
    shaar_scope scope,
    shaar_operation operation,
    const std::string& args,
    shaar_error* error) {
  return HandleExtensionsOperation(
      context, reinterpret_cast<shaar_engine*>(1), scope, nullptr, nullptr, operation,
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

TEST(ShaarExtensionsModuleTest, AcceptsSharedHomeInstallSchemaBeforeProfileLookup) {
  EmptyProfileServices profiles;
  shaar::ShaarEngineContext context{&profiles, nullptr};
  shaar_scope scope = {};
  scope.size = sizeof(scope);
  scope.profile = reinterpret_cast<shaar_profile*>(1);
  shaar_error error = {};
  error.size = sizeof(error);
  EXPECT_EQ(Submit(&context, scope, SHAAR_OP_EXTENSION_MANAGE,
                   R"({"schemaVersion":1,"action":"install","extensionId":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","source":"sharedHome"})",
                   &error),
            SHAAR_NOT_FOUND);
  EXPECT_EQ(profiles.resolve_calls, 1);
}

}  // namespace
