// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#include "chrome/browser/shaar/devtools/shaar_devtools.h"
#include "chrome/browser/shaar/windows_tabs/shaar_windows_tabs.h"

#include <memory>
#include <string>

#include "base/containers/span.h"
#include "base/functional/bind.h"
#include "base/json/json_reader.h"
#include "base/memory/ref_counted.h"
#include "base/task/sequenced_task_runner.h"
#include "base/test/task_environment.h"
#include "chrome/browser/shaar/engine/shaar_event_bridge.h"
#include "content/public/browser/devtools_agent_host.h"
#include "content/public/browser/devtools_agent_host_client.h"
#include "content/public/browser/render_frame_host.h"
#include "content/public/browser/web_contents.h"
#include "content/public/test/mock_devtools_agent_host.h"
#include "content/public/test/test_browser_context.h"
#include "content/public/test/test_renderer_host.h"
#include "testing/gtest/include/gtest/gtest.h"
#include "url/gurl.h"

namespace shaar::devtools {
namespace {

shaar_bytes Bytes(const std::string& value) {
  return {value.data(), value.size()};
}

class FakeDevToolsRuntime final : public DevToolsRuntimeServices {
 public:
  bool ResolveTarget(shaar_engine*, shaar_scope, shaar_window*, shaar_tab*,
                     content::WebContents*,
                     DevToolsTargetIdentity* identity) override {
    if (!allow_target || !identity)
      return false;
    *identity = {"profile-a", session_id, "window-a", "tab-a"};
    return true;
  }
  bool IsOperationAllowed(shaar_engine*, shaar_scope, content::WebContents*,
                          shaar_operation, int) override {
    return allow_operation;
  }
  bool allow_target = true;
  bool allow_operation = true;
  std::string session_id;
};

struct CapturedEvent {
  shaar_event event{};
  std::string profile;
  std::string session;
  std::string window;
  std::string tab;
  std::string payload;
};

void CaptureEvent(void* opaque, const shaar_event* event) {
  auto* captured = static_cast<CapturedEvent*>(opaque);
  captured->event = *event;
  captured->profile.assign(event->profile_id.data, event->profile_id.size);
  captured->session.assign(event->session_id.data, event->session_id.size);
  captured->window.assign(event->window_id.data, event->window_id.size);
  captured->tab.assign(event->tab_id.data, event->tab_id.size);
  captured->payload.assign(event->payload_json.data, event->payload_json.size);
}

class ReplyingAgentHost final : public content::MockDevToolsAgentHost {
 public:
  explicit ReplyingAgentHost(
      std::string response = R"({"id":44,"result":{"value":7}})")
      : response_(std::move(response)) {}
  void DispatchProtocolMessage(content::DevToolsAgentHostClient* client,
                               base::span<const uint8_t> message) override {
    request.assign(reinterpret_cast<const char*>(message.data()), message.size());
    base::SequencedTaskRunner::GetCurrentDefault()->PostTask(
        FROM_HERE, base::BindOnce(&ReplyingAgentHost::SendReply,
                                  base::WrapRefCounted(this), client));
  }
  std::string request;

 private:
  ~ReplyingAgentHost() override = default;
  void SendReply(content::DevToolsAgentHostClient* client) {
    client->DispatchProtocolMessage(this, base::as_byte_span(response_));
  }
  std::string response_;
};

class MainFrameContextAgentHost final : public content::MockDevToolsAgentHost {
 public:
  explicit MainFrameContextAgentHost(std::string frame_id)
      : frame_id_(std::move(frame_id)) {}

  void DispatchProtocolMessage(content::DevToolsAgentHostClient* client,
                               base::span<const uint8_t> message) override {
    auto parsed = base::JSONReader::Read(
        std::string_view(reinterpret_cast<const char*>(message.data()),
                         message.size()), base::JSON_PARSE_RFC);
    ASSERT_TRUE(parsed);
    ASSERT_TRUE(parsed->is_dict());
    const auto* method = parsed->GetDict().FindString("method");
    ASSERT_NE(nullptr, method);
    if (*method == "Runtime.enable") {
      base::SequencedTaskRunner::GetCurrentDefault()->PostTask(
          FROM_HERE, base::BindOnce(&MainFrameContextAgentHost::SendContexts,
                                    base::WrapRefCounted(this), client));
      return;
    }
    ASSERT_EQ("Runtime.evaluate", *method);
    evaluation = parsed->GetDict().Clone();
    base::SequencedTaskRunner::GetCurrentDefault()->PostTask(
        FROM_HERE, base::BindOnce(&MainFrameContextAgentHost::SendEvaluation,
                                  base::WrapRefCounted(this), client));
  }

