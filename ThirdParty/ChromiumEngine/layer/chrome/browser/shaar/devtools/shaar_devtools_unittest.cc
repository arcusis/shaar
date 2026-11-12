// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#include "chrome/browser/shaar/devtools/shaar_devtools.h"
#include "chrome/browser/shaar/devtools/shaar_agent_bridge.h"
#include "chrome/browser/shaar/devtools/shaar_devtools_panel.h"
#include "chrome/browser/shaar/windows_tabs/shaar_windows_tabs.h"

#include <memory>
#include <string>

#include "base/containers/span.h"
#include "base/scoped_environment_variable_override.h"
#include "base/functional/bind.h"
#include "base/json/json_reader.h"
#include "base/json/json_writer.h"
#include "base/memory/ref_counted.h"
#include "base/task/sequenced_task_runner.h"
#include "base/test/task_environment.h"
#include "chrome/browser/shaar/engine/shaar_event_bridge.h"
#include "content/public/browser/devtools_agent_host.h"
#include "content/public/browser/devtools_agent_host_client.h"
#include "content/public/browser/render_frame_host.h"
#include "content/public/browser/web_contents.h"
#include "content/public/browser/visibility.h"
#include "content/public/test/mock_devtools_agent_host.h"
#include "content/public/test/test_browser_context.h"
#include "content/public/test/test_renderer_host.h"
#include "testing/gtest/include/gtest/gtest.h"
#include "url/gurl.h"

