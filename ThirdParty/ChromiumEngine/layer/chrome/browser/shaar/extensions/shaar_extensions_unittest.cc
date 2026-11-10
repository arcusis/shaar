// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#include "chrome/browser/shaar/extensions/shaar_extensions.h"
#include "chrome/browser/shaar/extensions/shaar_extension_install.h"

#include <string>

#include "base/files/file_util.h"
#include "base/files/scoped_temp_dir.h"
#include "chrome/browser/shaar/engine/shaar_engine_context.h"
#include "testing/gtest/include/gtest/gtest.h"
#include "url/gurl.h"

namespace {

TEST(ShaarExtensionsModuleTest, ComponentExtensionsStayInternal) {
  using extensions::mojom::ManifestLocation;
  EXPECT_FALSE(
      shaar::extensions_host::ShouldListLocation(ManifestLocation::kComponent));
  EXPECT_FALSE(shaar::extensions_host::ShouldListLocation(
      ManifestLocation::kExternalComponent));
  EXPECT_TRUE(
      shaar::extensions_host::ShouldListLocation(ManifestLocation::kInternal));
}

TEST(ShaarExtensionsModuleTest, WebStoreFitAllowsLoopbackOnlyInTesting) {
  using shaar::extensions_host::WebStoreFitURLAllowed;
  EXPECT_TRUE(WebStoreFitURLAllowed(
      GURL("https://chromewebstore.google.com/detail/example"), false));
  EXPECT_TRUE(WebStoreFitURLAllowed(
      GURL("http://127.0.0.1:43129/web-store-fit"), true));
  EXPECT_FALSE(WebStoreFitURLAllowed(
      GURL("http://127.0.0.1:43129/web-store-fit"), false));
  EXPECT_FALSE(WebStoreFitURLAllowed(
      GURL("http://localhost:43129/web-store-fit"), true));
  EXPECT_FALSE(WebStoreFitURLAllowed(
      GURL("http://127.0.0.2:43129/web-store-fit"), true));
  EXPECT_FALSE(WebStoreFitURLAllowed(
      GURL("http://127.0.0.1:43129/other"), true));
}

TEST(ShaarExtensionsModuleTest, FrameworkDevToolsHavePinnedIdentities) {
  EXPECT_EQ(shaar::extensions_host::FrameworkDevToolsID("react"),
            "fmkadmapgofadopljbjfkapdkoienihi");
  EXPECT_EQ(shaar::extensions_host::FrameworkDevToolsID("vue"),
            "nhdogjmejiglipccpnnnanhbledajbpd");
  EXPECT_EQ(shaar::extensions_host::FrameworkDevToolsID("angular"),
            "ienfalfjdbdpebioblfackkekamfmbnh");
  EXPECT_TRUE(shaar::extensions_host::FrameworkDevToolsID("other").empty());
}

TEST(ShaarExtensionsModuleTest, FrameworkDevToolsPathCannotEscapeBundle) {
  base::ScopedTempDir bundle;
  ASSERT_TRUE(bundle.CreateUniqueTempDir());
  const base::FilePath root = bundle.GetPath().Append("FrameworkDevTools");
  ASSERT_TRUE(base::CreateDirectory(root.Append("react")));
  EXPECT_TRUE(shaar::extensions_host::ValidFrameworkDevToolsPath(
      root, root.Append("react")));
  EXPECT_FALSE(shaar::extensions_host::ValidFrameworkDevToolsPath(
      root, root.Append("../foreign")));
  EXPECT_FALSE(shaar::extensions_host::ValidFrameworkDevToolsPath(
      root, root.Append("missing")));
  ASSERT_TRUE(
      base::CreateSymbolicLink(root.Append("react"), root.Append("linked")));
  EXPECT_FALSE(shaar::extensions_host::ValidFrameworkDevToolsPath(
      root, root.Append("linked")));
}

TEST(ShaarExtensionsModuleTest, FrameworkDevToolsManifestRejectsRemoteHosts) {
  const std::string local =
      R"({"host_permissions":["http://localhost/*"],"content_scripts":[{"matches":["http://127.0.0.1/*"]}],"web_accessible_resources":[{"matches":["https://localhost/*"]}]})";
  const std::string remote =
      R"({"host_permissions":["https://example.com/*"],"content_scripts":[{"matches":["http://localhost/*"]}]})";
  const std::string remote_script =
      R"({"host_permissions":["http://localhost/*"],"content_scripts":[{"matches":["<all_urls>"]}]})";
  EXPECT_TRUE(shaar::extensions_host::FrameworkDevToolsManifestIsLocal(local));
  EXPECT_FALSE(
      shaar::extensions_host::FrameworkDevToolsManifestIsLocal(remote));
  EXPECT_FALSE(
      shaar::extensions_host::FrameworkDevToolsManifestIsLocal(remote_script));
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
  EXPECT_FALSE(
      shaar::extensions_host::ValidProbeExtensionPath(data_root, extension));
  ASSERT_TRUE(base::WriteFile(root.Append(".arcusis-probe"),
                              "arcusis-engine-probe-v1\n"));
  EXPECT_TRUE(
      shaar::extensions_host::ValidProbeExtensionPath(data_root, extension));
  EXPECT_FALSE(shaar::extensions_host::ValidProbeExtensionPath(
      data_root, root.Append("Other")));
  const auto outside = temp.GetPath().Append("outside");
  ASSERT_TRUE(base::CreateDirectory(outside));
  EXPECT_FALSE(
      shaar::extensions_host::ValidProbeExtensionPath(data_root, outside));
}

TEST(ShaarExtensionsModuleTest, ProbeComponentRejectsMissingEngineAndProfile) {
  shaar_error error = {};
  error.size = sizeof(error);
  shaar_bytes extension_id = {};
  constexpr char kPath[] = "/tmp/fixture/Extension";
  EXPECT_EQ(
      shaar_test_load_component_extension(
          nullptr, nullptr, {kPath, sizeof(kPath) - 1}, &extension_id, &error),
      SHAAR_INVALID_ARGUMENT);
  EXPECT_EQ(extension_id.data, nullptr);
}

TEST(ShaarExtensionsModuleTest, SharedInstallDoesNotConfirmOlderVersion) {
  EXPECT_FALSE(SharedHomeVersionSatisfied("1.1", "1.2"));
  EXPECT_TRUE(SharedHomeVersionSatisfied("1.2", "1.2"));
  EXPECT_TRUE(SharedHomeVersionSatisfied("1.3", "1.2"));
}

struct ManageFixture {
  EmptyProfileServices profiles;
  shaar::ShaarEngineContext context{&profiles, nullptr};
  shaar_scope scope = {};
  shaar_error error = {};

