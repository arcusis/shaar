// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#include "chrome/browser/shaar/history/shaar_history.h"

#include <map>
#include <string>

#include "chrome/browser/shaar/history/shaar_history_registry.h"
#include "testing/gtest/include/gtest/gtest.h"

namespace {

class FakeRegistry final : public ShaarModuleRegistry {
 public:
  void RegisterHandler(shaar_operation operation, Handler handler) override {
    handlers.emplace(operation, std::move(handler));
  }
  Profile* ResolveRegularProfile(shaar_profile*) override { return nullptr; }
  std::string ProfileID(shaar_profile*) const override { return "profile-test"; }
  HistoryEvent HistoryEventSink() override { return {}; }

  std::map<shaar_operation, Handler> handlers;
};

struct CapturedReply {
  shaar_error_code code = SHAAR_OK;
  std::string payload;
};

void Capture(void* context, const shaar_result* result) {
  auto* captured = static_cast<CapturedReply*>(context);
  captured->code = result->error.code;
  if (result->payload_json.size)
    captured->payload.assign(result->payload_json.data, result->payload_json.size);
}

shaar_bytes Bytes(const std::string& value) { return {value.data(), value.size()}; }

TEST(ShaarHistoryModuleTest, RegistersTheHistoryOperationRange) {
  FakeRegistry registry;
  shaar_history_register(&registry);
  EXPECT_EQ(registry.handlers.size(), 5u);
  EXPECT_TRUE(registry.handlers.contains(SHAAR_OP_HISTORY_QUERY));
  EXPECT_TRUE(registry.handlers.contains(SHAAR_OP_HISTORY_INSERT));
  EXPECT_TRUE(registry.handlers.contains(SHAAR_OP_HISTORY_DELETE));
  EXPECT_TRUE(registry.handlers.contains(SHAAR_OP_HISTORY_WATCH));
  EXPECT_TRUE(registry.handlers.contains(SHAAR_OP_HISTORY_UNWATCH));
}

TEST(ShaarHistoryModuleTest, RejectsPrivateScopeForEveryHistoryOperation) {
  FakeRegistry registry;
  shaar_history_register(&registry);
  shaar_scope private_scope{sizeof(shaar_scope), nullptr,
                            reinterpret_cast<shaar_private_session*>(1)};
  const std::string args = "{\"schemaVersion\":1}";
  for (const auto& [operation, handler] : registry.handlers) {
    CapturedReply result;
    shaar_error immediate{};
    immediate.size = sizeof(immediate);
    EXPECT_EQ(handler(private_scope, Bytes(args), 42, Capture, &result, &immediate),
              SHAAR_PRIVATE_DISALLOWED) << operation;
    EXPECT_EQ(immediate.code, SHAAR_PRIVATE_DISALLOWED) << operation;
    EXPECT_EQ(result.code, SHAAR_OK) << "immediate failures have no callback";
  }
}

TEST(ShaarHistoryModuleTest, RejectsUnknownQueryFieldsBeforeProfileLookup) {
  FakeRegistry registry;
  shaar_history_register(&registry);
  shaar_scope regular_scope{sizeof(shaar_scope),
                            reinterpret_cast<shaar_profile*>(1), nullptr};
  const std::string args =
      "{\"schemaVersion\":1,\"maxUrls\":20,\"ignored\":true}";
  CapturedReply result;
  shaar_error immediate{};
  immediate.size = sizeof(immediate);
  EXPECT_EQ(registry.handlers.at(SHAAR_OP_HISTORY_QUERY)(regular_scope, Bytes(args), 7,
                                                          Capture, &result, &immediate),
            SHAAR_INVALID_ARGUMENT);
  EXPECT_EQ(immediate.code, SHAAR_INVALID_ARGUMENT);
  EXPECT_EQ(result.code, SHAAR_OK);
}

TEST(ShaarHistoryModuleTest, RejectsInvalidDeleteURLBatchBeforeProfileLookup) {
  FakeRegistry registry;
  shaar_history_register(&registry);
  shaar_scope regular_scope{sizeof(shaar_scope),
                            reinterpret_cast<shaar_profile*>(1), nullptr};
  const std::string args =
      "{\"schemaVersion\":1,\"urls\":[\"file:///tmp/private\"]}";
  CapturedReply result;
  shaar_error immediate{};
  immediate.size = sizeof(immediate);
  EXPECT_EQ(registry.handlers.at(SHAAR_OP_HISTORY_DELETE)(regular_scope, Bytes(args), 8,
                                                          Capture, &result, &immediate),
            SHAAR_INVALID_ARGUMENT);
  EXPECT_EQ(immediate.code, SHAAR_INVALID_ARGUMENT);
  EXPECT_EQ(result.code, SHAAR_OK);
}

}  // namespace
