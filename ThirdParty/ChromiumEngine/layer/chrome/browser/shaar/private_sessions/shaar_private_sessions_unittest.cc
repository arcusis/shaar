// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#include "chrome/browser/shaar/private_sessions/shaar_private_sessions.h"
#include "chrome/browser/shaar/private_sessions/shaar_private_sessions_module.h"
#include "chrome/browser/shaar/private_sessions/shaar_private_trackers.h"

#include <memory>
#include <string>
#include <vector>

#include "chrome/browser/shaar/engine/shaar_engine_context.h"
#include "chrome/browser/shaar/engine/shaar_event_bridge.h"
#include "chrome/browser/content_settings/host_content_settings_map_factory.h"
#include "chrome/common/pref_names.h"
#include "chrome/test/base/testing_profile.h"
#include "components/content_settings/core/browser/host_content_settings_map.h"
#include "components/content_settings/core/common/content_settings.h"
#include "components/prefs/pref_service.h"
#include "content/public/test/browser_task_environment.h"
#include "base/functional/callback_helpers.h"
#include "base/functional/bind.h"
#include "base/run_loop.h"
#include "mojo/public/cpp/system/data_pipe_utils.h"
#include "net/base/isolation_info.h"
#include "net/traffic_annotation/network_traffic_annotation_test_helper.h"
#include "services/network/public/cpp/resource_request.h"
#include "services/network/public/cpp/weak_wrapper_shared_url_loader_factory.h"
#include "services/network/public/cpp/url_loader_factory_builder.h"
#include "services/network/test/test_url_loader_client.h"
#include "services/network/test/test_url_loader_factory.h"

#include "testing/gtest/include/gtest/gtest.h"