namespace shaar::devtools {
namespace {

TEST(ShaarAgentBridgeTest, RejectsUntrustedProtocolMethods) {
  EXPECT_TRUE(shaar::agent_bridge::AllowsPageMethod("DOM.getDocument"));
  EXPECT_TRUE(shaar::agent_bridge::AllowsPageMethod("Runtime.evaluate"));
  EXPECT_FALSE(shaar::agent_bridge::AllowsPageMethod("Input.dispatchMouseEvent"));
  EXPECT_FALSE(shaar::agent_bridge::AllowsPageMethod("Browser.setDownloadBehavior"));
  EXPECT_FALSE(shaar::agent_bridge::AllowsPageMethod("Page.setWebLifecycleState"));
  EXPECT_FALSE(shaar::agent_bridge::AllowsPageMethod("IO.read"));
}

TEST(ShaarAgentBridgeTest, RequiresExactBearerHeaderShape) {
  EXPECT_TRUE(shaar::agent_bridge::IsBearerToken(
      "Bearer AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"));
  EXPECT_FALSE(shaar::agent_bridge::IsBearerToken("Bearer short"));
  EXPECT_FALSE(shaar::agent_bridge::IsBearerToken(
      "Basic AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"));
  EXPECT_FALSE(shaar::agent_bridge::IsBearerToken(
      "Bearer AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA?"));
}

TEST(ShaarAgentBridgeTest, DefaultHasNoGrantAndRotatedSecretsDiffer) {
  EXPECT_FALSE(shaar::agent_bridge::HasActiveGrantForTesting());
  const std::string first = shaar::agent_bridge::GenerateBearerToken();
  const std::string second = shaar::agent_bridge::GenerateBearerToken();
  EXPECT_NE(first, second);
  EXPECT_TRUE(shaar::agent_bridge::IsBearerToken("Bearer " + first));
  EXPECT_TRUE(shaar::agent_bridge::IsBearerToken("Bearer " + second));
}

TEST(ShaarAgentBridgeTest, RejectsOtherTargets) {
  EXPECT_TRUE(shaar::agent_bridge::IsBoundTarget("tab-target", "tab-target"));
  EXPECT_FALSE(shaar::agent_bridge::IsBoundTarget("other", "tab-target"));
  EXPECT_FALSE(shaar::agent_bridge::IsBoundTarget("", "tab-target"));
}

TEST(ShaarAgentBridgeTest, PrivateScopeIsDeniedBeforeServerCreation) {
  shaar_scope scope{};
  scope.size = sizeof(scope);
  scope.private_session = reinterpret_cast<shaar_private_session*>(1);
  shaar_error error{};
  error.size = sizeof(error);
  EXPECT_EQ(shaar::agent_bridge::HandleOperation(
                nullptr, scope, nullptr, nullptr, nullptr, {},
                SHAAR_OP_DEVTOOLS_CONTROL_ENABLE, 1,
                [](void*, const shaar_result*) {}, nullptr, &error),
            SHAAR_PRIVATE_DISALLOWED);
}

shaar_bytes Bytes(const std::string& value) {
  return {value.data(), value.size()};
}

TEST(ShaarDevToolsTest, ProbeInputPolicyAndPayloads) {
  int x = -1;
  int y = -1;
  std::string element_id;
  EXPECT_TRUE(ParseProbeClickArguments(
      Bytes(R"({"schemaVersion":1,"x":20,"y":30})"), &x, &y,
      &element_id));
  EXPECT_EQ(20, x);
  EXPECT_EQ(30, y);
  EXPECT_TRUE(element_id.empty());
  EXPECT_TRUE(ParseProbeClickArguments(
      Bytes(R"({"schemaVersion":1,"elementID":"parity-action"})"), &x,
      &y, &element_id));
  EXPECT_EQ("parity-action", element_id);
  EXPECT_TRUE(ParseProbeScrollArguments(
      Bytes(R"({"schemaVersion":1,"elementID":"feed"})"), &element_id));
  EXPECT_EQ("feed", element_id);
  EXPECT_FALSE(ParseProbeScrollArguments(
      Bytes(R"({"schemaVersion":1,"x":20,"y":30})"), &element_id));
  for (const std::string invalid : {
           R"({"schemaVersion":1,"x":-1,"y":2})",
           R"({"schemaVersion":1,"x":20,"y":8192})",
           R"({"schemaVersion":1,"x":20.5,"y":2})",
           R"({"schemaVersion":1,"x":20,"y":2,"method":"open"})",
           R"({"schemaVersion":2,"x":20,"y":2})",
           "{\"schemaVersion\":1,\"elementID\":\"bad';alert(1)\"}"}) {
    EXPECT_FALSE(ParseProbeClickArguments(Bytes(invalid), &x, &y,
                                          &element_id));
  }
  int port = 0;
  EXPECT_TRUE(ParseNodeProbePort(
      Bytes(R"({"schemaVersion":1,"nodeInspectPort":9229})"), &port));
  EXPECT_EQ(9229, port);
  EXPECT_FALSE(ParseNodeProbePort(
      Bytes(R"({"schemaVersion":1,"nodeInspectPort":0})"), &port));
  EXPECT_FALSE(ParseNodeProbePort(
      Bytes(R"({"schemaVersion":1,"nodeInspectPort":65536})"), &port));
  EXPECT_FALSE(ParseNodeProbePort(
      Bytes(R"({"schemaVersion":1,"nodeInspectPort":9229,"url":"remote"})"),
      &port));
  const GURL fixture("http://127.0.0.1:8123/cross-site-a");
  EXPECT_TRUE(ProbeWindowAllowed(true, true, true, true, fixture));
  EXPECT_FALSE(ProbeWindowAllowed(false, true, true, true, fixture));
  EXPECT_FALSE(ProbeWindowAllowed(true, false, true, true, fixture));
  EXPECT_FALSE(ProbeWindowAllowed(true, true, false, true, fixture));
  EXPECT_FALSE(ProbeWindowAllowed(true, true, true, false, fixture));
  EXPECT_FALSE(ProbeWindowAllowed(true, true, true, true,
                                 GURL("https://example.com/")));
}

TEST(ShaarDevToolsTest, PopupProbeArgumentsStayBoundToOneHiddenPopup) {
  const char* popup = "11111111-2222-4333-8444-555555555555";
  std::string id;
  std::string expression;
  EXPECT_TRUE(ParseProbePopupArguments(
      Bytes(std::string(R"({"schemaVersion":1,"popupId":")") + popup +
            R"(","expression":"window.probeState"})"),
      true, &id, &expression));
  EXPECT_EQ(popup, id);
  EXPECT_EQ("window.probeState", expression);
  EXPECT_TRUE(ParseProbePopupArguments(
      Bytes(std::string(R"({"schemaVersion":1,"popupId":")") + popup + "\"}"),
      false, &id, nullptr));
  EXPECT_FALSE(ParseProbePopupArguments(
      Bytes(std::string(R"({"schemaVersion":1,"popupId":")") + popup +
            R"(","expression":"1","awaitPromise":true})"),
      true, &id, &expression));
  EXPECT_FALSE(ParseProbePopupArguments(
      Bytes(R"({"schemaVersion":1,"popupId":"NOT-A-POPUP","expression":"1"})"),
      true, &id, &expression));
  EXPECT_FALSE(ParseProbePopupArguments(
      Bytes(std::string(R"({"schemaVersion":1,"popupId":")") + popup +
            R"(","expression":""})"),
      true, &id, &expression));
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
      ++runtime_enables;
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
  int runtime_enables = 0;
  void NavigateToNewContext() {
    context_id_ = 81;
    Send(client_, R"({"method":"Runtime.executionContextsCleared"})");
  }

 private:
  ~MainFrameContextAgentHost() override = default;

  void Send(content::DevToolsAgentHostClient* client,
            const std::string& message) {
    client->DispatchProtocolMessage(this, base::as_byte_span(message));
  }

  void SendContexts(content::DevToolsAgentHostClient* client) {
    Send(client, R"({"id":-1,"result":{}})");
    Send(client, R"({"method":"Runtime.executionContextCreated","params":{"context":{"id":11,"auxData":{"frameId":"stale-frame","isDefault":true}}}})");
    Send(client, "{\"method\":\"Runtime.executionContextCreated\",\"params\":{\"context\":{\"id\":" + std::to_string(context_id_) + ",\"auxData\":{\"frameId\":\"" +
                     frame_id_ + "\",\"isDefault\":true}}}}");
  }

  void SendEvaluation(content::DevToolsAgentHostClient* client) {
    Send(client, R"({"id":44,"result":{"result":{"type":"object","value":{"documentElementPresent":true}}}})");
  }

  std::string frame_id_;
  int context_id_ = 27;
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