  ManageFixture() {
    scope.size = sizeof(scope);
    scope.profile = reinterpret_cast<shaar_profile*>(1);
    error.size = sizeof(error);
  }

  shaar_error_code Send(shaar_operation operation, const std::string& json) {
    return Submit(&context, scope, operation, json, &error);
  }
};

std::string ManifestV3() {
  return R"({"manifest_version":3,"name":"Probe","version":"1.0.0"})";
}

TEST(ShaarExtensionsModuleTest, DeveloperModeSchemaStopsBeforeProfileLookup) {
  ManageFixture fixture;
  EXPECT_EQ(fixture.Send(SHAAR_OP_EXTENSION_MANAGE,
                         R"({"schemaVersion":1,"action":"setDeveloperMode"})"),
            SHAAR_INVALID_ARGUMENT);
  EXPECT_EQ(fixture.profiles.resolve_calls, 0);
  EXPECT_EQ(
      fixture.Send(
          SHAAR_OP_EXTENSION_MANAGE,
          R"({"schemaVersion":1,"action":"setDeveloperMode","enabled":true,"other":1})"),
      SHAAR_INVALID_ARGUMENT);
  EXPECT_EQ(fixture.profiles.resolve_calls, 0);
}

TEST(ShaarExtensionsModuleTest, DeveloperModeReachesProfileWhenSchemaIsValid) {
  ManageFixture fixture;
  EXPECT_EQ(
      fixture.Send(
          SHAAR_OP_EXTENSION_MANAGE,
          R"({"schemaVersion":1,"action":"setDeveloperMode","enabled":true})"),
      SHAAR_NOT_FOUND);
  EXPECT_EQ(fixture.profiles.resolve_calls, 1);
}

TEST(ShaarExtensionsModuleTest, UnpackedSchemaRejectsUnsafePaths) {
  ManageFixture fixture;
  EXPECT_EQ(fixture.Send(
                SHAAR_OP_EXTENSION_MANAGE,
                R"({"schemaVersion":1,"action":"loadUnpacked","path":"ext"})"),
            SHAAR_INVALID_ARGUMENT);
  EXPECT_EQ(
      fixture.Send(
          SHAAR_OP_EXTENSION_MANAGE,
          R"({"schemaVersion":1,"action":"loadUnpacked","path":"/tmp/shaar/../etc"})"),
      SHAAR_INVALID_ARGUMENT);
  EXPECT_EQ(fixture.profiles.resolve_calls, 0);
}

TEST(ShaarExtensionsModuleTest, UnpackedSchemaRejectsManifestVersion2) {
  base::ScopedTempDir temp;
  ASSERT_TRUE(temp.CreateUniqueTempDir());
  ASSERT_TRUE(base::WriteFile(
      temp.GetPath().Append("manifest.json"),
      R"({"manifest_version":2,"name":"Probe","version":"1.0.0"})"));
  ManageFixture fixture;
  const std::string json =
      std::string(R"({"schemaVersion":1,"action":"loadUnpacked","path":")") +
      temp.GetPath().AsUTF8Unsafe() + "\"}";
  EXPECT_EQ(fixture.Send(SHAAR_OP_EXTENSION_MANAGE, json),
            SHAAR_INVALID_ARGUMENT);
  EXPECT_EQ(fixture.profiles.resolve_calls, 0);
}

TEST(ShaarExtensionsModuleTest, UnpackedManifestV3ReachesProfileLookup) {
  base::ScopedTempDir temp;
  ASSERT_TRUE(temp.CreateUniqueTempDir());
  ASSERT_TRUE(
      base::WriteFile(temp.GetPath().Append("manifest.json"), ManifestV3()));
  ManageFixture fixture;
  const std::string json =
      std::string(R"({"schemaVersion":1,"action":"loadUnpacked","path":")") +
      temp.GetPath().AsUTF8Unsafe() + "\"}";
  EXPECT_EQ(fixture.Send(SHAAR_OP_EXTENSION_MANAGE, json), SHAAR_NOT_FOUND);
  EXPECT_EQ(fixture.profiles.resolve_calls, 1);
}

TEST(ShaarExtensionsModuleTest, UnpackedFolderRejectsSymlink) {
  base::ScopedTempDir temp;
  ASSERT_TRUE(temp.CreateUniqueTempDir());
  const base::FilePath real = temp.GetPath().Append("real");
  ASSERT_TRUE(base::CreateDirectory(real));
  ASSERT_TRUE(base::WriteFile(real.Append("manifest.json"), ManifestV3()));
  const base::FilePath linked = temp.GetPath().Append("linked");
  ASSERT_TRUE(base::CreateSymbolicLink(real, linked));
  const base::FilePath absolute_real = base::MakeAbsoluteFilePath(real);
  ASSERT_FALSE(absolute_real.empty());
  base::FilePath resolved;
  EXPECT_EQ(shaar::extensions_host::InspectUnpackedFolder(linked, &resolved),
            shaar::extensions_host::UnpackedFolderStatus::kOk);
  EXPECT_EQ(resolved, absolute_real);
  EXPECT_EQ(shaar::extensions_host::InspectUnpackedFolder(real, &resolved),
            shaar::extensions_host::UnpackedFolderStatus::kOk);
  EXPECT_EQ(resolved, absolute_real);

  const base::FilePath outside = temp.GetPath().Append("outside.json");
  ASSERT_TRUE(base::WriteFile(outside, ManifestV3()));
  const base::FilePath escaped = temp.GetPath().Append("escaped");
  ASSERT_TRUE(base::CreateDirectory(escaped));
  ASSERT_TRUE(
      base::CreateSymbolicLink(outside, escaped.Append("manifest.json")));
  EXPECT_EQ(shaar::extensions_host::InspectUnpackedFolder(escaped),
            shaar::extensions_host::UnpackedFolderStatus::kInvalid);
}

TEST(ShaarExtensionsModuleTest, SiteAccessSchemaStopsBeforeProfileLookup) {
  ManageFixture fixture;
  EXPECT_EQ(
      fixture.Send(
          SHAAR_OP_EXTENSION_MANAGE,
          R"({"schemaVersion":1,"action":"setSiteAccess","extensionId":"../bad","access":"onClick","origin":"https://example.com"})"),
      SHAAR_INVALID_ARGUMENT);
  EXPECT_EQ(
      fixture.Send(
          SHAAR_OP_EXTENSION_MANAGE,
          R"({"schemaVersion":1,"action":"setSiteAccess","extensionId":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","access":"everywhere","origin":"https://example.com"})"),
      SHAAR_INVALID_ARGUMENT);
  EXPECT_EQ(
      fixture.Send(
          SHAAR_OP_EXTENSION_MANAGE,
          R"({"schemaVersion":1,"action":"setSiteAccess","extensionId":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","access":"onClick","origin":"https://example.com/path"})"),
      SHAAR_INVALID_ARGUMENT);
  EXPECT_EQ(fixture.profiles.resolve_calls, 0);
}

