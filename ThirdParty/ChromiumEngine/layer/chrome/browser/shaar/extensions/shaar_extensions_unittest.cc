// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#include "chrome/browser/shaar/extensions/shaar_extensions.h"

#include <string>

#include "base/files/file_util.h"
#include "base/files/scoped_temp_dir.h"
#include "chrome/browser/shaar/engine/shaar_engine_context.h"
#include "testing/gtest/include/gtest/gtest.h"
#include "url/gurl.h"

namespace {

TEST(ShaarExtensionsModuleTest, ComponentExtensionsStayInternal) {
  using extensions::mojom::ManifestLocation;
  EXPECT_FALSE(shaar::extensions_host::ShouldListLocation(
      ManifestLocation::kComponent));
  EXPECT_FALSE(shaar::extensions_host::ShouldListLocation(
      ManifestLocation::kExternalComponent));
  EXPECT_TRUE(shaar::extensions_host::ShouldListLocation(
      ManifestLocation::kInternal));
}

class EmptyProfileServices final : public shaar::ProfileServices {
 public:
  Profile* ResolveProfile(shaar_engine*, shaar_profile*) override {
    ++resolve_calls;
    return nullptr;
  }
  std::string_view ProfileID(shaar_engine*, shaar_profile*) override {
    return {};
  }
  KeyedService* GetKeyedService(shaar_engine*,
                                shaar_profile*,
                                KeyedServiceLookup) override {
    return nullptr;
  }
  int resolve_calls = 0;
};

shaar_error_code Submit(shaar::ShaarEngineContext* context,
                        shaar_scope scope,
                        shaar_operation operation,
                        const std::string& args,
                        shaar_error* error) {
  return HandleExtensionsOperation(
      context, reinterpret_cast<shaar_engine*>(1), scope, nullptr, nullptr,
      operation, {args.data(), args.size()}, 1,
      [](void*, const shaar_result*) {}, nullptr, error);
}

TEST(ShaarExtensionsModuleTest, RegistrationAddsOnlyExtensionOperationRange) {
  ShaarModuleRegistry registry;
  shaar_extensions_register(&registry);
  EXPECT_NE(registry.Find(SHAAR_OP_EXTENSION_LIST), nullptr);
  EXPECT_NE(registry.Find(SHAAR_OP_EXTENSION_POPUP_CLOSE), nullptr);
  EXPECT_NE(registry.Find(SHAAR_OP_EXTENSION_WEB_STORE_ZOOM), nullptr);
  EXPECT_NE(registry.Find(SHAAR_OP_EXTENSION_ACTION_STATE), nullptr);
  EXPECT_NE(registry.Find(SHAAR_OP_EXTENSION_MANAGER_OPEN), nullptr);
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

TEST(ShaarExtensionsModuleTest,
     RejectsPrivateMutationWithoutResolvingRegularProfile) {
  EmptyProfileServices profiles;
  shaar::ShaarEngineContext context{&profiles, nullptr};
  shaar_scope scope = {};
  scope.size = sizeof(scope);
  scope.private_session = reinterpret_cast<shaar_private_session*>(1);
  shaar_error error = {};
  error.size = sizeof(error);
  EXPECT_EQ(
      Submit(
          &context, scope, SHAAR_OP_EXTENSION_MANAGE,
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
  EXPECT_EQ(
      Submit(
          &context, scope, SHAAR_OP_EXTENSION_MANAGE,
          R"({"schemaVersion":1,"action":"uninstall","extensionId":"../bad"})",
          &error),
      SHAAR_INVALID_ARGUMENT);
  EXPECT_EQ(profiles.resolve_calls, 0);
}

TEST(ShaarExtensionsModuleTest,
     RejectsMalformedWebStoreFitBeforeProfileLookup) {
  EmptyProfileServices profiles;
  shaar::ShaarEngineContext context{&profiles, nullptr};
  shaar_scope scope = {};
  scope.size = sizeof(scope);
  scope.profile = reinterpret_cast<shaar_profile*>(1);
  shaar_error error = {};
  error.size = sizeof(error);
  EXPECT_EQ(
      Submit(&context, scope, SHAAR_OP_EXTENSION_WEB_STORE_ZOOM,
             R"({"schemaVersion":1,"zoomFactor":-5,"appliedZoom":1})", &error),
      SHAAR_INVALID_ARGUMENT);
  EXPECT_EQ(profiles.resolve_calls, 0);
}

TEST(ShaarExtensionsModuleTest,
     RejectsMalformedActionStateBeforeProfileLookup) {
  EmptyProfileServices profiles;
  shaar::ShaarEngineContext context{&profiles, nullptr};
  shaar_scope scope = {};
  scope.size = sizeof(scope);
  scope.profile = reinterpret_cast<shaar_profile*>(1);
  shaar_error error = {};
  error.size = sizeof(error);
  EXPECT_EQ(Submit(&context, scope, SHAAR_OP_EXTENSION_ACTION_STATE,
                   R"({"schemaVersion":1,"extensionId":"../bad"})", &error),
            SHAAR_INVALID_ARGUMENT);
  EXPECT_EQ(profiles.resolve_calls, 0);
}

TEST(ShaarExtensionsModuleTest, SharedInstallRequiresApprovedVersion) {
  EmptyProfileServices profiles;
  shaar::ShaarEngineContext context{&profiles, nullptr};
  shaar_scope scope = {};
  scope.size = sizeof(scope);
  scope.profile = reinterpret_cast<shaar_profile*>(1);
  shaar_error error = {};
  error.size = sizeof(error);
  EXPECT_EQ(
      Submit(
          &context, scope, SHAAR_OP_EXTENSION_MANAGE,
          R"({"schemaVersion":1,"action":"install","extensionId":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","source":"sharedHome"})",
          &error),
      SHAAR_INVALID_ARGUMENT);
  EXPECT_EQ(profiles.resolve_calls, 0);
  EXPECT_EQ(
      Submit(
          &context, scope, SHAAR_OP_EXTENSION_MANAGE,
          R"({"schemaVersion":1,"action":"install","extensionId":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","source":"sharedHome","approvedVersion":"1.2.3"})",
          &error),
      SHAAR_NOT_FOUND);
  EXPECT_EQ(profiles.resolve_calls, 1);
}