// Remote objects and enabled domains belong to one CDP attachment.
class InspectorSessionHost final : public content::MockDevToolsAgentHost {
 public:
  bool AttachClient(content::DevToolsAgentHostClient* client) override {
    ++attachments;
    return MockDevToolsAgentHost::AttachClient(client);
  }
  bool DetachClient(content::DevToolsAgentHostClient* client) override {
    dom_enabled = css_enabled = object_created = false;
    return MockDevToolsAgentHost::DetachClient(client);
  }
  void DispatchProtocolMessage(content::DevToolsAgentHostClient* client,
                               base::span<const uint8_t> message) override {
    auto parsed = base::JSONReader::Read(std::string_view(
        reinterpret_cast<const char*>(message.data()), message.size()),
        base::JSON_PARSE_RFC);
    ASSERT_TRUE(parsed && parsed->is_dict());
    const auto& command = parsed->GetDict();
    const auto* method = command.FindString("method");
    ASSERT_TRUE(method);
    base::DictValue response;
    response.Set("id", command.FindInt("id").value());
    base::DictValue result;
    if (*method == "DOM.enable") dom_enabled = true;
    if (*method == "CSS.enable") css_enabled = true;
    if (*method == "DOM.getDocument") {
      EXPECT_TRUE(dom_enabled);
      result.Set("root", base::DictValue().Set("nodeId", 7));
    }
    if (*method == "Runtime.evaluate") {
      object_created = true;
      result.Set("result", base::DictValue().Set("objectId", "session-object"));
    }
    if (*method == "DOM.requestNode") {
      EXPECT_TRUE(dom_enabled);
      EXPECT_TRUE(css_enabled);
      EXPECT_TRUE(object_created);
      EXPECT_EQ("session-object", *command.FindDict("params")->FindString("objectId"));
      result.Set("nodeId", 7);
    }
    response.Set("result", std::move(result));
    std::string json;
    base::JSONWriter::Write(response, &json);
    client->DispatchProtocolMessage(this, base::as_byte_span(json));
  }
  int attachments = 0;
  bool dom_enabled = false;
  bool css_enabled = false;
  bool object_created = false;
 private:
  ~InspectorSessionHost() override = default;
};

TEST(ShaarDevToolsTest, InspectorSequenceKeepsDomainsNodesAndObjectsInOneSession) {
  base::test::TaskEnvironment tasks;
  auto host = base::MakeRefCounted<InspectorSessionHost>();
  const char* commands[] = {
      R"({"id":1,"method":"Page.enable"})",
      R"({"id":2,"method":"DOM.enable"})",
      R"({"id":3,"method":"DOM.getDocument"})",
      R"({"id":4,"method":"CSS.enable"})",
      R"({"id":5,"method":"Runtime.evaluate","params":{"expression":"document.body"}})",
      R"({"id":6,"method":"DOM.requestNode","params":{"objectId":"session-object"}})"};
  for (size_t i = 0; i < std::size(commands); ++i) {
    CapturedReply reply;
    ASSERT_TRUE(StartProtocolRequest(host, i + 1, &CaptureReply, &reply, commands[i]));
    tasks.RunUntilIdle();
    EXPECT_EQ(SHAAR_OK, reply.code);
  }
  EXPECT_EQ(1, host->attachments);
  EXPECT_TRUE(host->IsAttached());
  auto other = base::MakeRefCounted<InspectorSessionHost>();
  EXPECT_FALSE(other->dom_enabled);
  CloseProtocolSessionForTesting(host.get());
  EXPECT_FALSE(host->IsAttached());
}

