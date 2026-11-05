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
#include "content/public/common/content_paths.h"
#include "content/public/common/content_client.h"
#include "content/public/test/test_content_client_initializer.h"
#include "mojo/core/embedder/embedder.h"
#include "content/public/test/content_test_suite_base.h"
#include "ui/base/resource/resource_bundle.h"
#include "ui/base/ui_base_paths.h"

namespace shaar {
namespace {

class ShaarTestSuite final : public content::ContentTestSuiteBase {
 public:
  ShaarTestSuite(int argc, char** argv) : ContentTestSuiteBase(argc, argv) {}

 protected:
  void Initialize() override {
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
    content_test_clients_ =
        std::make_unique<content::TestContentClientInitializer>();
    content::ContentTestSuiteBase::RegisterContentSchemes(
        &content_client_);
    content::ContentTestSuiteBase::RegisterInProcessThreads();
    publisher_host_factory_resetter_ =
        apps::AppServiceProxyFactory::GetInstance()->SetPublisherHostFactory(
            std::make_unique<apps::PublisherHostFactoryImpl>());
    TestingBrowserProcess::CreateInstance();
  }

  void Shutdown() override {
    TestingBrowserProcess::TearDownAndDeleteInstance();
    publisher_host_factory_resetter_.reset();
    content_test_clients_.reset();
    ui::ResourceBundle::CleanupSharedInstance();
    content::ContentTestSuiteBase::Shutdown();
  }

 private:
  content::ContentClient content_client_;
  std::unique_ptr<content::TestContentClientInitializer> content_test_clients_;
  std::optional<base::AutoReset<std::unique_ptr<apps::PublisherHostFactory>>>
      publisher_host_factory_resetter_;
};

}  // namespace
}  // namespace shaar

int main(int argc, char** argv) {
  return shaar::ShaarTestSuite(argc, argv).Run();
}