namespace shaar {
namespace {

class PrivateSessionRegistryTest : public testing::Test {
 protected:
  content::BrowserTaskEnvironment task_environment_;
};

// The URLLoader command pipe and URLLoaderClient response pipe are independent.
// A network loader may close its command pipe before queued response messages
// have reached this proxy. Only the response pipe can establish completion.
TEST_F(PrivateSessionRegistryTest, TrackerProxyDrainsResponseAfterLoaderCloses) {
  TestingProfile profile;
  Profile* otr = profile.GetPrimaryOTRProfile(/*create_if_needed=*/true);
  ASSERT_EQ(TrackerProtection().SetRules(&profile, "proxy-test", {"tracker.example"}),
            SHAAR_OK);
  base::ScopedClosureRunner remove_rules(base::BindOnce(
      [](Profile* parent) { TrackerProtection().RemoveProfile(parent); }, &profile));
  network::TestURLLoaderFactory upstream(/*observe_loader_requests=*/true);
  network::URLLoaderFactoryBuilder builder;
  InstallPrivateTrackerFactory(otr, net::IsolationInfo(), builder);
  auto factory = std::move(builder).Finish(upstream.GetSafeWeakWrapper());
  network::TestURLLoaderClient client;
  mojo::Remote<network::mojom::URLLoader> loader;
  network::ResourceRequest request;
  request.url = GURL("http://127.0.0.1/private-document");
  factory->CreateLoaderAndStart(loader.BindNewPipeAndPassReceiver(), 1, 0,
                               request, client.CreateRemote(),
                               net::MutableNetworkTrafficAnnotationTag(TRAFFIC_ANNOTATION_FOR_TESTS));
  task_environment_.RunUntilIdle();
  ASSERT_EQ(upstream.pending_requests()->size(), 1u);
  auto& pending = upstream.pending_requests()->front();
  pending.test_url_loader.reset();
  task_environment_.RunUntilIdle();
  EXPECT_FALSE(client.has_received_completion());
  const std::string body = "<!doctype html><body>private document ready</body>";
  upstream.SimulateResponseForPendingRequest(request.url.spec(), body);
  task_environment_.RunUntilIdle();
  ASSERT_TRUE(client.has_received_response());
  ASSERT_TRUE(client.has_received_completion());
  EXPECT_EQ(client.completion_status().error_code, net::OK);
  std::string received;
  EXPECT_TRUE(mojo::BlockingCopyToString(client.response_body_release(), &received));
  EXPECT_EQ(received, body);
}

TEST_F(PrivateSessionRegistryTest, TrackerProxyFailsWhenResponsePipeDisconnects) {
  TestingProfile profile;
  Profile* otr = profile.GetPrimaryOTRProfile(/*create_if_needed=*/true);
  ASSERT_EQ(TrackerProtection().SetRules(&profile, "proxy-test", {"tracker.example"}),
            SHAAR_OK);
  base::ScopedClosureRunner remove_rules(base::BindOnce(
      [](Profile* parent) { TrackerProtection().RemoveProfile(parent); }, &profile));
  network::TestURLLoaderFactory upstream(/*observe_loader_requests=*/true);
  network::URLLoaderFactoryBuilder builder;
  InstallPrivateTrackerFactory(otr, net::IsolationInfo(), builder);
  auto factory = std::move(builder).Finish(upstream.GetSafeWeakWrapper());
  network::TestURLLoaderClient client;
  mojo::Remote<network::mojom::URLLoader> loader;
  network::ResourceRequest request;
  request.url = GURL("http://127.0.0.1/private-document");
  factory->CreateLoaderAndStart(loader.BindNewPipeAndPassReceiver(), 1, 0,
                               request, client.CreateRemote(),
                               net::MutableNetworkTrafficAnnotationTag(TRAFFIC_ANNOTATION_FOR_TESTS));
  task_environment_.RunUntilIdle();
  ASSERT_EQ(upstream.pending_requests()->size(), 1u);
  upstream.pending_requests()->front().client.reset();
  task_environment_.RunUntilIdle();
  ASSERT_TRUE(client.has_received_completion());
  EXPECT_EQ(client.completion_status().error_code, net::ERR_ABORTED);
}

struct CapturedEvent {
  uint64_t sequence;
  shaar_event_kind kind;
  std::string profile_id;
  std::string session_id;
  std::string payload;
};

void CaptureEvent(void* context, const shaar_event* event) {
  auto* events = static_cast<std::vector<CapturedEvent>*>(context);
  events->push_back({event->sequence, event->kind,
                     std::string(event->profile_id.data, event->profile_id.size),
                     std::string(event->session_id.data, event->session_id.size),
                     std::string(event->payload_json.data,
                                 event->payload_json.size)});
}

TEST_F(PrivateSessionRegistryTest, SameParentAndIDShareOnePrimaryOTRLease) {
  TestingProfile profile;
  PrivateSessionRegistry registry;
  PrivateSessionRegistry::Session* first = nullptr;
  EXPECT_EQ(registry.Open(&profile, "profile-a", "session-a", &first), SHAAR_OK);
  ASSERT_NE(first, nullptr);
  PrivateSessionRegistry::Session* second = nullptr;
  EXPECT_EQ(registry.Open(&profile, "profile-a", "session-a", &second), SHAAR_OK);
  EXPECT_EQ(first, second);
  PrivateSessionRegistry::Session* other = nullptr;
  EXPECT_EQ(registry.Open(&profile, "profile-a", "session-b", &other),
            SHAAR_OK);
  ASSERT_NE(other, nullptr);
  EXPECT_NE(first, other);
  EXPECT_EQ(first->otr, other->otr);
  EXPECT_EQ(first->otr, profile.GetPrimaryOTRProfile(/*create_if_needed=*/false));
  EXPECT_EQ(first->open_handles, 2u);
  EXPECT_TRUE(registry.Close(first));
  EXPECT_NE(registry.Find(&profile, "session-a"), nullptr);
  EXPECT_TRUE(registry.Close(second));
  EXPECT_EQ(registry.Find(&profile, "session-a"), nullptr);
  EXPECT_EQ(profile.GetPrimaryOTRProfile(/*create_if_needed=*/false), other->otr);
  EXPECT_TRUE(registry.Close(other));
  EXPECT_EQ(profile.GetPrimaryOTRProfile(/*create_if_needed=*/false), nullptr);
}

TEST_F(PrivateSessionRegistryTest, RejectsWrongParentAndRetiredSessionIDs) {
  TestingProfile first_profile;
  TestingProfile second_profile;
  PrivateSessionRegistry registry;
  PrivateSessionRegistry::Session* session = nullptr;
  EXPECT_EQ(registry.Open(&first_profile, "profile-a", "session-a", &session),
            SHAAR_OK);
  ASSERT_NE(session, nullptr);
  PrivateSessionRegistry::Session* wrong_profile = nullptr;
  EXPECT_EQ(registry.Open(&second_profile, "profile-b", "session-a",
                          &wrong_profile),
            SHAAR_WRONG_PROFILE);
  EXPECT_EQ(wrong_profile, nullptr);
  EXPECT_TRUE(registry.Close(session));
  EXPECT_EQ(registry.Open(&first_profile, "profile-a", "session-a",
                          &wrong_profile),
            SHAAR_CONFLICT);
}

TEST_F(PrivateSessionRegistryTest, DefersRetirementUntilChildrenClose) {
  TestingProfile profile;
  PrivateSessionRegistry registry;
  PrivateSessionRegistry::Session* session = nullptr;
  ASSERT_EQ(registry.Open(&profile, "profile-a", "session-a", &session),
            SHAAR_OK);
  ASSERT_NE(session, nullptr);
  ASSERT_TRUE(registry.RetainChild(session));
  EXPECT_TRUE(registry.Close(session));
  EXPECT_EQ(registry.Find(&profile, "session-a"), nullptr);
  EXPECT_TRUE(registry.ReleaseChild(session));
  EXPECT_EQ(registry.Open(&profile, "profile-a", "session-a", &session),
            SHAAR_CONFLICT);
}

TEST_F(PrivateSessionRegistryTest,
       ExternalOTRDestructionDoesNotDoubleDestroyAtLeaseRetirement) {
  TestingProfile profile;
  PrivateSessionRegistry registry;
  PrivateSessionRegistry::Session* session = nullptr;
  ASSERT_EQ(registry.Open(&profile, "profile-a", "session-a", &session),
            SHAAR_OK);
  ASSERT_NE(session, nullptr);
  Profile* otr = profile.GetPrimaryOTRProfile(false);
  ASSERT_NE(otr, nullptr);

  profile.DestroyOffTheRecordProfile(otr);
  ASSERT_EQ(profile.GetPrimaryOTRProfile(false), nullptr);
  EXPECT_TRUE(registry.Close(session));
  EXPECT_EQ(profile.GetPrimaryOTRProfile(false), nullptr);
}

TEST_F(PrivateSessionRegistryTest, ResolvesLiveSessionAndRetainsWindowLease) {
  TestingProfile profile;
  PrivateSessionRegistry registry;
  PrivateSessionRegistry::Session *session = nullptr;
  ASSERT_EQ(registry.Open(&profile, "profile-a", "session-a", &session),
            SHAAR_OK);
  Profile *parent = nullptr;
  Profile *otr = nullptr;
  std::string_view profile_id;
  std::string_view session_id;
  ASSERT_TRUE(
      registry.Resolve(session, &parent, &otr, &profile_id, &session_id));
  EXPECT_EQ(parent, &profile);
  EXPECT_EQ(otr, profile.GetPrimaryOTRProfile(false));
  EXPECT_EQ(profile_id, "profile-a");
  EXPECT_EQ(session_id, "session-a");
  ASSERT_TRUE(registry.RetainChild(session));
  ASSERT_TRUE(registry.Close(session));
  EXPECT_FALSE(
      registry.Resolve(session, &parent, &otr, &profile_id, &session_id));
  EXPECT_NE(profile.GetPrimaryOTRProfile(false), nullptr);
  ASSERT_TRUE(registry.ReleaseChild(session));
  EXPECT_EQ(profile.GetPrimaryOTRProfile(false), nullptr);
}

TEST_F(PrivateSessionRegistryTest, CookieSettingsStayOnPrivateProfile) {
  TestingProfile profile;
  Profile *otr = profile.GetPrimaryOTRProfile(true);
  ASSERT_NE(otr, nullptr);
  bool allowed = true;
  EXPECT_EQ(
      PrivateCookieSetting(otr, "https://example.test", true, false, &allowed),
      SHAAR_OK);
  EXPECT_FALSE(allowed);
  EXPECT_EQ(
      PrivateCookieSetting(otr, "https://example.test", false, false, &allowed),
      SHAAR_OK);
  EXPECT_FALSE(allowed);
  EXPECT_EQ(PrivateCookieSetting(&profile, "https://example.test", false, false,
                                 &allowed),
            SHAAR_WRONG_PROFILE);
  EXPECT_EQ(PrivateCookieSetting(otr, "https://example.test/path", true, true,
                                 &allowed),
            SHAAR_INVALID_ARGUMENT);
  profile.DestroyOffTheRecordProfile(otr);
}

TEST_F(PrivateSessionRegistryTest, GlobalCookiesAndStorageDefaultIsOTROnly) {
  TestingProfile profile;
  auto* normal = HostContentSettingsMapFactory::GetForProfile(&profile);
  ASSERT_NE(normal, nullptr);
  const GURL inherited_site("https://allowed.example.test/");
  normal->SetContentSettingDefaultScope(inherited_site, inherited_site,
                                        ContentSettingsType::COOKIES,
                                        CONTENT_SETTING_ALLOW);
  const ContentSetting before =
      normal->GetDefaultContentSetting(ContentSettingsType::COOKIES);
  PrivateSessionRegistry registry;
  PrivateSessionRegistry::Session* session = nullptr;
  ASSERT_EQ(registry.Open(&profile, "profile-a", "private-a", &session),
            SHAAR_OK);
  auto* private_settings = HostContentSettingsMapFactory::GetForProfile(session->otr);
  ASSERT_NE(private_settings, nullptr);
  const GURL other_site("https://unrelated.example.test/");
  EXPECT_EQ(private_settings->GetContentSetting(other_site, other_site,
                                                 ContentSettingsType::COOKIES),
            CONTENT_SETTING_BLOCK);
  EXPECT_EQ(private_settings->GetContentSetting(inherited_site, inherited_site,
                                                ContentSettingsType::COOKIES),
            CONTENT_SETTING_BLOCK);
  EXPECT_EQ(normal->GetDefaultContentSetting(ContentSettingsType::COOKIES), before);
  EXPECT_TRUE(registry.Close(session));
}

TEST_F(PrivateSessionRegistryTest, HTTPSOnlyAppliesToOTRProfile) {
  TestingProfile profile;
  profile.GetPrefs()->SetBoolean(prefs::kHttpsOnlyModeEnabled, false);
  PrivateSessionRegistry registry;
  PrivateSessionRegistry::Session* session = nullptr;
  ASSERT_EQ(registry.Open(&profile, "profile-a", "private-a", &session),
            SHAAR_OK);
  EXPECT_TRUE(session->otr->GetPrefs()->GetBoolean(prefs::kHttpsOnlyModeEnabled));
  EXPECT_FALSE(profile.GetPrefs()->GetBoolean(prefs::kHttpsOnlyModeEnabled));
  EXPECT_TRUE(registry.Close(session));
}

TEST_F(PrivateSessionRegistryTest, WebRTCAndReferrerPrefsStayPrivate) {
  TestingProfile profile;
  profile.GetPrefs()->SetBoolean(prefs::kEnableReferrers, true);
  profile.GetPrefs()->SetString(prefs::kWebRTCIPHandlingPolicy, "default");
  PrivateSessionRegistry registry;
  PrivateSessionRegistry::Session* session = nullptr;
  ASSERT_EQ(registry.Open(&profile, "profile-a", "private-a", &session),
            SHAAR_OK);
  PrefService* private_prefs = session->otr->GetPrefs();
  EXPECT_FALSE(private_prefs->GetBoolean(prefs::kEnableReferrers));
  EXPECT_EQ(private_prefs->GetString(prefs::kWebRTCIPHandlingPolicy),
            "disable_non_proxied_udp");
  EXPECT_TRUE(private_prefs->GetList(prefs::kWebRTCIPHandlingUrl).empty());
  EXPECT_TRUE(private_prefs->GetList(prefs::kWebRtcLocalIpsAllowedUrls).empty());
  EXPECT_TRUE(profile.GetPrefs()->GetBoolean(prefs::kEnableReferrers));
  EXPECT_EQ(profile.GetPrefs()->GetString(prefs::kWebRTCIPHandlingPolicy),
            "default");
  EXPECT_TRUE(registry.Close(session));
}

TEST_F(PrivateSessionRegistryTest, ExtensionPolicyRejectsOnlyOTRContexts) {
  TestingProfile profile;
  PrivateSessionRegistry registry;
  PrivateSessionRegistry::Session* session = nullptr;
  ASSERT_EQ(registry.Open(&profile, "profile-a", "private-a", &session),
            SHAAR_OK);
  EXPECT_TRUE(PrivateExtensionsDisabled(session->otr));
  EXPECT_FALSE(PrivateExtensionsDisabled(&profile));
  EXPECT_TRUE(registry.Close(session));
}

TEST_F(PrivateSessionRegistryTest,
       TrackerRulesBlockThirdPartyRequestsAndRedirects) {
  TestingProfile profile;
  Profile *otr = profile.GetPrimaryOTRProfile(true);
  ASSERT_NE(otr, nullptr);
  PrivateTrackerProtection protection;
  ASSERT_EQ(protection.SetRules(&profile, "revision-1",
                                {"tracker.example", "metrics.example"}),
            SHAAR_OK);
  const url::Origin top = url::Origin::Create(GURL("https://site.example/"));
  EXPECT_FALSE(protection.ShouldBlock(
      &profile, GURL("https://tracker.example/pixel"), top));
  EXPECT_TRUE(
      protection.ShouldBlock(otr, GURL("https://tracker.example/pixel"), top));
  EXPECT_TRUE(protection.ShouldBlock(
      otr, GURL("https://a.tracker.example/redirect"), top));
  EXPECT_FALSE(
      protection.ShouldBlock(otr, GURL("https://site.example/resource"), top));
  EXPECT_EQ(protection.Status(otr).blocked_requests, 2);
  ASSERT_EQ(protection.SetAllowance(otr, "https://site.example", true),
            SHAAR_OK);
  EXPECT_FALSE(
      protection.ShouldBlock(otr, GURL("https://tracker.example/pixel"), top));
  EXPECT_FALSE(
      protection.ShouldBlock(otr, GURL("https://metrics.example/pixel"), top));
  EXPECT_EQ(protection.Status(otr).blocked_requests, 2);
  profile.DestroyOffTheRecordProfile(otr);
}

TEST_F(PrivateSessionRegistryTest, TrackerRulesRejectMalformedAndFailClosed) {
  TestingProfile profile;
  Profile *otr = profile.GetPrimaryOTRProfile(true);
  ASSERT_NE(otr, nullptr);
  PrivateTrackerProtection protection;
  const url::Origin top = url::Origin::Create(GURL("https://site.example/"));
  EXPECT_TRUE(protection.ShouldBlock(otr, GURL("https://site.example/a"), top));
  EXPECT_EQ(protection.SetRules(&profile, "revision-1", {"bad..domain"}),
            SHAAR_INVALID_ARGUMENT);
  EXPECT_EQ(protection.SetRules(&profile, "revision-1", {"tracker.example"}),
            SHAAR_OK);
  EXPECT_EQ(protection.SetRules(&profile, "revision-1", {"other.example"}),
            SHAAR_CONFLICT);
  EXPECT_EQ(protection.SetAllowance(&profile, "https://site.example", true),
            SHAAR_WRONG_PROFILE);
  EXPECT_EQ(protection.SetAllowance(otr, "https://site.example/path", true),
            SHAAR_INVALID_ARGUMENT);
  profile.DestroyOffTheRecordProfile(otr);
}

TEST_F(PrivateSessionRegistryTest, RejectsOTRParentAndEmptyIdentity) {
  TestingProfile profile;
  PrivateSessionRegistry registry;
  Profile* otr = profile.GetPrimaryOTRProfile(/*create_if_needed=*/true);
  ASSERT_NE(otr, nullptr);
  PrivateSessionRegistry::Session* session = nullptr;
  EXPECT_EQ(registry.Open(otr, "profile-a", "session-a", &session),
            SHAAR_WRONG_PROFILE);
  EXPECT_EQ(registry.Open(&profile, "profile-a", "", &session),
            SHAAR_INVALID_ARGUMENT);
}

TEST_F(PrivateSessionRegistryTest, ParentDestructionInvalidatesStaleHandles) {
  PrivateSessionRegistry registry;
  auto profile = std::make_unique<TestingProfile>();
  PrivateSessionRegistry::Session* session = nullptr;
  ASSERT_EQ(registry.Open(profile.get(), "profile-a", "session-a", &session),
            SHAAR_OK);
  ASSERT_NE(session, nullptr);
  ASSERT_TRUE(registry.RetainChild(session));

  profile.reset();

  EXPECT_EQ(registry.Find(nullptr, "session-a"), nullptr);
  EXPECT_FALSE(registry.Close(session));
  EXPECT_FALSE(registry.ReleaseChild(session));
}

TEST_F(PrivateSessionRegistryTest, ModuleRegistrationExposesDirectHandlers) {
  TestingProfile profile;
  PrivateSessionRegistry sessions;
  ShaarModuleRegistry modules;
  shaar_private_sessions_register(&modules);
  ASSERT_NE(EngineContext().private_sessions, nullptr);
  const auto* handlers = static_cast<const PrivateSessionModuleHandlers*>(
      modules.FindModule(SHAAR_MODULE_PRIVATE_SESSIONS));
  ASSERT_NE(handlers, nullptr);
  PrivateSessionRegistry::Session* session = nullptr;
  EXPECT_EQ(handlers->open(&sessions, &profile, "profile-a", "session-a", &session),
            SHAAR_OK);
  ASSERT_NE(session, nullptr);
  EXPECT_EQ(handlers->close(&sessions, session), SHAAR_OK);
  EXPECT_EQ(handlers->close(&sessions, session), SHAAR_NOT_FOUND);
}

TEST_F(PrivateSessionRegistryTest, EventsRetainParentAndSessionIDsThroughTeardown) {
  TestingProfile profile;
  std::vector<CapturedEvent> events;
  shaar_engine engine;
  engine.on_event = &CaptureEvent;
  engine.event_context = &events;
  auto registry = CreatePrivateSessionRegistry(&engine);
  PrivateSessionRegistry::Session* session = nullptr;
  ASSERT_EQ(registry->Open(&profile, "profile-uuid", "session-uuid", &session),
            SHAAR_OK);
  ASSERT_NE(session, nullptr);
  ASSERT_TRUE(registry->RetainChild(session));
  ASSERT_TRUE(registry->Close(session));
  ASSERT_TRUE(registry->ReleaseChild(session));
  ASSERT_EQ(events.size(), 3u);
  EXPECT_EQ(events[0].sequence, 1u);
  EXPECT_EQ(events[0].kind, SHAAR_EVENT_PRIVATE_SESSION);
  EXPECT_EQ(events[0].profile_id, "profile-uuid");
  EXPECT_EQ(events[0].session_id, "session-uuid");
  EXPECT_NE(events[0].payload.find("privateSession.opened"), std::string::npos);
  EXPECT_NE(events[1].payload.find("privateSession.closing"), std::string::npos);
  EXPECT_NE(events[2].payload.find("privateSession.closed"), std::string::npos);
}

TEST_F(PrivateSessionRegistryTest, PersistenceOperationsAreRejectedOnlyForPrivateScope) {
  shaar_scope regular = {};
  regular.size = sizeof(regular);
  regular.profile = reinterpret_cast<shaar_profile*>(1);
  shaar_scope private_scope = {};
  private_scope.size = sizeof(private_scope);
  private_scope.private_session = reinterpret_cast<shaar_private_session*>(1);
  EXPECT_EQ(PrivateSessionScopePolicy(private_scope, SHAAR_OP_HISTORY_INSERT),
            SHAAR_PRIVATE_DISALLOWED);
  EXPECT_EQ(PrivateSessionScopePolicy(private_scope, SHAAR_OP_BOOKMARK_APPLY),
            SHAAR_PRIVATE_DISALLOWED);
  EXPECT_EQ(PrivateSessionScopePolicy(private_scope, SHAAR_OP_DOWNLOAD_LIST),
            SHAAR_PRIVATE_DISALLOWED);
  EXPECT_EQ(PrivateSessionScopePolicy(private_scope, SHAAR_OP_SITE_SETTINGS_GET),
            SHAAR_OK);
  EXPECT_EQ(PrivateSessionScopePolicy(regular, SHAAR_OP_HISTORY_INSERT),
            SHAAR_OK);
}

}  // namespace
}  // namespace shaar
