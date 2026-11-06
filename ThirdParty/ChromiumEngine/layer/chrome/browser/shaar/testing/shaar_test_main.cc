// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#include <memory>
#include <optional>

#include "base/auto_reset.h"
#include "base/test/test_suite.h"
#include "base/base_paths.h"
#include "base/path_service.h"
#include "base/test/allow_check_is_test_for_testing.h"
#include "chrome/browser/apps/app_service/app_service_proxy_factory.h"
#include "chrome/browser/apps/app_service/publishers/publisher_host_factory_impl.h"
#include "chrome/common/chrome_paths.h"
#include "chrome/test/base/testing_browser_process.h"
#include "content/public/browser/network_service_util.h"
#include "content/browser/network_service_instance_impl.h"
#include "testing/gtest/include/gtest/gtest.h"
#include "content/public/common/content_paths.h"
#include "content/public/common/content_client.h"
#include "mojo/core/embedder/embedder.h"
#include "content/public/test/content_test_suite_base.h"
#include "content/public/test/test_content_client_initializer.h"
#include "ui/base/resource/resource_bundle.h"
#include "ui/base/ui_base_paths.h"

namespace shaar {
namespace {

// Match Chromium's UnitTestTestSuite cleanup: a BrowserTaskEnvironment destroys
// its in-process service, but the cached Mojo remote otherwise survives into
// the next test and can reference the previous DNS notifier.
class NetworkServiceReset final : public testing::EmptyTestEventListener {
 public:
  void OnTestEnd(const testing::TestInfo&) override {
    content::ResetNetworkServiceForTesting();
  }
};

class ShaarTestSuite final : public content::ContentTestSuiteBase {
 public:
  ShaarTestSuite(int argc, char** argv) : ContentTestSuiteBase(argc, argv) {}

 protected:
  void Initialize() override {
    content::ForceCreateNetworkServiceDirectlyForTesting();
    content::ContentTestSuiteBase::Initialize();
    base::test::AllowCheckIsTestForTesting();
    mojo::core::Init();
    chrome::RegisterPathProvider();
    content::RegisterPathProvider();
    ui::RegisterPathProvider();
    base::FilePath output_dir;
    CHECK(base::PathService::Get(base::DIR_EXE, &output_dir));
    const base::FilePath repack_dir =
        output_dir.AppendASCII("gen").AppendASCII("repack");
    ui::ResourceBundle::InitSharedInstanceWithPakPath(
        repack_dir.AppendASCII("locales").AppendASCII("en.pak"));
    ui::ResourceBundle::GetSharedInstance().AddDataPackFromPath(
        repack_dir.AppendASCII("resources.pak"), ui::kScaleFactorNone);
    content_client_initializer_ =
        std::make_unique<content::TestContentClientInitializer>();
    content_client_initializer_->CreateTestRenderViewHosts();
    content::ContentTestSuiteBase::RegisterContentSchemes(
        content::GetContentClientForTesting());
    content::ContentTestSuiteBase::RegisterInProcessThreads();
    publisher_host_factory_resetter_ =
        apps::AppServiceProxyFactory::GetInstance()->SetPublisherHostFactory(
            std::make_unique<apps::PublisherHostFactoryImpl>());
    TestingBrowserProcess::CreateInstance();
    testing::UnitTest::GetInstance()->listeners().Append(new NetworkServiceReset());
  }

  void Shutdown() override {
    TestingBrowserProcess::TearDownAndDeleteInstance();
    publisher_host_factory_resetter_.reset();
    content_client_initializer_.reset();
    ui::ResourceBundle::CleanupSharedInstance();
    content::ContentTestSuiteBase::Shutdown();
  }

 private:
  std::unique_ptr<content::TestContentClientInitializer>
      content_client_initializer_;
  std::optional<base::AutoReset<std::unique_ptr<apps::PublisherHostFactory>>>
      publisher_host_factory_resetter_;
};

}  // namespace
}  // namespace shaar

int main(int argc, char** argv) {
  return shaar::ShaarTestSuite(argc, argv).Run();
}