TEST(ShaarExtensionsModuleTest, SiteAccessReachesProfileWhenSchemaIsValid) {
  ManageFixture fixture;
  EXPECT_EQ(
      fixture.Send(
          SHAAR_OP_EXTENSION_MANAGE,
          R"({"schemaVersion":1,"action":"setSiteAccess","extensionId":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","access":"onSite","origin":"https://example.com"})"),
      SHAAR_NOT_FOUND);
  EXPECT_EQ(fixture.profiles.resolve_calls, 1);
}

TEST(ShaarExtensionsModuleTest, UnknownManageActionStopsBeforeProfileLookup) {
  ManageFixture fixture;
  EXPECT_EQ(
      fixture.Send(
          SHAAR_OP_EXTENSION_MANAGE,
          R"({"schemaVersion":1,"action":"pin","extensionId":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"})"),
      SHAAR_INVALID_ARGUMENT);
  EXPECT_EQ(fixture.profiles.resolve_calls, 0);
}

TEST(ShaarExtensionsModuleTest, InstallDecisionSchemaReachesProfileLookup) {
  ManageFixture fixture;
  EXPECT_EQ(fixture.Send(
                SHAAR_OP_EXTENSION_INSTALL_DECISION,
                R"({"schemaVersion":1,"consentRequestId":"","accepted":true})"),
            SHAAR_INVALID_ARGUMENT);
  EXPECT_EQ(fixture.profiles.resolve_calls, 0);
  EXPECT_EQ(
      fixture.Send(
          SHAAR_OP_EXTENSION_INSTALL_DECISION,
          R"({"schemaVersion":1,"consentRequestId":"7","accepted":false})"),
      SHAAR_NOT_FOUND);
  EXPECT_EQ(fixture.profiles.resolve_calls, 1);
}

TEST(ShaarExtensionsModuleTest, InstallPromptTypesMatchTheApp) {
  using shaar::extensions_host::InstallPromptEventType;
  const auto install = InstallPromptEventType(0);
  const auto external = InstallPromptEventType(5);
  const auto remote = InstallPromptEventType(8);
  const auto reenable = InstallPromptEventType(3);
  const auto permissions = InstallPromptEventType(4);
  const auto repair = InstallPromptEventType(9);
  ASSERT_TRUE(install.has_value());
  ASSERT_TRUE(external.has_value());
  ASSERT_TRUE(remote.has_value());
  ASSERT_TRUE(reenable.has_value());
  ASSERT_TRUE(permissions.has_value());
  ASSERT_TRUE(repair.has_value());
  EXPECT_EQ(*install, "install");
  EXPECT_EQ(*external, "install");
  EXPECT_EQ(*remote, "install");
  EXPECT_EQ(*reenable, "re-enable");
  EXPECT_EQ(*permissions, "permissions");
  EXPECT_EQ(*repair, "repair");
  EXPECT_FALSE(InstallPromptEventType(13).has_value());
  EXPECT_FALSE(InstallPromptEventType(15).has_value());
}

}  // namespace