class PendingSessionHost final : public content::MockDevToolsAgentHost {
 public:
  void DispatchProtocolMessage(content::DevToolsAgentHostClient*,
                               base::span<const uint8_t>) override {}
  void CloseTarget() {
    auto* client = client_.get();
    client_ = nullptr;
    client->AgentHostClosed(this);
  }
 private:
  ~PendingSessionHost() override = default;
};

TEST(ShaarDevToolsTest, TargetClosureFailsActiveAndQueuedRequests) {
  base::test::TaskEnvironment tasks;
  auto host = base::MakeRefCounted<PendingSessionHost>();
  CapturedReply first, second;
  ASSERT_TRUE(StartProtocolRequest(host, 1, &CaptureReply, &first,
                                  R"({"id":1,"method":"DOM.enable"})"));
  ASSERT_TRUE(StartProtocolRequest(host, 2, &CaptureReply, &second,
                                  R"({"id":2,"method":"DOM.getDocument"})"));
  host->CloseTarget();
  tasks.RunUntilIdle();
  EXPECT_EQ(SHAAR_NOT_FOUND, first.code);
  EXPECT_EQ(SHAAR_NOT_FOUND, second.code);
  EXPECT_EQ(1u, first.request_id);
  EXPECT_EQ(2u, second.request_id);
  EXPECT_FALSE(host->IsAttached());
}

TEST(ShaarDevToolsTest, PersistentSessionDropsExecutionContextOnNavigation) {
  base::test::TaskEnvironment tasks;
  auto host = base::MakeRefCounted<MainFrameContextAgentHost>("main-frame");
  const std::string command = R"({"id":44,"method":"Runtime.evaluate","params":{"expression":"document.body"}})";
  CapturedReply before, after;
  ASSERT_TRUE(StartProtocolRequest(host, 44, &CaptureReply, &before, command, "main-frame"));
  tasks.RunUntilIdle();
  EXPECT_EQ(SHAAR_OK, before.code);
  EXPECT_EQ(27, host->evaluation.FindDict("params")->FindInt("contextId"));
  host->NavigateToNewContext();
  ASSERT_TRUE(StartProtocolRequest(host, 44, &CaptureReply, &after, command, "main-frame"));
  tasks.RunUntilIdle();
  EXPECT_EQ(SHAAR_OK, after.code);
  EXPECT_EQ(81, host->evaluation.FindDict("params")->FindInt("contextId"));
  EXPECT_EQ(2, host->runtime_enables);
  CloseProtocolSessionForTesting(host.get());
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
  EXPECT_STREQ("Page.handleJavaScriptDialog",
               ProtocolMethod(SHAAR_DEVTOOLS_CAPABILITY_DEVELOPER,
                              SHAAR_DEVTOOLS_PAGE_HANDLE_JAVASCRIPT_DIALOG));
  EXPECT_EQ(nullptr,
            ProtocolMethod(SHAAR_DEVTOOLS_CAPABILITY_INSPECTOR,
                           SHAAR_DEVTOOLS_PAGE_HANDLE_JAVASCRIPT_DIALOG));
}

TEST(ShaarDevToolsTest, QuitDialogCancellationIsRestrictedToTestingProbes) {
  const std::string envelope =
      R"({"schemaVersion":1,"capability":2,"command":45,"probeQuitDialogCancellation":true,"params":{"accept":false}})";
  std::string encoded;
  std::string reason;
  {
    base::ScopedEnvironmentVariableOverride env("SHAAR_ENGINE_TESTING", "0");
    EXPECT_EQ(SHAAR_POLICY_BLOCKED,
              EncodeProtocolRequest(Bytes(envelope), 44, &encoded, &reason));
  }
  base::ScopedEnvironmentVariableOverride env("SHAAR_ENGINE_TESTING", "1");
  EXPECT_EQ(SHAAR_OK,
            EncodeProtocolRequest(Bytes(envelope), 44, &encoded, &reason))
      << reason;
  EXPECT_NE(std::string::npos, encoded.find("Page.handleJavaScriptDialog"));
  EXPECT_EQ(std::string::npos, encoded.find("probeQuitDialogCancellation"));
  for (const std::string invalid : {
           R"({"schemaVersion":1,"capability":2,"command":45,"params":{"accept":false}})",
           R"({"schemaVersion":1,"capability":2,"command":45,"probeQuitDialogCancellation":true,"params":{"accept":true}})",
           R"({"schemaVersion":1,"capability":2,"command":45,"probeQuitDialogCancellation":true,"params":{"accept":false,"promptText":"unused"}})",
           R"({"schemaVersion":1,"capability":1,"command":45,"probeQuitDialogCancellation":true,"params":{"accept":false}})"}) {
    EXPECT_NE(SHAAR_OK,
              EncodeProtocolRequest(Bytes(invalid), 44, &encoded, &reason));
  }
}

