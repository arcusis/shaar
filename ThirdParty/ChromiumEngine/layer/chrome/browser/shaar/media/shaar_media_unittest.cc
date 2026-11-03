// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#include "chrome/browser/shaar/media/shaar_media.h"

#include <cmath>
#include <string>
#include <unordered_map>

#include "base/run_loop.h"
#include "chrome/browser/content_settings/host_content_settings_map_factory.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/shaar/engine/shaar_event_bridge.h"
#include "chrome/browser/shaar/engine/shaar_engine_context.h"
#include "chrome/test/base/testing_profile.h"
#include "components/content_settings/core/browser/host_content_settings_map.h"
#include "components/content_settings/core/common/content_settings.h"
#include "components/content_settings/core/common/content_settings_types.h"
#include "content/public/browser/web_contents.h"
#include "content/public/test/browser_task_environment.h"
#include "content/public/test/web_contents_tester.h"
#include "services/media_session/public/mojom/media_session.mojom.h"
#include "testing/gtest/include/gtest/gtest.h"

namespace {

class TestProfileServices final : public shaar::ProfileServices {
 public:
  explicit TestProfileServices(Profile* profile) : profile_(profile) {}
  Profile* ResolveProfile(shaar_engine*, shaar_profile* handle) override {
    return handle == reinterpret_cast<shaar_profile*>(1) ? profile_ : nullptr;
  }
  std::string_view ProfileID(shaar_engine*, shaar_profile* handle) override {
    return ResolveProfile(nullptr, handle) ? "profile-1" : "";
  }
  KeyedService* GetKeyedService(shaar_engine*, shaar_profile*,
                                KeyedServiceLookup) override {
    return nullptr;
  }

 private:
  Profile* profile_;
};

class TestBrowserTabs final : public shaar::BrowserTabRegistry {
 public:
  TestBrowserTabs(shaar_window* window, shaar_tab* tab,
                  content::WebContents* contents)
      : window_(window), tab_(tab), contents_(contents) {}
  Browser* FindBrowser(shaar_engine*, shaar_window*) override { return nullptr; }
  content::WebContents* FindWebContents(shaar_engine*, shaar_window* window,
                                         shaar_tab* tab) override {
    return window == window_ && tab == tab_ ? contents_ : nullptr;
  }
  content::WebContents* FindWebContentsByID(shaar_engine*, shaar_window*,
                                             std::string_view) override {
    return nullptr;
  }
  std::string_view TabID(shaar_engine*, shaar_window* window,
                         shaar_tab* tab) override {
    return window == window_ && tab == tab_ ? "tab-1" : "";
  }
  void GetTabs(shaar_engine*, shaar_window*,
               std::unordered_map<std::string, content::WebContents*>* tabs)
      override {
    tabs->clear();
  }
  std::string_view WindowID(shaar_engine*, shaar_window* window) override {
    return window == window_ ? "window-1" : "";
  }

 private:
  shaar_window* window_;
  shaar_tab* tab_;
  content::WebContents* contents_;
};

struct ReplyCapture {
  int count = 0;
  shaar_error_code code = SHAAR_NOT_READY;
};

void CaptureReply(void* context, const shaar_result* result) {
  auto* capture = static_cast<ReplyCapture*>(context);
  ++capture->count;
  capture->code = result->error.code;
}

}  // namespace

TEST(ShaarMediaTest, ValidatesValueBoundsAndPresenceByCommand) {
  EXPECT_TRUE(shaar::media::IsValidControl(SHAAR_MEDIA_SET_ELEMENT_VOLUME, 0.5, true));
  EXPECT_FALSE(shaar::media::IsValidControl(SHAAR_MEDIA_SET_ELEMENT_VOLUME, 1.1, true));
  EXPECT_FALSE(shaar::media::IsValidControl(SHAAR_MEDIA_SET_ELEMENT_VOLUME,
                                             std::nan(""), true));
  EXPECT_TRUE(shaar::media::IsValidControl(SHAAR_MEDIA_SEEK_TO, 3600, true));
  EXPECT_FALSE(shaar::media::IsValidControl(SHAAR_MEDIA_SEEK_TO, -1, true));
  EXPECT_FALSE(shaar::media::IsValidControl(SHAAR_MEDIA_PLAY, 0, true));
  EXPECT_TRUE(shaar::media::IsValidControl(SHAAR_MEDIA_PLAY, 0, false));
  EXPECT_FALSE(shaar::media::IsValidControl(1199, 0, false));
}

TEST(ShaarMediaTest, MapsOnlySupportedChromiumSessionActions) {
  media_session::mojom::MediaSessionAction action;
  EXPECT_TRUE(shaar::media::MapSessionAction(SHAAR_MEDIA_NEXT_TRACK, &action));
  EXPECT_EQ(action, media_session::mojom::MediaSessionAction::kNextTrack);
  EXPECT_TRUE(shaar::media::MapSessionAction(SHAAR_MEDIA_SEEK_TO, &action));
  EXPECT_EQ(action, media_session::mojom::MediaSessionAction::kSeekTo);
  EXPECT_FALSE(shaar::media::MapSessionAction(SHAAR_MEDIA_SET_ELEMENT_VOLUME, &action));
  EXPECT_FALSE(shaar::media::MapSessionAction(SHAAR_MEDIA_PIP_SKIP, &action));
}

