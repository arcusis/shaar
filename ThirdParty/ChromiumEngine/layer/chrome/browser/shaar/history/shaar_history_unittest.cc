// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#include "chrome/browser/shaar/history/shaar_history.h"

#include <map>
#include <string>

#include "chrome/browser/shaar/engine/shaar_module_registry.h"
#include "components/history/core/browser/history_types.h"
#include "testing/gtest/include/gtest/gtest.h"

namespace {

class FakeProfileServices final : public shaar::ProfileServices {
 public:
  Profile* ResolveProfile(shaar_engine*, shaar_profile*) override {
    return nullptr;
  }
  std::string_view ProfileID(shaar_engine*, shaar_profile*) override {
    return "profile-test";
  }
  KeyedService* GetKeyedService(shaar_engine*, shaar_profile*,
                                KeyedServiceLookup) override {
    return nullptr;
  }
};

class FakeBrowserTabs final : public shaar::BrowserTabRegistry {
 public:
  Browser* FindBrowser(shaar_engine*, shaar_window*) override { return nullptr; }
  content::WebContents* FindWebContents(shaar_engine*, shaar_window*,
                                        shaar_tab*) override {
    return nullptr;
  }
  content::WebContents* FindWebContentsByID(shaar_engine*, shaar_window*,
                                             std::string_view) override {
    return nullptr;
  }
  std::string_view TabID(shaar_engine*, shaar_window*, shaar_tab*) override {
    return {};
  }
  void GetTabs(shaar_engine*, shaar_window*,
               std::unordered_map<std::string, content::WebContents*>*)
      override {}
};

struct CapturedReply {
  shaar_error_code code = SHAAR_OK;
  std::string payload;
};

void Capture(void *context, const shaar_result *result) {
  auto *captured = static_cast<CapturedReply *>(context);
  captured->code = result->error.code;
  if (result->payload_json.size)
    captured->payload.assign(result->payload_json.data,
                             result->payload_json.size);
}

shaar_bytes Bytes(const std::string &value) {
  return {value.data(), value.size()};
}

TEST(ShaarHistoryModuleTest, RegistersTheHistoryOperationRange) {
  ShaarModuleRegistry registry;
  shaar_history_register(&registry);
  EXPECT_NE(registry.Find(SHAAR_OP_HISTORY_QUERY), nullptr);
  EXPECT_NE(registry.Find(SHAAR_OP_HISTORY_INSERT), nullptr);
  EXPECT_NE(registry.Find(SHAAR_OP_HISTORY_DELETE), nullptr);
  EXPECT_NE(registry.Find(SHAAR_OP_HISTORY_WATCH), nullptr);
  EXPECT_NE(registry.Find(SHAAR_OP_HISTORY_UNWATCH), nullptr);
}

TEST(ShaarHistoryModuleTest, MapsImportsToChromiumVisitSourceCategories) {
  EXPECT_EQ(shaar_history::VisitSourceForImport("safari"),
            history::SOURCE_SAFARI_IMPORTED);
  EXPECT_EQ(shaar_history::VisitSourceForImport("firefox"),
            history::SOURCE_FIREFOX_IMPORTED);
  EXPECT_EQ(shaar_history::VisitSourceForImport("chrome"),
            history::SOURCE_OS_MIGRATION_IMPORTED);
  EXPECT_EQ(shaar_history::VisitSourceForImport("arc"),
            history::SOURCE_OS_MIGRATION_IMPORTED);
}

TEST(ShaarHistoryModuleTest, RejectsPrivateScopeForEveryHistoryOperation) {
  ShaarModuleRegistry registry;
  shaar_history_register(&registry);
  FakeProfileServices profiles;
  FakeBrowserTabs tabs;
  shaar::ShaarEngineContext context{&profiles, &tabs};
  auto* engine = reinterpret_cast<shaar_engine*>(1);
  shaar_scope private_scope{sizeof(shaar_scope), nullptr,
                            reinterpret_cast<shaar_private_session *>(1)};
  const std::string args = "{\"schemaVersion\":1}";
  for (shaar_operation operation : {SHAAR_OP_HISTORY_QUERY,
                                    SHAAR_OP_HISTORY_INSERT,
                                    SHAAR_OP_HISTORY_DELETE,
                                    SHAAR_OP_HISTORY_WATCH,
                                    SHAAR_OP_HISTORY_UNWATCH}) {
    CapturedReply result;
    shaar_error immediate{};
    immediate.size = sizeof(immediate);
    EXPECT_EQ(registry.Find(operation)(
                  &context, engine, private_scope, nullptr, nullptr, operation,
                  Bytes(args), 42, Capture, &result, &immediate),
              SHAAR_PRIVATE_DISALLOWED) << operation;
    EXPECT_EQ(immediate.code, SHAAR_PRIVATE_DISALLOWED) << operation;
    EXPECT_EQ(result.code, SHAAR_OK) << "immediate failures have no callback";
  }
}

TEST(ShaarHistoryModuleTest, RejectsUnknownQueryFieldsBeforeProfileLookup) {
  ShaarModuleRegistry registry;
  shaar_history_register(&registry);
  FakeProfileServices profiles;
  FakeBrowserTabs tabs;
  shaar::ShaarEngineContext context{&profiles, &tabs};
  shaar_scope regular_scope{sizeof(shaar_scope),
                            reinterpret_cast<shaar_profile *>(1), nullptr};
  const std::string args =
      "{\"schemaVersion\":1,\"maxUrls\":20,\"ignored\":true}";
  CapturedReply result;
  shaar_error immediate{};
  immediate.size = sizeof(immediate);
  EXPECT_EQ(registry.Find(SHAAR_OP_HISTORY_QUERY)(
                &context, reinterpret_cast<shaar_engine*>(1), regular_scope,
                nullptr, nullptr, SHAAR_OP_HISTORY_QUERY, Bytes(args), 7,
                Capture, &result, &immediate),
            SHAAR_INVALID_ARGUMENT);
  EXPECT_EQ(immediate.code, SHAAR_INVALID_ARGUMENT);
  EXPECT_EQ(result.code, SHAAR_OK);
}

TEST(ShaarHistoryModuleTest, RejectsInvalidDeleteURLBatchBeforeProfileLookup) {
  ShaarModuleRegistry registry;
  shaar_history_register(&registry);
  FakeProfileServices profiles;
  FakeBrowserTabs tabs;
  shaar::ShaarEngineContext context{&profiles, &tabs};
  shaar_scope regular_scope{sizeof(shaar_scope),
                            reinterpret_cast<shaar_profile *>(1), nullptr};
  const std::string args =
      "{\"schemaVersion\":1,\"urls\":[\"file:///tmp/private\"]}";
  CapturedReply result;
  shaar_error immediate{};
  immediate.size = sizeof(immediate);
  EXPECT_EQ(registry.Find(SHAAR_OP_HISTORY_DELETE)(
                &context, reinterpret_cast<shaar_engine*>(1), regular_scope,
                nullptr, nullptr, SHAAR_OP_HISTORY_DELETE, Bytes(args), 8,
                Capture, &result, &immediate),
            SHAAR_INVALID_ARGUMENT);
  EXPECT_EQ(immediate.code, SHAAR_INVALID_ARGUMENT);
  EXPECT_EQ(result.code, SHAAR_OK);
}

TEST(ShaarHistoryModuleTest, RejectsWrongQueryFieldTypes) {
  ShaarModuleRegistry registry;
  shaar_history_register(&registry);
  FakeProfileServices profiles;
  FakeBrowserTabs tabs;
  shaar::ShaarEngineContext context{&profiles, &tabs};
  shaar_scope regular_scope{sizeof(shaar_scope),
                            reinterpret_cast<shaar_profile *>(1), nullptr};
  const std::string args = "{\"schemaVersion\":1,\"maxUrls\":\"500\"}";
  CapturedReply result;
  shaar_error immediate{};
  immediate.size = sizeof(immediate);
  EXPECT_EQ(registry.Find(SHAAR_OP_HISTORY_QUERY)(
                &context, reinterpret_cast<shaar_engine*>(1), regular_scope,
                nullptr, nullptr, SHAAR_OP_HISTORY_QUERY, Bytes(args), 9,
                Capture, &result, &immediate),
            SHAAR_INVALID_ARGUMENT);
  EXPECT_EQ(immediate.code, SHAAR_INVALID_ARGUMENT);
  EXPECT_EQ(result.code, SHAAR_OK);
}

} // namespace