TEST(ShaarDevToolsTest, SafeAreaInsetsAreBoundedAndDeveloperOnly) {
  EXPECT_STREQ("Emulation.setSafeAreaInsetsOverride",
               ProtocolMethod(SHAAR_DEVTOOLS_CAPABILITY_DEVELOPER,
                              SHAAR_DEVTOOLS_EMULATION_SET_SAFE_AREA_INSETS_OVERRIDE));
  EXPECT_EQ(nullptr,
            ProtocolMethod(SHAAR_DEVTOOLS_CAPABILITY_INSPECTOR,
                           SHAAR_DEVTOOLS_EMULATION_SET_SAFE_AREA_INSETS_OVERRIDE));
  for (const std::string args : {
           R"({"schemaVersion":1,"capability":2,"command":44,"params":{"insets":{"top":59,"bottom":34,"topMax":59,"bottomMax":34}}})",
           R"({"schemaVersion":1,"capability":2,"command":44,"params":{"insets":{}}})"}) {
    std::string output;
    std::string reason;
    EXPECT_EQ(SHAAR_OK, EncodeProtocolRequest(Bytes(args), 44, &output, &reason))
        << reason;
    EXPECT_NE(std::string::npos,
              output.find("Emulation.setSafeAreaInsetsOverride"));
  }
  for (const std::string args : {
           R"({"schemaVersion":1,"capability":1,"command":44,"params":{"insets":{}}})",
           R"({"schemaVersion":1,"capability":2,"command":44,"params":{}})",
           R"({"schemaVersion":1,"capability":2,"command":44,"params":{"insets":{"top":-1}}})",
           R"({"schemaVersion":1,"capability":2,"command":44,"params":{"insets":{"top":201}}})",
           R"({"schemaVersion":1,"capability":2,"command":44,"params":{"insets":{"top":1.5}}})",
           R"({"schemaVersion":1,"capability":2,"command":44,"params":{"insets":{"unreviewed":1}}})"}) {
    std::string output;
    std::string reason;
    EXPECT_NE(SHAAR_OK, EncodeProtocolRequest(Bytes(args), 44, &output, &reason));
    EXPECT_TRUE(output.empty());
  }
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

TEST(ShaarDevToolsTest, ProtocolClientKeepsSessionUntilTargetCloses) {
  base::test::TaskEnvironment tasks;
  auto host = base::MakeRefCounted<ReplyingAgentHost>();
  CapturedReply captured;
  ASSERT_TRUE(StartProtocolRequest(host, 44, &CaptureReply, &captured,
                                   R"({"id":44,"method":"DOM.getDocument"})"));
  EXPECT_TRUE(host->IsAttached());
  EXPECT_NE(std::string::npos, host->request.find("DOM.getDocument"));
  tasks.RunUntilIdle();
  EXPECT_TRUE(host->IsAttached());
  CloseProtocolSessionForTesting(host.get());
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
  EXPECT_TRUE(host->IsAttached());
  CloseProtocolSessionForTesting(host.get());
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
  const std::string first_frame_id =
      web_contents()->GetPrimaryMainFrame()->GetDevToolsFrameToken().ToString();
  NavigateAndCommit(GURL("https://second.example.test/"));
  const std::string frame_id =
      web_contents()->GetPrimaryMainFrame()->GetDevToolsFrameToken().ToString();
  // CDP frame identity is stable across document navigations; the execution
  // context must be selected again for the newly committed document.
  ASSERT_EQ(first_frame_id, frame_id);
  ASSERT_EQ(GURL("https://second.example.test/"),
            web_contents()->GetLastCommittedURL());
  auto host = base::MakeRefCounted<MainFrameContextAgentHost>(frame_id);
  CapturedReply captured;
  ASSERT_TRUE(StartProtocolRequest(
      host, 44, &CaptureReply, &captured,
      R"({"id":44,"method":"Runtime.evaluate","params":{"expression":"!!document.documentElement","returnByValue":true}})",
      frame_id));
  task_environment()->RunUntilIdle();
  CloseProtocolSessionForTesting(host.get());
  const auto* params = host->evaluation.FindDict("params");
  ASSERT_NE(nullptr, params);
  EXPECT_EQ(27, params->FindInt("contextId"));
  EXPECT_EQ("!!document.documentElement", params->FindString("expression")
                                             ? *params->FindString("expression") : "");
  EXPECT_EQ(SHAAR_OK, captured.code);
  EXPECT_NE(std::string::npos,
            captured.payload.find("documentElementPresent"));
}

TEST_F(ShaarPrivateDevToolsPageTargetTest,
       HiddenProbeCaptureTemporarilyShowsRendererAndRestoresHiddenState) {
  web_contents()->WasHidden();
  ASSERT_EQ(content::Visibility::HIDDEN, web_contents()->GetVisibility());
  ASSERT_FALSE(web_contents()->IsBeingCaptured());

  auto capture = StartHiddenProbeCapture(web_contents());
  EXPECT_EQ(content::Visibility::VISIBLE, web_contents()->GetVisibility());
  EXPECT_TRUE(web_contents()->IsBeingCaptured());

  capture.RunAndReset();
  EXPECT_EQ(content::Visibility::HIDDEN, web_contents()->GetVisibility());
  EXPECT_FALSE(web_contents()->IsBeingCaptured());
}

TEST_F(ShaarPrivateDevToolsPageTargetTest,
       HiddenProbeCaptureRestoresOccludedState) {
  web_contents()->WasOccluded();
  ASSERT_EQ(content::Visibility::OCCLUDED, web_contents()->GetVisibility());

  auto capture = StartHiddenProbeCapture(web_contents());
  EXPECT_EQ(content::Visibility::VISIBLE, web_contents()->GetVisibility());

  capture.RunAndReset();
  EXPECT_EQ(content::Visibility::OCCLUDED, web_contents()->GetVisibility());
}


TEST(ShaarDevToolsTest, RendererVisibilityProbeIsExplicitTestingOnlyAndNotForwarded) {
  const std::string envelope = R"({"schemaVersion":1,"capability":2,"command":1,"probeVisibleForRenderer":true,"params":{"expression":"document.visibilityState","awaitPromise":true,"returnByValue":true}})";
  std::string encoded, reason;
  {
    base::ScopedEnvironmentVariableOverride env("SHAAR_ENGINE_TESTING", "0");
    EXPECT_EQ(SHAAR_POLICY_BLOCKED,
              EncodeProtocolRequest(Bytes(envelope), 44, &encoded, &reason));
  }
  base::ScopedEnvironmentVariableOverride env("SHAAR_ENGINE_TESTING", "1");
  EXPECT_EQ(SHAAR_OK, EncodeProtocolRequest(Bytes(envelope), 44, &encoded, &reason));
  EXPECT_EQ(std::string::npos, encoded.find("probeVisibleForRenderer"));
  auto value = base::JSONReader::Read(envelope, base::JSON_PARSE_RFC);
  value->GetDict().Set("capability", 1);
  std::string invalid;
  base::JSONWriter::Write(*value, &invalid);
  EXPECT_EQ(SHAAR_INVALID_ARGUMENT,
            EncodeProtocolRequest(Bytes(invalid), 44, &encoded, &reason));
  value->GetDict().Set("capability", 2);
  value->GetDict().FindDict("params")->Set("awaitPromise", false);
  base::JSONWriter::Write(*value, &invalid);
  EXPECT_EQ(SHAAR_INVALID_ARGUMENT,
            EncodeProtocolRequest(Bytes(invalid), 44, &encoded, &reason));
}

TEST(ShaarDevToolsTest, ProtocolReleasesVisibilityLeaseBeforeSuccessAndErrorReply) {
  base::test::TaskEnvironment tasks;
  for (const std::string response : {
           R"({"id":44,"result":{}})",
           R"({"id":44,"error":{"message":"failed"}})"}) {
    auto host = base::MakeRefCounted<ReplyingAgentHost>(response);
    bool restored = false;
    bool replied = false;
    std::pair<bool*, bool*> flags(&restored, &replied);
    ASSERT_TRUE(StartProtocolRequest(
        host, 44, [](void* context, const shaar_result*) {
          auto* flags = static_cast<std::pair<bool*, bool*>*>(context);
          EXPECT_TRUE(*flags->first);
          *flags->second = true;
        }, &flags, R"({"id":44,"method":"Runtime.evaluate"})", {},
        base::ScopedClosureRunner(base::BindOnce([](bool* flag) { *flag = true; }, &restored))));
    EXPECT_FALSE(restored);
    tasks.RunUntilIdle();
    EXPECT_TRUE(replied);
    CloseProtocolSessionForTesting(host.get());
  }
}

TEST(ShaarDevToolsTest, ProtocolReleasesVisibilityLeaseOnTimeoutAndClose) {
  base::test::TaskEnvironment tasks(base::test::TaskEnvironment::TimeSource::MOCK_TIME);
  for (bool timeout : {false, true}) {
    auto host = base::MakeRefCounted<content::MockDevToolsAgentHost>();
    bool restored = false;
    CapturedReply captured;
    ASSERT_TRUE(StartProtocolRequest(host, 44, &CaptureReply, &captured,
        R"({"id":44,"method":"Runtime.evaluate"})", {},
        base::ScopedClosureRunner(base::BindOnce([](bool* flag) { *flag = true; }, &restored))));
    if (timeout)
      tasks.FastForwardBy(base::Seconds(16));
    else
      CloseProtocolSessionForTesting(host.get());
    EXPECT_TRUE(restored);
    tasks.RunUntilIdle();
    EXPECT_EQ(timeout ? SHAAR_NOT_READY : SHAAR_NOT_FOUND, captured.code);
    if (timeout)
      CloseProtocolSessionForTesting(host.get());
  }
}

TEST_F(ShaarPrivateDevToolsPageTargetTest, RendererVisibilityRejectsOverlappingLease) {
  web_contents()->WasHidden();
  auto first = StartHiddenProbeCapture(web_contents());
  ASSERT_TRUE(first);
  auto second = StartHiddenProbeCapture(web_contents());
  EXPECT_FALSE(second);
  first.RunAndReset();
  EXPECT_EQ(content::Visibility::HIDDEN, web_contents()->GetVisibility());
  EXPECT_TRUE(StartHiddenProbeCapture(web_contents()));
  EXPECT_EQ(content::Visibility::HIDDEN, web_contents()->GetVisibility());
}

TEST(ShaarDevToolsTest, LifecycleEntryRegistersOnlyItsOperationRange) {
  ShaarModuleRegistry registry;
  shaar_devtools_register(&registry);
  EXPECT_NE(nullptr, registry.Find(SHAAR_OP_DEVTOOLS_CALL));
  EXPECT_NE(nullptr, registry.Find(SHAAR_OP_PROBE_CAPTURE_TAB));
  EXPECT_EQ(&HandleDevToolsOperation, registry.Find(SHAAR_OP_PROBE_TRUSTED_CLICK));
  EXPECT_EQ(&HandleDevToolsOperation, registry.Find(SHAAR_OP_PROBE_TRUSTED_SCROLL));
  EXPECT_EQ(&HandleDevToolsOperation, registry.Find(SHAAR_OP_PROBE_NODE_LIVE));
  EXPECT_EQ(&HandleDevToolsOperation,
            registry.Find(SHAAR_OP_PROBE_POPUP_EVALUATE));
  EXPECT_EQ(&HandleDevToolsOperation,
            registry.Find(SHAAR_OP_PROBE_POPUP_CAPTURE));
  EXPECT_EQ(&HandleDevToolsOperation,
            registry.Find(SHAAR_OP_PROBE_POPUP_TRUSTED_CLICK));
  EXPECT_NE(nullptr, registry.Find(SHAAR_OP_DEVTOOLS_UI_SHOW));
  EXPECT_NE(nullptr, registry.Find(SHAAR_OP_DEVTOOLS_CONTROL_STATUS));
  EXPECT_NE(nullptr, registry.Find(SHAAR_OP_DEVTOOLS_PANEL_OPEN));
  EXPECT_NE(nullptr, registry.Find(SHAAR_OP_DEVTOOLS_PANEL_SCREENCAST));
  EXPECT_NE(nullptr, registry.Find(SHAAR_OP_DEVTOOLS_PANEL_CLOSE));
  EXPECT_NE(nullptr, registry.Find(SHAAR_OP_DEVTOOLS_PANEL_GET_RESPONSE_BODY));
  EXPECT_NE(nullptr, registry.Find(SHAAR_OP_DEVTOOLS_PANEL_PHASE2_COMMAND));
  EXPECT_EQ(nullptr, registry.Find(SHAAR_OP_MEDIA_GET_STATE));
  EXPECT_NE(nullptr, registry.FindModule(SHAAR_MODULE_DEVTOOLS));
}

TEST(ShaarDevToolsPanelTest, ProjectsOnlyNamedFieldsFromAllowlistedEvents) {
  std::string output;
  EXPECT_TRUE(ProjectPanelEventForTesting(
      R"({"method":"Network.requestWillBeSent","params":{"requestId":"r1","request":{"url":"https://example.test","method":"GET","headers":{"Cookie":"secret"},"postData":"secret"}}})",
      42, &output));
  auto parsed = base::JSONReader::Read(output, base::JSON_PARSE_RFC);
  ASSERT_TRUE(parsed && parsed->is_dict());
  EXPECT_EQ(4, parsed->GetDict().FindInt("eventID"));
  EXPECT_EQ(42, parsed->GetDict().FindInt("leaseID"));
  EXPECT_EQ("r1", *parsed->GetDict().FindDict("data")->FindString("requestID"));
  EXPECT_EQ(std::string::npos, output.find("secret"));
  EXPECT_EQ(std::string::npos, output.find("headers"));
  EXPECT_FALSE(ProjectPanelEventForTesting(
      R"({"method":"Runtime.evaluate","params":{"expression":"secret"}})",
      42, &output));
  EXPECT_FALSE(ProjectPanelEventForTesting(
      R"({"method":"Page.screencastFrame","params":{"data":"raw"}})",
      42, &output));
  EXPECT_FALSE(ProjectPanelEventForTesting(
      R"({"method":"Network.requestWillBeSent","params":{}})",
      0, &output));
}

TEST(ShaarDevToolsPanelTest, ClipsTextAndRejectsUnboundedProtocolInput) {
  std::string output;
  const std::string message =
      R"({"method":"Log.entryAdded","params":{"entry":{"text":")" +
      std::string(4097, 'x') + R"(","level":"warning"}}})";
  EXPECT_TRUE(ProjectPanelEventForTesting(message, 1, &output));
  auto parsed = base::JSONReader::Read(output, base::JSON_PARSE_RFC);
  ASSERT_TRUE(parsed && parsed->is_dict());
  const auto* data = parsed->GetDict().FindDict("data");
  ASSERT_NE(nullptr, data);
  EXPECT_EQ(4096u, data->FindString("text")->size());
  EXPECT_EQ(true, data->FindBool("truncated"));
  EXPECT_FALSE(ProjectPanelEventForTesting(
      std::string(257 * 1024, 'x'), 1, &output));
}