TEST(ShaarExtensionsModuleTest,
     ManagerOpenRejectsUntrustedFieldsBeforeProfileLookup) {
  EmptyProfileServices profiles;
  shaar::ShaarEngineContext context{&profiles, nullptr};
  shaar_scope scope = {};
  scope.size = sizeof(scope);
  scope.profile = reinterpret_cast<shaar_profile*>(1);
  shaar_error error = {};
  error.size = sizeof(error);
  EXPECT_EQ(Submit(&context, scope, SHAAR_OP_EXTENSION_MANAGER_OPEN,
                   R"({"schemaVersion":1,"bundlePath":"../ExtensionManager"})",
                   &error),
            SHAAR_INVALID_ARGUMENT);
  EXPECT_EQ(profiles.resolve_calls, 0);
}

TEST(ShaarExtensionsModuleTest,
     PopupCloseRejectsUnknownFieldsBeforeProfileLookup) {
  EmptyProfileServices profiles;
  shaar::ShaarEngineContext context{&profiles, nullptr};
  shaar_scope scope = {};
  scope.size = sizeof(scope);
  scope.profile = reinterpret_cast<shaar_profile*>(1);
  shaar_error error = {};
  error.size = sizeof(error);
  EXPECT_EQ(
      Submit(&context, scope, SHAAR_OP_EXTENSION_POPUP_CLOSE,
             R"({"schemaVersion":1,"popupId":"popup","other":1})", &error),
      SHAAR_INVALID_ARGUMENT);
  EXPECT_EQ(profiles.resolve_calls, 0);
}

TEST(ShaarExtensionsModuleTest, PopupViewRejectsMissingOwner) {
  constexpr char kPopup[] = "popup";
  EXPECT_EQ(shaar_extension_popup_view(nullptr, nullptr,
                                       {kPopup, sizeof(kPopup) - 1}),
            nullptr);
}

TEST(ShaarExtensionsModuleTest, PopupURLMustBelongToOwningExtension) {
  EXPECT_TRUE(shaar::extensions_host::ValidPopupOrigin(
      "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      GURL("chrome-extension://aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/popup.html")));
  EXPECT_FALSE(shaar::extensions_host::ValidPopupOrigin(
      "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      GURL("chrome-extension://bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb/popup.html")));
  EXPECT_FALSE(shaar::extensions_host::ValidPopupOrigin(
      "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", GURL("https://example.com/popup")));
}

TEST(ShaarExtensionsModuleTest, ProbeComponentRequiresOwnedMarkedDirectory) {
  base::ScopedTempDir temp;
  ASSERT_TRUE(temp.CreateUniqueTempDir());
  const auto root = temp.GetPath().Append("arcusis-engine-probe-owned");
  const auto data_root = root.Append("Chromium");
  const auto extension = root.Append("Extension");
  ASSERT_TRUE(base::CreateDirectory(data_root));
  ASSERT_TRUE(base::CreateDirectory(extension));
  EXPECT_FALSE(shaar::extensions_host::ValidProbeExtensionPath(data_root, extension));
  ASSERT_TRUE(base::WriteFile(root.Append(".arcusis-probe"),
                              "arcusis-engine-probe-v1\n"));
  EXPECT_TRUE(shaar::extensions_host::ValidProbeExtensionPath(data_root, extension));
  EXPECT_FALSE(shaar::extensions_host::ValidProbeExtensionPath(
      data_root, root.Append("Other")));
  const auto outside = temp.GetPath().Append("outside");
  ASSERT_TRUE(base::CreateDirectory(outside));
  EXPECT_FALSE(shaar::extensions_host::ValidProbeExtensionPath(data_root, outside));
}

TEST(ShaarExtensionsModuleTest, ProbeComponentRejectsMissingEngineAndProfile) {
  shaar_error error = {};
  error.size = sizeof(error);
  shaar_bytes extension_id = {};
  constexpr char kPath[] = "/tmp/fixture/Extension";
  EXPECT_EQ(shaar_test_load_component_extension(
                nullptr, nullptr, {kPath, sizeof(kPath) - 1}, &extension_id,
                &error),
            SHAAR_INVALID_ARGUMENT);
  EXPECT_EQ(extension_id.data, nullptr);
}

TEST(ShaarExtensionsModuleTest, SharedInstallDoesNotConfirmOlderVersion) {
  EXPECT_FALSE(SharedHomeVersionSatisfied("1.1", "1.2"));
  EXPECT_TRUE(SharedHomeVersionSatisfied("1.2", "1.2"));
  EXPECT_TRUE(SharedHomeVersionSatisfied("1.3", "1.2"));
}

}  // namespace