  base::DictValue evaluation;

 private:
  ~MainFrameContextAgentHost() override = default;

  void Send(content::DevToolsAgentHostClient* client,
            const std::string& message) {
    client->DispatchProtocolMessage(this, base::as_byte_span(message));
  }

  void SendContexts(content::DevToolsAgentHostClient* client) {
    Send(client, R"({"id":-1,"result":{}})");
    Send(client, R"({"method":"Runtime.executionContextCreated","params":{"context":{"id":11,"auxData":{"frameId":"stale-frame","isDefault":true}}}})");
    Send(client, "{\"method\":\"Runtime.executionContextCreated\",\"params\":{\"context\":{\"id\":27,\"auxData\":{\"frameId\":\"" +
                     frame_id_ + "\",\"isDefault\":true}}}}");
  }

  void SendEvaluation(content::DevToolsAgentHostClient* client) {
    Send(client, R"({"id":44,"result":{"result":{"type":"object","value":{"documentElementPresent":true}}}})");
  }

  std::string frame_id_;
};

struct CapturedReply {
  shaar_request_id request_id = 0;
  shaar_error_code code = SHAAR_CHROMIUM_ERROR;
  std::string payload;
  std::string message;
};

void CaptureReply(void* opaque, const shaar_result* result) {
  auto* captured = static_cast<CapturedReply*>(opaque);
  captured->request_id = result->request_id;
  captured->code = result->error.code;
  captured->payload.assign(result->payload_json.data, result->payload_json.size);
  captured->message.assign(result->error.message.data,
                           result->error.message.size);
}

TEST(ShaarDevToolsTest, CommandMapIsCapabilityScoped) {
  EXPECT_STREQ("DOM.getDocument",
               ProtocolMethod(SHAAR_DEVTOOLS_CAPABILITY_INSPECTOR,
                              SHAAR_DEVTOOLS_DOM_GET_DOCUMENT));
  EXPECT_EQ(nullptr,
            ProtocolMethod(SHAAR_DEVTOOLS_CAPABILITY_DEVELOPER,
                           SHAAR_DEVTOOLS_DOM_GET_DOCUMENT));
  EXPECT_STREQ("Emulation.setLocaleOverride",
               ProtocolMethod(SHAAR_DEVTOOLS_CAPABILITY_DEVELOPER,
                              SHAAR_DEVTOOLS_EMULATION_SET_LOCALE_OVERRIDE));
  EXPECT_EQ(nullptr,
            ProtocolMethod(SHAAR_DEVTOOLS_CAPABILITY_INSPECTOR,
                           SHAAR_DEVTOOLS_NETWORK_GET_COOKIES));
  EXPECT_STREQ("Network.deleteCookies",
               ProtocolMethod(SHAAR_DEVTOOLS_CAPABILITY_DEVELOPER,
                              SHAAR_DEVTOOLS_NETWORK_DELETE_COOKIES));
  EXPECT_STREQ("Page.captureScreenshot",
               ProtocolMethod(SHAAR_DEVTOOLS_CAPABILITY_DEVELOPER,
                              SHAAR_DEVTOOLS_PAGE_CAPTURE_SCREENSHOT));
}

TEST(ShaarDevToolsTest, EncodesOnlyFixedMethodsWithNumericRequestIDs) {
  const std::string args =
      R"({"schemaVersion":1,"capability":1,"command":6,"params":{"depth":2}})";
  std::string output;
  std::string reason;
  EXPECT_EQ(SHAAR_OK,
            EncodeProtocolRequest(Bytes(args), 44, &output, &reason));
  EXPECT_NE(std::string::npos, output.find("DOM.getDocument"));
  EXPECT_NE(std::string::npos, output.find("\"id\":44"));
  EXPECT_EQ(std::string::npos, output.find("methodName"));
}

TEST(ShaarDevToolsTest, RejectsUnknownFieldsMalformedJSONAndForbiddenCommands) {
  for (const std::string args : {
           R"({"schemaVersion":1,"capability":1,"command":6,"params":{},"method":"Page.navigate"})",
           R"({bad json)",
           R"({"schemaVersion":1,"capability":1,"command":41,"params":{}})",
           R"({"schemaVersion":1,"capability":1,"command":6,"params":{"depth":2,"unreviewed":true}})",
           R"({"schemaVersion":1,"capability":3,"command":6,"params":{}})"}) {
    std::string output;
    std::string reason;
    EXPECT_NE(SHAAR_OK,
              EncodeProtocolRequest(Bytes(args), 7, &output, &reason));
    EXPECT_TRUE(output.empty());
  }
}

TEST(ShaarDevToolsTest, DeveloperCookieCommandsRequireScopedParameters) {
  for (
      const std::string args :
      {R"({"schemaVersion":1,"capability":2,"command":41,"params":{"urls":["https://example.com"]}})",
       R"({"schemaVersion":1,"capability":2,"command":42,"params":{"name":"session","value":"v","url":"https://example.com"}})",
       R"({"schemaVersion":1,"capability":2,"command":43,"params":{"name":"session","url":"https://example.com"}})"}) {
    std::string output;
    std::string reason;
    EXPECT_EQ(SHAAR_OK,
              EncodeProtocolRequest(Bytes(args), 44, &output, &reason))
        << reason;
    EXPECT_NE(std::string::npos, output.find("Network."));
  }
  for (
      const std::string args :
      {R"({"schemaVersion":1,"capability":2,"command":42,"params":{"name":"session","url":"https://example.com"}})",
       R"({"schemaVersion":1,"capability":2,"command":43,"params":{"name":"session"}})",
       R"({"schemaVersion":1,"capability":1,"command":41,"params":{}})"}) {
    std::string output;
    std::string reason;
    EXPECT_NE(SHAAR_OK,
              EncodeProtocolRequest(Bytes(args), 44, &output, &reason));
  }
}

TEST(ShaarDevToolsTest, RejectsEmptyZeroAndOutOfRangeRequestIDs) {
  const std::string args =
      R"({"schemaVersion":1,"capability":2,"command":15,"params":{}})";
  std::string output;
  std::string reason;
  EXPECT_EQ(SHAAR_INVALID_ARGUMENT,
            EncodeProtocolRequest(Bytes(args), 0, &output, &reason));
  EXPECT_EQ(SHAAR_INVALID_ARGUMENT,
            EncodeProtocolRequest(Bytes(args), UINT64_MAX, &output, &reason));
}

TEST(ShaarDevToolsTest, RequiresTypedParametersForStateChangingCommands) {
  for (const std::string args : {
           R"({"schemaVersion":1,"capability":1,"command":1,"params":{}})",
           R"({"schemaVersion":1,"capability":1,"command":12,"params":{"nodeId":"7"}})",
           R"({"schemaVersion":1,"capability":2,"command":29,"params":{"offline":true}})"}) {
    std::string output;
    std::string reason;
    EXPECT_EQ(SHAAR_INVALID_ARGUMENT,
              EncodeProtocolRequest(Bytes(args), 8, &output, &reason));
    EXPECT_EQ("DevTools command is missing required parameters", reason);
  }
}

TEST(ShaarDevToolsTest, RuntimeEvaluationCannotRequestElevatedPrivileges) {
  for (const std::string args : {
           R"({"schemaVersion":1,"capability":1,"command":1,"params":{"expression":"1","includeCommandLineAPI":true}})",
           R"({"schemaVersion":1,"capability":2,"command":1,"params":{"expression":"1","userGesture":true}})",
           R"({"schemaVersion":1,"capability":1,"command":1,"params":{"expression":"1","allowUnsafeEvalBlockedByCSP":true}})"}) {
    std::string output;
    std::string reason;
    EXPECT_EQ(SHAAR_INVALID_ARGUMENT,
              EncodeProtocolRequest(Bytes(args), 9, &output, &reason));
    EXPECT_EQ("DevTools command parameters are invalid", reason);
  }
}

TEST(ShaarDevToolsTest, ScopeIdentityAndRuntimePolicyFailClosed) {
  shaar_scope regular{sizeof(shaar_scope),
                      reinterpret_cast<shaar_profile*>(1), nullptr};
  DevToolsTargetIdentity identity{"profile-a", "", "window-a", "tab-a"};
  EXPECT_TRUE(IsValidTargetIdentity(regular, "tab-a", identity));
  EXPECT_FALSE(IsValidTargetIdentity(regular, "tab-b", identity));
  identity.session_id = "private-a";
  EXPECT_FALSE(IsValidTargetIdentity(regular, "tab-a", identity));

  FakeDevToolsRuntime runtime;
  auto* engine = reinterpret_cast<shaar_engine*>(1);
  auto* contents = reinterpret_cast<content::WebContents*>(1);
  auto* window = reinterpret_cast<shaar_window*>(2);
  auto* tab = reinterpret_cast<shaar_tab*>(3);
  DevToolsTargetIdentity resolved;
  EXPECT_TRUE(runtime.ResolveTarget(engine, regular, window, tab, contents,
                                    &resolved));
  EXPECT_TRUE(IsValidTargetIdentity(regular, "tab-a", resolved));
  runtime.allow_target = false;
  EXPECT_FALSE(runtime.ResolveTarget(engine, regular, window, tab, contents,
                                     &resolved));
  runtime.allow_target = true;
  EXPECT_TRUE(PolicyAllowsOperation(&runtime, engine, regular, contents,
                                    SHAAR_OP_DEVTOOLS_UI_SHOW, 0));
  EXPECT_FALSE(PolicyAllowsOperation(nullptr, engine, regular, contents,
                                     SHAAR_OP_DEVTOOLS_UI_SHOW, 0));
  EXPECT_FALSE(PolicyAllowsOperation(&runtime, engine, regular, contents,
                                     SHAAR_OP_DEVTOOLS_CONTROL_ENABLE, 0));
  runtime.allow_operation = false;
  EXPECT_FALSE(PolicyAllowsOperation(&runtime, engine, regular, contents,
                                     SHAAR_OP_DEVTOOLS_CALL, 1));

  shaar_scope private_scope{sizeof(shaar_scope), nullptr,
                            reinterpret_cast<shaar_private_session*>(4)};
  runtime.session_id = "private-a";
  EXPECT_TRUE(runtime.ResolveTarget(engine, private_scope, window, tab, contents,
                                    &resolved));
  EXPECT_TRUE(IsValidTargetIdentity(private_scope, "tab-a", resolved));
}

TEST(ShaarDevToolsTest, FrontendStateEventCarriesOnlyExactScopeAndState) {
  CapturedEvent captured;
  shaar_engine engine;
  engine.on_event = &CaptureEvent;
  engine.event_context = &captured;
  const DevToolsTargetIdentity identity{"profile-a", "private-a", "window-a",
                                        "tab-a"};
  EmitFrontendStateEvent(&engine, identity, true);
  EXPECT_EQ(SHAAR_EVENT_DEVTOOLS, captured.event.kind);
  EXPECT_EQ("profile-a", captured.profile);
  EXPECT_EQ("private-a", captured.session);
  EXPECT_EQ("window-a", captured.window);
  EXPECT_EQ("tab-a", captured.tab);
  EXPECT_EQ(
      R"({"schemaVersion":1,"kind":"frontendState","open":true})",
      captured.payload);
  EXPECT_EQ(1u, captured.event.sequence);
}

TEST(ShaarDevToolsTest, ProtocolClientAttachesRepliesAndDetaches) {
  base::test::TaskEnvironment tasks;
  auto host = base::MakeRefCounted<ReplyingAgentHost>();
  CapturedReply captured;
  ASSERT_TRUE(StartProtocolRequest(host, 44, &CaptureReply, &captured,
                                   R"({"id":44,"method":"DOM.getDocument"})"));
  EXPECT_TRUE(host->IsAttached());
  EXPECT_NE(std::string::npos, host->request.find("DOM.getDocument"));
  tasks.RunUntilIdle();
  EXPECT_FALSE(host->IsAttached());
  EXPECT_EQ(44u, captured.request_id);
  EXPECT_EQ(SHAAR_OK, captured.code);
  auto payload = base::JSONReader::Read(captured.payload, base::JSON_PARSE_RFC);
  ASSERT_TRUE(payload);
  ASSERT_TRUE(payload->is_dict());
  EXPECT_EQ(1, payload->GetDict().FindInt("schemaVersion"));
  const auto* result = payload->GetDict().FindDict("result");
  ASSERT_NE(nullptr, result);
  EXPECT_EQ(7, result->FindInt("value"));
}

TEST(ShaarDevToolsTest, ProtocolClientPreservesProtocolErrorMessage) {
  base::test::TaskEnvironment tasks;
  auto host = base::MakeRefCounted<ReplyingAgentHost>(
      R"({"id":44,"error":{"code":-32601,"message":"Method not found"}})");
  CapturedReply captured;
  ASSERT_TRUE(StartProtocolRequest(host, 44, &CaptureReply, &captured,
                                   R"({"id":44,"method":"Runtime.evaluate"})"));
  tasks.RunUntilIdle();
  EXPECT_FALSE(host->IsAttached());
  EXPECT_EQ(SHAAR_CHROMIUM_ERROR, captured.code);
  EXPECT_EQ("Method not found", captured.message);
}

class ScopedProtocolHost final : public content::MockDevToolsAgentHost {
 public:
  ScopedProtocolHost(content::WebContents* contents, std::string type)
      : contents_(contents), type_(std::move(type)) {}
  content::WebContents* GetWebContents() override { return contents_; }
  std::string GetType() override { return type_; }

 private:
  ~ScopedProtocolHost() override = default;
  content::WebContents* contents_;
  std::string type_;
};

TEST(ShaarDevToolsTest, ProtocolRequiresExactPageTargetForScopedTab) {
  auto* tab = reinterpret_cast<content::WebContents*>(1);
  auto* other_tab = reinterpret_cast<content::WebContents*>(2);
  auto page = base::MakeRefCounted<ScopedProtocolHost>(
      tab, content::DevToolsAgentHost::kTypePage);
  auto tab_target = base::MakeRefCounted<ScopedProtocolHost>(
      tab, content::DevToolsAgentHost::kTypeTab);
  EXPECT_TRUE(IsProtocolPageTargetFor(tab, page.get()));
  EXPECT_FALSE(IsProtocolPageTargetFor(other_tab, page.get()));
  EXPECT_FALSE(IsProtocolPageTargetFor(tab, tab_target.get()));
  EXPECT_FALSE(IsProtocolPageTargetFor(nullptr, page.get()));
  EXPECT_FALSE(IsProtocolPageTargetFor(tab, nullptr));
}

TEST(ShaarDevToolsTest, CaptureRejectsUnownedWindowTabPair) {
  shaar::windows_tabs::BrowserTabRegistryImpl registry;
  auto* engine = reinterpret_cast<shaar_engine*>(1);
  auto* owned_window = reinterpret_cast<shaar_window*>(2);
  auto* other_window = reinterpret_cast<shaar_window*>(3);
  auto* tab = reinterpret_cast<shaar_tab*>(4);
  auto* browser = reinterpret_cast<Browser*>(5);
  auto* contents = reinterpret_cast<content::WebContents*>(6);
  registry.BindWindow(engine, owned_window, browser);
  registry.BindTab(engine, owned_window, tab, "tab-a", browser, contents);
  shaar::ShaarEngineContext context{};
  context.browser_tabs = &registry;
  shaar_scope scope{sizeof(shaar_scope), reinterpret_cast<shaar_profile*>(7), nullptr};
  CapturedReply captured;
  shaar_error error{};
  error.size = sizeof(error);
  EXPECT_EQ(SHAAR_NOT_FOUND,
            HandleDevToolsOperation(&context, engine, scope, other_window, tab,
                                    SHAAR_OP_PROBE_CAPTURE_TAB,
                                    Bytes(R"({"schemaVersion":1})"), 44,
                                    &CaptureReply, &captured, &error));
  EXPECT_EQ(SHAAR_NOT_FOUND, error.code);
  EXPECT_EQ(0u, captured.request_id);
}

class ShaarPrivateDevToolsPageTargetTest
    : public content::RenderViewHostTestHarness {
 protected:
  std::unique_ptr<content::BrowserContext> CreateBrowserContext() override {
    auto context = std::make_unique<content::TestBrowserContext>();
    context->set_is_off_the_record(true);
    return context;
  }
};

TEST_F(ShaarPrivateDevToolsPageTargetTest, ProtocolUsesPrivatePageTarget) {
  ASSERT_TRUE(browser_context()->IsOffTheRecord());
  auto host = ProtocolAgentHostFor(web_contents());
  ASSERT_TRUE(host);
  EXPECT_EQ(content::DevToolsAgentHost::kTypePage, host->GetType());
  EXPECT_EQ(web_contents(), host->GetWebContents());
  auto tab_host =
      content::DevToolsAgentHost::GetOrCreateForTab(web_contents());
  ASSERT_TRUE(tab_host);
  EXPECT_NE(tab_host.get(), host.get());
}

TEST_F(ShaarPrivateDevToolsPageTargetTest,
       CrossSiteNavigationEvaluatesCurrentMainFrameDocument) {
  NavigateAndCommit(GURL("https://first.example.test/"));
  NavigateAndCommit(GURL("https://second.example.test/"));
  const std::string frame_id =
      web_contents()->GetPrimaryMainFrame()->GetDevToolsFrameToken().ToString();
  auto host = base::MakeRefCounted<MainFrameContextAgentHost>(frame_id);
  CapturedReply captured;
  ASSERT_TRUE(StartProtocolRequest(
      host, 44, &CaptureReply, &captured,
      R"({"id":44,"method":"Runtime.evaluate","params":{"expression":"!!document.documentElement","returnByValue":true}})",
      frame_id));
  task_environment()->RunUntilIdle();
  const auto* params = host->evaluation.FindDict("params");
  ASSERT_NE(nullptr, params);
  EXPECT_EQ(27, params->FindInt("contextId"));
  EXPECT_EQ("!!document.documentElement", params->FindString("expression")
                                             ? *params->FindString("expression") : "");
  EXPECT_EQ(SHAAR_OK, captured.code);
  EXPECT_NE(std::string::npos,
            captured.payload.find("documentElementPresent"));
}

TEST(ShaarDevToolsTest, CaptureRejectsUnownedWindowTabPair) {
  shaar::windows_tabs::BrowserTabRegistryImpl registry;
  auto* engine = reinterpret_cast<shaar_engine*>(1);
  auto* owned_window = reinterpret_cast<shaar_window*>(2);
  auto* other_window = reinterpret_cast<shaar_window*>(3);
  auto* tab = reinterpret_cast<shaar_tab*>(4);
  auto* browser = reinterpret_cast<Browser*>(5);
  auto* contents = reinterpret_cast<content::WebContents*>(6);
  registry.BindWindow(engine, owned_window, browser);
  registry.BindTab(engine, owned_window, tab, "tab-a", browser, contents);
  shaar::ShaarEngineContext context{};
  context.browser_tabs = &registry;
  shaar_scope scope{sizeof(shaar_scope), reinterpret_cast<shaar_profile*>(7), nullptr};
  CapturedReply captured;
  shaar_error error{};
  error.size = sizeof(error);
  EXPECT_EQ(SHAAR_NOT_FOUND,
            HandleDevToolsOperation(&context, engine, scope, other_window, tab,
                                    SHAAR_OP_PROBE_CAPTURE_TAB,
                                    Bytes(R"({"schemaVersion":1})"), 44,
                                    &CaptureReply, &captured, &error));
  EXPECT_EQ(SHAAR_NOT_FOUND, error.code);
  EXPECT_EQ(0u, captured.request_id);
}

TEST(ShaarDevToolsTest, LifecycleEntryRegistersOnlyItsOperationRange) {
  ShaarModuleRegistry registry;
  shaar_devtools_register(&registry);
  EXPECT_NE(nullptr, registry.Find(SHAAR_OP_DEVTOOLS_CALL));
  EXPECT_NE(nullptr, registry.Find(SHAAR_OP_PROBE_CAPTURE_TAB));
  EXPECT_NE(nullptr, registry.Find(SHAAR_OP_DEVTOOLS_UI_SHOW));
  EXPECT_NE(nullptr, registry.Find(SHAAR_OP_DEVTOOLS_CONTROL_STATUS));
  EXPECT_EQ(nullptr, registry.Find(SHAAR_OP_MEDIA_GET_STATE));
  EXPECT_NE(nullptr, registry.FindModule(SHAAR_MODULE_DEVTOOLS));
}

}  // namespace
}  // namespace shaar::devtools