TEST(ShaarDevToolsPanelTest, Phase2CommandsHaveFixedMethodsAndBoundedPages) {
  std::string output;
  EXPECT_TRUE(BuildPhase2CommandForTesting(
      SHAAR_DEVTOOLS_PHASE2_DOM_STORAGE_ITEMS,
      R"({"isLocalStorage":false,"skipCount":0,"pageSize":50})",
      "https://example.test", &output));
  EXPECT_NE(std::string::npos, output.find("DOMStorage.getDOMStorageItems"));
  EXPECT_NE(std::string::npos, output.find("https://example.test"));
  EXPECT_FALSE(BuildPhase2CommandForTesting(
      SHAAR_DEVTOOLS_PHASE2_DOM_STORAGE_ITEMS,
      R"({"isLocalStorage":true,"skipCount":0,"pageSize":51})",
      "https://example.test", &output));
  EXPECT_FALSE(BuildPhase2CommandForTesting(
      SHAAR_DEVTOOLS_PHASE2_DOM_STORAGE_ITEMS,
      R"({"isLocalStorage":true,"skipCount":0,"pageSize":1,"securityOrigin":"https://other.test"})",
      "https://example.test", &output));
  EXPECT_FALSE(BuildPhase2CommandForTesting(
      99, "{}", "https://example.test", &output));
}

TEST(ShaarDevToolsPanelTest, Phase2EventsRejectOtherOriginsAndPayloadFields) {
  std::string output;
  EXPECT_TRUE(ProjectPhase2EventForTesting(
      R"({"method":"DOMStorage.domStorageItemAdded","params":{"storageId":{"securityOrigin":"https://example.test","isLocalStorage":true},"key":"a","newValue":"b","secret":"not-projected"}})",
      "https://example.test", 42, &output));
  EXPECT_NE(std::string::npos, output.find("\"eventID\":12"));
  EXPECT_EQ(std::string::npos, output.find("not-projected"));
  EXPECT_FALSE(ProjectPhase2EventForTesting(
      R"({"method":"DOMStorage.domStorageItemAdded","params":{"storageId":{"securityOrigin":"https://other.test","isLocalStorage":true},"key":"a","newValue":"b"}})",
      "https://example.test", 42, &output));
  EXPECT_FALSE(ProjectPhase2EventForTesting(
      R"({"method":"Network.getCookies","params":{}})",
      "https://example.test", 42, &output));
}

}  // namespace
}  // namespace shaar::devtools