TEST(ShaarMediaTest, AutoPiPPolicyRequiresWebOrigin) {
  EXPECT_TRUE(shaar::media::IsAllowedAutoPiPURL("https://example.test/watch"));
  EXPECT_TRUE(shaar::media::IsAllowedAutoPiPURL("http://localhost:8080/video"));
  EXPECT_FALSE(shaar::media::IsAllowedAutoPiPURL("file:///tmp/video.html"));
  EXPECT_FALSE(shaar::media::IsAllowedAutoPiPURL("data:text/html,video"));
  EXPECT_FALSE(shaar::media::IsAllowedAutoPiPURL("about:blank"));
}

TEST(ShaarMediaTest, StateEventsUseTheSharedVersionedEnvelope) {
  const std::string payload = shaar::media::SerializeStateChangedEvent(
      R"({"schemaVersion":1,"playbackState":"paused"})");
  EXPECT_EQ(payload,
            R"({"kind":"state_changed","schemaVersion":1,"state":{"schemaVersion":1,"playbackState":"paused"}})");
}

TEST(ShaarMediaTest, AutoPiPPolicyIsProfileScopedAndCompletesAsynchronously) {
  content::BrowserTaskEnvironment task_environment;
  TestingProfile profile;
  auto contents = content::WebContentsTester::CreateTestWebContents(&profile, nullptr);
  const GURL url("https://example.test/watch");
  content::WebContentsTester::For(contents.get())->NavigateAndCommit(url);
  shaar_engine engine;
  auto* profile_handle = reinterpret_cast<shaar_profile*>(1);
  auto* window = reinterpret_cast<shaar_window*>(2);
  auto* tab = reinterpret_cast<shaar_tab*>(3);
  TestProfileServices profiles(&profile);
  TestBrowserTabs tabs(window, tab, contents.get());
  shaar::ShaarEngineContext context;
  context.profile_services = &profiles;
  context.browser_tabs = &tabs;
  shaar::media::InstallRuntimeServices();
  shaar_scope scope{sizeof(shaar_scope), profile_handle, nullptr};
  constexpr char kRequest[] = R"({"schemaVersion":1,"allowed":false})";
  ReplyCapture capture;
  shaar_error error{};
  error.size = sizeof(error);

  EXPECT_EQ(HandleMediaOperation(
                &context, &engine, scope, window, tab,
                SHAAR_OP_MEDIA_SET_AUTO_PIP, {kRequest, sizeof(kRequest) - 1},
                1, &CaptureReply, &capture, &error),
            SHAAR_OK);
  EXPECT_EQ(capture.count, 0);
  base::RunLoop().RunUntilIdle();
  EXPECT_EQ(capture.count, 1);
  EXPECT_EQ(capture.code, SHAAR_OK);
  EXPECT_EQ(HostContentSettingsMapFactory::GetForProfile(&profile)->GetContentSetting(
                url, GURL(), ContentSettingsType::AUTO_PICTURE_IN_PICTURE),
            CONTENT_SETTING_BLOCK);

  capture = {};
  constexpr char kCaptureList[] = R"({"schemaVersion":1})";
  EXPECT_EQ(HandleMediaOperation(
                &context, &engine, scope, window, tab,
                SHAAR_OP_MEDIA_LIST_CAPTURE_SOURCES,
                {kCaptureList, sizeof(kCaptureList) - 1}, 2, &CaptureReply,
                &capture, &error),
            SHAAR_UNSUPPORTED_CAPABILITY);
  EXPECT_EQ(capture.count, 0);

  constexpr char kCaptureReply[] =
      R"({"schemaVersion":1,"promptID":"prompt-1","decision":"approve","sourceToken":"forged"})";
  EXPECT_EQ(HandleMediaOperation(
                &context, &engine, scope, window, tab,
                SHAAR_OP_MEDIA_CAPTURE_REPLY,
                {kCaptureReply, sizeof(kCaptureReply) - 1}, 3, &CaptureReply,
                &capture, &error),
            SHAAR_PERMISSION_DENIED);
  EXPECT_EQ(capture.count, 0);

  capture = {};
  constexpr char kPrivateRequest[] = R"({"schemaVersion":1})";
  shaar_scope private_scope{sizeof(shaar_scope), nullptr,
                            reinterpret_cast<shaar_private_session*>(4)};
  EXPECT_EQ(HandleMediaOperation(
                &context, &engine, private_scope, window, tab,
                SHAAR_OP_MEDIA_GET_STATE,
                {kPrivateRequest, sizeof(kPrivateRequest) - 1}, 4,
                &CaptureReply, &capture, &error),
            SHAAR_WRONG_SESSION);
  EXPECT_EQ(capture.count, 0);
}
